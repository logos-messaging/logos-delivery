{.push raises: [].}

import
  std/[options, sequtils, strformat],
  results,
  chronicles,
  chronos,
  libp2p/protocols/connectivity/relay/relay,
  libp2p/protocols/connectivity/relay/client,
  libp2p/wire,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/services/autorelayservice,
  libp2p/services/hpservice,
  libp2p/peerid,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  presto,
  metrics,
  metrics/chronos_httpserver,
  waku/[
    waku_core,
    waku_node,
    waku_archive,
    waku_rln_relay,
    waku_store,
    waku_filter_v2,
    waku_relay/protocol,
    waku_enr/sharding,
    waku_enr/multiaddr,
    api/types,
    common/logging,
    common/broker/broker_context,
    node/peer_manager,
    node/health_monitor,
    node/waku_metrics,
    node/delivery_service/delivery_service,
    rest_api/message_cache,
    rest_api/endpoint/server,
    rest_api/endpoint/builder as rest_server_builder,
    discovery/waku_dnsdisc,
    discovery/waku_discv5,
    discovery/autonat_service,
    requests/health_requests,
    factory/node_factory,
    factory/internal_config,
    factory/app_callbacks
  ],
  ./waku_conf

logScope:
  topics = "wakunode waku"

# Git version in git describe format (defined at compile time)
const git_version* {.strdefine.} = "n/a"

type Waku* = ref object
  version: string
  conf*: WakuConf
  rng*: ref HmacDrbgContext

  key: crypto.PrivateKey

  wakuDiscv5*: WakuDiscoveryV5
  dynamicBootstrapNodes*: seq[RemotePeerInfo]
  dnsRetryLoopHandle: Future[void]
  networkConnLoopHandle: Future[void]

  node*: WakuNode

  healthMonitor*: NodeHealthMonitor

  deliveryService*: DeliveryService

  restServer*: WakuRestServerRef
  metricsServer*: MetricsHttpServerRef
  appCallbacks*: AppCallbacks

  brokerCtx*: BrokerContext

func version*(waku: Waku): string =
  waku.version

proc setupSwitchServices(
    waku: Waku, conf: WakuConf, circuitRelay: Relay, rng: ref HmacDrbgContext
) =
  proc onReservation(addresses: seq[MultiAddress]) {.gcsafe, raises: [].} =
    info "circuit relay handler new reserve event",
      addrs_before = $(waku.node.announcedAddresses), addrs = $addresses

    waku.node.announcedAddresses.setLen(0) ## remove previous addresses
    waku.node.announcedAddresses.add(addresses)
    info "waku node announced addresses updated",
      announcedAddresses = waku.node.announcedAddresses

    if not isNil(waku.wakuDiscv5):
      waku.wakuDiscv5.updateAnnouncedMultiAddress(addresses).isOkOr:
        error "failed to update announced multiaddress", error = $error

  let autonatService = getAutonatService(rng)
  if conf.circuitRelayClient:
    ## The node is considered to be behind a NAT or firewall and then it
    ## should struggle to be reachable and establish connections to other nodes
    const MaxNumRelayServers = 2
    let autoRelayService = AutoRelayService.new(
      MaxNumRelayServers, RelayClient(circuitRelay), onReservation, rng
    )
    let holePunchService = HPService.new(autonatService, autoRelayService)
    waku.node.switch.services = @[Service(holePunchService)]
  else:
    waku.node.switch.services = @[Service(autonatService)]

## Initialisation

proc newCircuitRelay(isRelayClient: bool): Relay =
  # TODO: Does it mean it's a circuit-relay server when it's false?
  if isRelayClient:
    return RelayClient.new()
  return Relay.new()

proc setupAppCallbacks(
    node: WakuNode,
    conf: WakuConf,
    appCallbacks: AppCallbacks,
    healthMonitor: NodeHealthMonitor,
): Result[void, string] =
  if appCallbacks.isNil():
    info "No external callbacks to be set"
    return ok()

  if not appCallbacks.relayHandler.isNil():
    if node.wakuRelay.isNil():
      return err("Cannot configure relayHandler callback without Relay mounted")

    let autoShards =
      if node.wakuAutoSharding.isSome():
        node.getAutoshards(conf.contentTopics).valueOr:
          return err("Could not get autoshards: " & error)
      else:
        @[]

    let confShards = conf.subscribeShards.mapIt(
      RelayShard(clusterId: conf.clusterId, shardId: uint16(it))
    )
    let shards = confShards & autoShards

    let uniqueShards = deduplicate(shards)

    for shard in uniqueShards:
      let topic = $shard
      node.subscribe((kind: PubsubSub, topic: topic), appCallbacks.relayHandler).isOkOr:
        return err(fmt"Could not subscribe {topic}: " & $error)

  if not appCallbacks.topicHealthChangeHandler.isNil():
    if node.wakuRelay.isNil():
      return
        err("Cannot configure topicHealthChangeHandler callback without Relay mounted")
    node.wakuRelay.onTopicHealthChange = appCallbacks.topicHealthChangeHandler

  if not appCallbacks.connectionChangeHandler.isNil():
    if node.peerManager.isNil():
      return
        err("Cannot configure connectionChangeHandler callback with empty peer manager")
    node.peerManager.onConnectionChange = appCallbacks.connectionChangeHandler

  if not appCallbacks.connectionStatusChangeHandler.isNil():
    if healthMonitor.isNil():
      return err("Cannot configure connectionStatusChangeHandler with empty health monitor")

    healthMonitor.onConnectionStatusChange = appCallbacks.connectionStatusChangeHandler

  return ok()

proc new*(
    T: type Waku, wakuConf: WakuConf, appCallbacks: AppCallbacks = nil
): Future[Result[Waku, string]] {.async.} =
  let rng = crypto.newRng()
  let brokerCtx = globalBrokerContext()

  logging.setupLog(wakuConf.logLevel, wakuConf.logFormat)

  ?wakuConf.validate()
  wakuConf.logConf()

  let relay = newCircuitRelay(wakuConf.circuitRelayClient)

  let node = (await setupNode(wakuConf, rng, relay)).valueOr:
    error "Failed setting up node", error = $error
    return err("Failed setting up node: " & $error)

  let healthMonitor = NodeHealthMonitor.new(node, wakuConf.dnsAddrsNameServers)

  let restServer: WakuRestServerRef =
    if wakuConf.restServerConf.isSome():
      let restServer = startRestServerEssentials(
        healthMonitor, wakuConf.restServerConf.get(), wakuConf.portsShift
      ).valueOr:
        error "Starting essential REST server failed", error = $error
        return err("Failed to start essential REST server in Waku.new: " & $error)

      restServer
    else:
      nil

  node.setupAppCallbacks(wakuConf, appCallbacks, healthMonitor).isOkOr:
    error "Failed setting up app callbacks", error = error
    return err("Failed setting up app callbacks: " & $error)

  ## Delivery Monitor
  let deliveryService = DeliveryService.new(wakuConf.p2pReliability, node).valueOr:
    return err("could not create delivery service: " & $error)

  var waku = Waku(
    version: git_version,
    conf: wakuConf,
    rng: rng,
    key: wakuConf.nodeKey,
    node: node,
    healthMonitor: healthMonitor,
    deliveryService: deliveryService,
    appCallbacks: appCallbacks,
    restServer: restServer,
    brokerCtx: brokerCtx,
  )

  waku.setupSwitchServices(wakuConf, relay, rng)

  ok(waku)

proc getPorts(
    listenAddrs: seq[MultiAddress]
): Result[tuple[tcpPort, websocketPort: Option[Port]], string] =
  var tcpPort, websocketPort = none(Port)

  for a in listenAddrs:
    if a.isWsAddress():
      if websocketPort.isNone():
        let wsAddress = initTAddress(a).valueOr:
          return err("getPorts wsAddr error:" & $error)
        websocketPort = some(wsAddress.port)
    elif tcpPort.isNone():
      let tcpAddress = initTAddress(a).valueOr:
        return err("getPorts tcpAddr error:" & $error)
      tcpPort = some(tcpAddress.port)

  return ok((tcpPort: tcpPort, websocketPort: websocketPort))

proc getRunningNetConfig(waku: ptr Waku): Future[Result[NetConfig, string]] {.async.} =
  var conf = waku[].conf
  let (tcpPort, websocketPort) = getPorts(waku[].node.switch.peerInfo.listenAddrs).valueOr:
    return err("Could not retrieve ports: " & error)

  if tcpPort.isSome():
    conf.endpointConf.p2pTcpPort = tcpPort.get()

  if websocketPort.isSome() and conf.webSocketConf.isSome():
    conf.webSocketConf.get().port = websocketPort.get()

  # Rebuild NetConfig with bound port values
  let netConf = (
    await networkConfiguration(
      conf.clusterId, conf.endpointConf, conf.discv5Conf, conf.webSocketConf,
      conf.wakuFlags, conf.dnsAddrsNameServers, conf.portsShift, clientId,
    )
  ).valueOr:
    return err("Could not update NetConfig: " & error)

  return ok(netConf)

proc updateEnr(waku: ptr Waku): Future[Result[void, string]] {.async.} =
  let netConf: NetConfig = (await getRunningNetConfig(waku)).valueOr:
    return err("error calling updateNetConfig: " & $error)
  let record = enrConfiguration(waku[].conf, netConf).valueOr:
    return err("ENR setup failed: " & error)

  if isClusterMismatched(record, waku[].conf.clusterId):
    return err("cluster-id mismatch configured shards")

  waku[].node.enr = record

  return ok()

proc updateAddressInENR(waku: ptr Waku): Result[void, string] =
  let addresses: seq[MultiAddress] = waku[].node.announcedAddresses
  let encodedAddrs = multiaddr.encodeMultiaddrs(addresses)

  ## First update the enr info contained in WakuNode
  let keyBytes = waku[].key.getRawBytes().valueOr:
    return err("failed to retrieve raw bytes from waku key: " & $error)

  let parsedPk = keys.PrivateKey.fromHex(keyBytes.toHex()).valueOr:
    return err("failed to parse the private key: " & $error)

  let enrFields = @[toFieldPair(MultiaddrEnrField, encodedAddrs)]
  waku[].node.enr.update(parsedPk, extraFields = enrFields).isOkOr:
    return err("failed to update multiaddress in ENR updateAddressInENR: " & $error)

  info "Waku node ENR updated successfully with new multiaddress",
    enr = waku[].node.enr.toUri(), record = $(waku[].node.enr)

  ## Now update the ENR infor in discv5
  if not waku[].wakuDiscv5.isNil():
    waku[].wakuDiscv5.protocol.localNode.record = waku[].node.enr
    let enr = waku[].wakuDiscv5.protocol.localNode.record

    info "Waku discv5 ENR updated successfully with new multiaddress",
      enr = enr.toUri(), record = $(enr)

  return ok()

proc updateWaku(waku: ptr Waku): Future[Result[void, string]] {.async.} =
  let conf = waku[].conf
  if conf.endpointConf.p2pTcpPort == Port(0) or
      (conf.websocketConf.isSome() and conf.websocketConf.get.port == Port(0)):
    (await updateEnr(waku)).isOkOr:
      return err("error calling updateEnr: " & $error)

  ?updateAnnouncedAddrWithPrimaryIpAddr(waku[].node)

  ?updateAddressInENR(waku)

  return ok()

proc startDnsDiscoveryRetryLoop(waku: ptr Waku): Future[void] {.async.} =
  while true:
    await sleepAsync(30.seconds)
    if waku.conf.dnsDiscoveryConf.isSome():
      let dnsDiscoveryConf = waku.conf.dnsDiscoveryConf.get()
      waku[].dynamicBootstrapNodes = (
        await waku_dnsdisc.retrieveDynamicBootstrapNodes(
          dnsDiscoveryConf.enrTreeUrl, dnsDiscoveryConf.nameServers
        )
      ).valueOr:
        error "Retrieving dynamic bootstrap nodes failed", error = error
        continue

    if not waku[].wakuDiscv5.isNil():
      let dynamicBootstrapEnrs = waku[].dynamicBootstrapNodes
        .filterIt(it.hasUdpPort())
        .mapIt(it.enr.get().toUri())
      var discv5BootstrapEnrs: seq[enr.Record]
      # parse enrURIs from the configuration and add the resulting ENRs to the discv5BootstrapEnrs seq
      for enrUri in dynamicBootstrapEnrs:
        addBootstrapNode(enrUri, discv5BootstrapEnrs)

      waku[].wakuDiscv5.updateBootstrapRecords(
        waku[].wakuDiscv5.protocol.bootstrapRecords & discv5BootstrapEnrs
      )

    info "Connecting to dynamic bootstrap peers"
    try:
      await connectToNodes(
        waku[].node, waku[].dynamicBootstrapNodes, "dynamic bootstrap"
      )
    except CatchableError:
      error "failed to connect to dynamic bootstrap nodes: " & getCurrentExceptionMsg()
    return

proc startWaku*(waku: ptr Waku): Future[Result[void, string]] {.async: (raises: []).} =
  if waku[].node.started:
    warn "startWaku: waku node already started"
    return ok()

  info "Retrieve dynamic bootstrap nodes"
  let conf = waku[].conf

  if conf.dnsDiscoveryConf.isSome():
    let dnsDiscoveryConf = waku.conf.dnsDiscoveryConf.get()
    let dynamicBootstrapNodesRes =
      try:
        await waku_dnsdisc.retrieveDynamicBootstrapNodes(
          dnsDiscoveryConf.enrTreeUrl, dnsDiscoveryConf.nameServers
        )
      except CatchableError as exc:
        Result[seq[RemotePeerInfo], string].err(
          "Retrieving dynamic bootstrap nodes failed: " & exc.msg
        )

    if dynamicBootstrapNodesRes.isErr():
      error "Retrieving dynamic bootstrap nodes failed",
        error = dynamicBootstrapNodesRes.error
      # Start Dns Discovery retry loop
      waku[].dnsRetryLoopHandle = waku.startDnsDiscoveryRetryLoop()
    else:
      waku[].dynamicBootstrapNodes = dynamicBootstrapNodesRes.get()

  (await startNode(waku.node, waku.conf, waku.dynamicBootstrapNodes)).isOkOr:
    return err("error while calling startNode: " & $error)

  ## Update waku data that is set dynamically on node start
  try:
    (await updateWaku(waku)).isOkOr:
      return err("Error in updateApp: " & $error)
  except CatchableError:
    return err("Caught exception in updateApp: " & getCurrentExceptionMsg())

  ## Discv5
  if conf.discv5Conf.isSome():
    waku[].wakuDiscV5 = waku_discv5.setupDiscoveryV5(
      waku.node.enr,
      waku.node.peerManager,
      waku.node.topicSubscriptionQueue,
      conf.discv5Conf.get(),
      waku.dynamicBootstrapNodes,
      waku.rng,
      conf.nodeKey,
      conf.endpointConf.p2pListenAddress,
      conf.portsShift,
    )

    (await waku.wakuDiscV5.start()).isOkOr:
      return err("failed to start waku discovery v5: " & $error)

  ## Reliability
  if not waku[].deliveryService.isNil():
    waku[].deliveryService.startDeliveryService()

  ## Health Monitor
  waku[].healthMonitor.startHealthMonitor().isOkOr:
    return err("failed to start health monitor: " & $error)

  ## Setup RequestConnectionStatus provider

  RequestConnectionStatus.setProvider(
    globalBrokerContext(),
    proc(): Result[RequestConnectionStatus, string] =
      try:
        let healthReport = waku[].healthMonitor.getSyncNodeHealthReport()
        return ok(RequestConnectionStatus(connectionStatus: healthReport.connectionStatus))
      except CatchableError:
        err("Failed to read health report: " & getCurrentExceptionMsg()),
  ).isOkOr:
    error "Failed to set RequestConnectionStatus provider", error = error

  ## Setup RequestProtocolHealth provider

  RequestProtocolHealth.setProvider(
    globalBrokerContext(),
    proc(
        protocol: WakuProtocol
    ): Future[Result[RequestProtocolHealth, string]] {.async.} =
      try:
        let protocolHealthStatus =
          await waku[].healthMonitor.getProtocolHealthInfo(protocol)
        ok(RequestProtocolHealth(healthStatus: protocolHealthStatus))
      except CatchableError:
        err("Failed to get protocol health: " & getCurrentExceptionMsg()),
  ).isOkOr:
    error "Failed to set RequestProtocolHealth provider", error = error

  if conf.restServerConf.isSome():
    rest_server_builder.startRestServerProtocolSupport(
      waku[].restServer,
      waku[].node,
      waku[].wakuDiscv5,
      conf.restServerConf.get(),
      conf.relay,
      conf.lightPush,
      conf.clusterId,
      conf.subscribeShards,
      conf.contentTopics,
    ).isOkOr:
      return err ("Starting protocols support REST server failed: " & $error)

  if conf.metricsServerConf.isSome():
    try:
      waku[].metricsServer = (
        await (
          waku_metrics.startMetricsServerAndLogging(
            conf.metricsServerConf.get(), conf.portsShift
          )
        )
      ).valueOr:
        return err("Starting monitoring and external interfaces failed: " & error)
    except CatchableError:
      return err(
        "Caught exception starting monitoring and external interfaces failed: " &
          getCurrentExceptionMsg()
      )
  waku[].healthMonitor.setOverallHealth(HealthStatus.READY)

  return ok()

proc stop*(waku: Waku): Future[Result[void, string]] {.async: (raises: []).} =
  ## Waku shutdown

  if not waku.node.started:
    warn "stop: attempting to stop node that isn't running"

  try:
    waku.healthMonitor.setOverallHealth(HealthStatus.SHUTTING_DOWN)

    if not waku.metricsServer.isNil():
      await waku.metricsServer.stop()

    if not waku.wakuDiscv5.isNil():
      await waku.wakuDiscv5.stop()

    if not waku.node.isNil():
      await waku.node.stop()

    if not waku.dnsRetryLoopHandle.isNil():
      await waku.dnsRetryLoopHandle.cancelAndWait()

    if not waku.healthMonitor.isNil():
      await waku.healthMonitor.stopHealthMonitor()

    ## Clear RequestConnectionStatus provider
    RequestConnectionStatus.clearProvider(waku.brokerCtx)

    if not waku.restServer.isNil():
      await waku.restServer.stop()
  except Exception:
    error "waku stop failed: " & getCurrentExceptionMsg()
    return err("waku stop failed: " & getCurrentExceptionMsg())

  return ok()

proc isModeCoreAvailable*(waku: Waku): bool =
  return not waku.node.wakuRelay.isNil()

proc isModeEdgeAvailable*(waku: Waku): bool =
  return
    waku.node.wakuRelay.isNil() and not waku.node.wakuStoreClient.isNil() and
    not waku.node.wakuFilterClient.isNil() and not waku.node.wakuLightPushClient.isNil()

{.pop.}

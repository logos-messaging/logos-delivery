import logos_delivery/waku/compat/option_valueor
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
  libp2p/protocols/ping,
  libp2p/services/autorelayservice,
  libp2p/services/hpservice,
  libp2p/peerid,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  presto,
  metrics,
  metrics/chronos_httpserver,
  brokers/broker_context,
  logos_delivery/api/types,
  logos_delivery/waku/[
    waku_core,
    waku_node,
    waku_archive,
    waku_rln_relay,
    waku_store,
    waku_filter_v2,
    waku_relay/protocol,
    waku_enr/sharding,
    waku_enr/multiaddr,
    common/logging,
    node/peer_manager,
    node/health_monitor,
    net/net_config,
    node/waku_metrics,
    node/subscription_manager,
    rest_api/message_cache,
    rest_api/endpoint/server,
    rest_api/endpoint/builder as rest_server_builder,
    discovery/waku_dnsdisc,
    discovery/waku_discv5,
    discovery/autonat_service,
    requests/health_requests,
    factory/node_factory,
    factory/internal_config,
    factory/app_callbacks,
    persistency/persistency,
    factory/validator_signed,
    waku_lightpush/client,
    waku_lightpush_legacy/client,
    waku_store/client,
  ],
  ./factory/waku_conf,
  ./factory/waku_state_info

logScope:
  topics = "wakunode waku"

# Git version in git describe format (defined at compile time)
const git_version* {.strdefine.} = "n/a"

const FilterOpTimeout = 5.seconds

type Waku* = ref object
  stateInfo*: WakuStateInfo
  conf*: WakuConf
  rng*: crypto.Rng

  key: crypto.PrivateKey

  wakuDiscv5*: WakuDiscoveryV5
  dynamicBootstrapNodes*: seq[RemotePeerInfo]
  dnsRetryLoopHandle: Future[void]
  networkConnLoopHandle: Future[void]

  node*: WakuNode

  healthMonitor*: NodeHealthMonitor

  restServer*: WakuRestServerRef
  metricsServer*: MetricsHttpServerRef
  appCallbacks*: AppCallbacks

  brokerCtx*: BrokerContext

proc setupSwitchServices(
    waku: Waku, conf: WakuConf, circuitRelay: Relay, rng: crypto.Rng
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

  # libp2p 2.0.0 split Service.setup out of Service.start: the switch runs setup
  # only at build time (SwitchBuilder.setupServices), while switch.start calls
  # just start. These services are created and attached post-build, so setup must
  # be invoked explicitly here -- otherwise AutonatService.addressMapper stays nil
  # and the peerInfo.update() inside start dereferences it (SIGSEGV).
  for service in waku.node.switch.services:
    try:
      service.setup(waku.node.switch)
    except ServiceSetupError as e:
      error "failed to set up libp2p switch service", error = e.msg

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
      return
        err("Cannot configure connectionStatusChangeHandler with empty health monitor")

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

  if not restServer.isNil():
    let boundRestPort = restServer.httpServer.address.port
    node.ports.rest = boundRestPort.uint16
    wakuConf.restServerConf.get().port = boundRestPort

  # Set the extMultiAddrsOnly flag so the node knows not to replace explicit addresses
  node.extMultiAddrsOnly = wakuConf.endpointConf.extMultiAddrsOnly

  node.setupAppCallbacks(wakuConf, appCallbacks, healthMonitor).isOkOr:
    error "Failed setting up app callbacks", error = error
    return err("Failed setting up app callbacks: " & $error)

  var waku = Waku(
    stateInfo: WakuStateInfo.init(node),
    conf: wakuConf,
    rng: rng,
    key: wakuConf.nodeKey,
    node: node,
    healthMonitor: healthMonitor,
    appCallbacks: appCallbacks,
    restServer: restServer,
    brokerCtx: brokerCtx,
  )

  waku.setupSwitchServices(wakuConf, relay, rng)

  ok(waku)

proc getPorts(
    listenAddrs: seq[MultiAddress]
): Result[tuple[tcpPort, websocketPort, quicPort: Option[Port]], string] =
  var tcpPort, websocketPort, quicPort = none(Port)

  for a in listenAddrs:
    if a.isWsAddress():
      if websocketPort.isNone():
        let wsAddress = initTAddress(a).valueOr:
          return err("getPorts wsAddr error:" & $error)
        websocketPort = some(wsAddress.port)
    elif a.isQuicAddress():
      if quicPort.isNone():
        let quicAddress = initTAddress(a).valueOr:
          return err("getPorts quicAddr error:" & $error)
        quicPort = some(quicAddress.port)
    elif tcpPort.isNone():
      let tcpAddress = initTAddress(a).valueOr:
        return err("getPorts tcpAddr error:" & $error)
      tcpPort = some(tcpAddress.port)

  return ok((tcpPort: tcpPort, websocketPort: websocketPort, quicPort: quicPort))

proc getRunningNetConfig(waku: Waku): Future[Result[NetConfig, string]] {.async.} =
  let conf = waku.conf
  let (tcpPort, websocketPort, quicPort) = getPorts(
    waku.node.switch.peerInfo.listenAddrs
  ).valueOr:
    return err("Could not retrieve ports: " & error)

  if tcpPort.isSome():
    conf.endpointConf.p2pTcpPort = tcpPort.get()

  if websocketPort.isSome() and conf.webSocketConf.isSome():
    conf.webSocketConf.get().port = websocketPort.get()

  if quicPort.isSome() and conf.quicConf.isSome():
    conf.quicConf.get().port = quicPort.get()

  # Rebuild NetConfig with bound port values
  let netConf = (
    await networkConfiguration(
      conf.clusterId, conf.endpointConf, conf.discv5Conf, conf.webSocketConf,
      conf.quicConf, conf.wakuFlags, conf.dnsAddrsNameServers, conf.portsShift, clientId,
    )
  ).valueOr:
    return err("Could not update NetConfig: " & error)

  return ok(netConf)

proc updateEnr(waku: Waku): Future[Result[void, string]] {.async.} =
  let netConf: NetConfig = (await getRunningNetConfig(waku)).valueOr:
    return err("error calling updateNetConfig: " & $error)
  let record = enrConfiguration(waku.conf, netConf).valueOr:
    return err("ENR setup failed: " & error)

  if isClusterMismatched(record, waku.conf.clusterId):
    return err("cluster-id mismatch configured shards")

  waku.node.enr = record

  # If TCP/WS was configured with port 0, node.announcedAddresses was built
  # pre-bind with a port value of 0. In any case, the resync is harmless.
  waku.node.announcedAddresses = netConf.announcedAddresses

  return ok()

proc updateAddressInENR(waku: Waku): Result[void, string] =
  let addresses: seq[MultiAddress] = waku.node.announcedAddresses
  let encodedAddrs = multiaddr.encodeMultiaddrs(addresses)

  ## First update the enr info contained in WakuNode
  let keyBytes = waku.key.getRawBytes().valueOr:
    return err("failed to retrieve raw bytes from waku key: " & $error)

  let parsedPk = keys.PrivateKey.fromHex(keyBytes.toHex()).valueOr:
    return err("failed to parse the private key: " & $error)

  let enrFields = @[toFieldPair(MultiaddrEnrField, encodedAddrs)]
  waku.node.enr.update(parsedPk, extraFields = enrFields).isOkOr:
    return err("failed to update multiaddress in ENR updateAddressInENR: " & $error)

  info "Waku node ENR updated successfully with new multiaddress",
    enr = waku.node.enr.toUri(), record = $(waku.node.enr)

  ## Now update the ENR infor in discv5
  if not waku.wakuDiscv5.isNil():
    waku.wakuDiscv5.protocol.localNode.record = waku.node.enr
    let enr = waku.wakuDiscv5.protocol.localNode.record

    info "Waku discv5 ENR updated successfully with new multiaddress",
      enr = enr.toUri(), record = $(enr)

  return ok()

proc updateWaku(waku: Waku): Future[Result[void, string]] {.async.} =
  (await updateEnr(waku)).isOkOr:
    return err("error calling updateEnr: " & $error)

  ?updateAnnouncedAddrWithPrimaryIpAddr(waku.node)

  ?updateAddressInENR(waku)

  return ok()

proc startDnsDiscoveryRetryLoop(waku: Waku): Future[void] {.async.} =
  while true:
    await sleepAsync(30.seconds)
    if waku.conf.dnsDiscoveryConf.isSome():
      let dnsDiscoveryConf = waku.conf.dnsDiscoveryConf.get()
      waku.dynamicBootstrapNodes = (
        await waku_dnsdisc.retrieveDynamicBootstrapNodes(
          dnsDiscoveryConf.enrTreeUrl, dnsDiscoveryConf.nameServers
        )
      ).valueOr:
        error "Retrieving dynamic bootstrap nodes failed", error = error
        continue

    if not waku.wakuDiscv5.isNil():
      let dynamicBootstrapEnrs =
        waku.dynamicBootstrapNodes.filterIt(it.hasUdpPort()).mapIt(it.enr.get().toUri())
      var discv5BootstrapEnrs: seq[enr.Record]
      # parse enrURIs from the configuration and add the resulting ENRs to the discv5BootstrapEnrs seq
      for enrUri in dynamicBootstrapEnrs:
        addBootstrapNode(enrUri, discv5BootstrapEnrs)

      waku.wakuDiscv5.updateBootstrapRecords(
        waku.wakuDiscv5.protocol.bootstrapRecords & discv5BootstrapEnrs
      )

    info "Connecting to dynamic bootstrap peers"
    try:
      await connectToNodes(waku.node, waku.dynamicBootstrapNodes, "dynamic bootstrap")
    except CatchableError:
      error "failed to connect to dynamic bootstrap nodes: " & getCurrentExceptionMsg()
    return

proc start*(waku: Waku): Future[Result[void, string]] {.async: (raises: []).} =
  if waku.node.started:
    warn "start: waku node already started"
    return ok()

  info "Retrieve dynamic bootstrap nodes"
  let conf = waku.conf

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
      waku.dnsRetryLoopHandle = waku.startDnsDiscoveryRetryLoop()
    else:
      waku.dynamicBootstrapNodes = dynamicBootstrapNodesRes.get()

  ## Initialize persistency singleton instance - we don't need the instance itself here,
  ## but this ensures it's initialized before any store job starts.
  discard Persistency.instance(conf.localStoragePath).valueOr:
    error "Failed to initialize persistency instance", error = $error
    return err("Failed to initialize persistency instance: " & $error)

  (await startNode(waku.node, waku.conf, waku.dynamicBootstrapNodes)).isOkOr:
    return err("error while calling startNode: " & $error)

  let bound = getPorts(waku.node.switch.peerInfo.listenAddrs).valueOr:
    return err("failed to read bound ports from switch: " & $error)
  waku.node.ports.tcp = bound.tcpPort.get(Port(0)).uint16
  waku.node.ports.webSocket = bound.websocketPort.get(Port(0)).uint16
  waku.node.ports.quic = bound.quicPort.get(Port(0)).uint16

  ## Discv5
  if conf.discv5Conf.isSome():
    waku.wakuDiscV5 = (
      await waku_discv5.setupAndStartDiscv5(
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
    ).valueOr:
      return err("failed to start waku discovery v5: " & error)

    waku.node.ports.discv5Udp = waku.wakuDiscV5.udpPort.uint16
    waku.conf.discv5Conf.get().udpPort = waku.wakuDiscV5.udpPort

  ## Update waku data that is set dynamically on node start
  try:
    (await updateWaku(waku)).isOkOr:
      return err("Error in start: " & $error)
  except CatchableError:
    return err("Caught exception in start: " & getCurrentExceptionMsg())

  waku.node.subscriptionManager.subscribeAllAutoshards().isOkOr:
    return err("failed to auto-subscribe autosharding shards: " & $error)

  ## Health Monitor
  waku.healthMonitor.startHealthMonitor().isOkOr:
    return err("failed to start health monitor: " & $error)

  ## Setup RequestConnectionStatus provider

  RequestConnectionStatus.setProvider(
    globalBrokerContext(),
    proc(): Result[RequestConnectionStatus, string] =
      try:
        let healthReport = waku.healthMonitor.getSyncNodeHealthReport()
        return
          ok(RequestConnectionStatus(connectionStatus: healthReport.connectionStatus))
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
          await waku.healthMonitor.getProtocolHealthInfo(protocol)
        return ok(RequestProtocolHealth(healthStatus: protocolHealthStatus))
      except CatchableError:
        return err("Failed to get protocol health: " & getCurrentExceptionMsg()),
  ).isOkOr:
    error "Failed to set RequestProtocolHealth provider", error = error

  ## Setup RequestHealthReport provider

  RequestHealthReport.setProvider(
    globalBrokerContext(),
    proc(): Future[Result[RequestHealthReport, string]] {.async.} =
      try:
        let report = await waku.healthMonitor.getNodeHealthReport()
        return ok(RequestHealthReport(healthReport: report))
      except CatchableError:
        return err("Failed to get health report: " & getCurrentExceptionMsg()),
  ).isOkOr:
    error "Failed to set RequestHealthReport provider", error = error

  if conf.restServerConf.isSome():
    rest_server_builder.startRestServerProtocolSupport(
      waku.restServer,
      waku.node,
      waku.wakuDiscv5,
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
      let (server, port) = (
        await waku_metrics.startMetricsServerAndLogging(
          conf.metricsServerConf.get(), conf.portsShift
        )
      ).valueOr:
        return err("Starting monitoring and external interfaces failed: " & error)
      waku.metricsServer = server
      waku.node.ports.metrics = port.uint16
      waku.conf.metricsServerConf.get().httpPort = port
    except CatchableError:
      return err(
        "Caught exception starting monitoring and external interfaces failed: " &
          getCurrentExceptionMsg()
      )
  waku.healthMonitor.setOverallHealth(HealthStatus.READY)

  return ok()

proc stop*(waku: Waku): Future[Result[void, string]] {.async: (raises: []).} =
  if not waku.node.started:
    warn "stop: attempting to stop node that isn't running"

  try:
    waku.healthMonitor.setOverallHealth(HealthStatus.SHUTTING_DOWN)

    Persistency.reset()

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

## Kernel API realization
##
# --- topic construction ---
proc buildContentTopic*(
    self: Waku, appName: string, appVersion: uint32, name: string, encoding: string
): Future[Result[ContentTopic, string]] {.async.} =
  try:
    return ok(ContentTopic(fmt"/{appName}/{appVersion}/{name}/{encoding}"))
  except CatchableError as e:
    return err(e.msg)

proc buildPubsubTopic*(
    self: Waku, topicName: string
): Future[Result[PubsubTopic, string]] {.async.} =
  try:
    return ok(PubsubTopic(fmt"/waku/2/{topicName}"))
  except CatchableError as e:
    return err(e.msg)

proc defaultPubsubTopic*(self: Waku): Future[Result[PubsubTopic, string]] {.async.} =
  return ok(DefaultPubsubTopic)

# --- relay ---
proc relayPublish*(
    self: Waku, pubsubTopic: PubsubTopic, message: WakuMessage, timeoutMs: uint32
): Future[Result[int, string]] {.async.} =
  try:
    if self.node.wakuRelay.isNil():
      return err("relayPublish: WakuRelay not mounted")

    let numPeers = (await self.node.wakuRelay.publish(pubsubTopic, message)).valueOr:
      return err($error)

    return ok(numPeers)
  except CatchableError as e:
    return err(e.msg)

proc relaySubscribe*(
    self: Waku, pubsubTopic: PubsubTopic
): Future[Result[bool, string]] {.async.} =
  try:
    if self.node.wakuRelay.isNil():
      return err("relaySubscribe: WakuRelay not mounted")

    self.node.subscribe(
      (kind: SubscriptionKind.PubsubSub, topic: pubsubTopic), WakuRelayHandler(nil)
    ).isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc relayUnsubscribe*(
    self: Waku, pubsubTopic: PubsubTopic
): Future[Result[bool, string]] {.async.} =
  try:
    if self.node.wakuRelay.isNil():
      return err("relayUnsubscribe: WakuRelay not mounted")

    self.node.unsubscribe((kind: SubscriptionKind.PubsubSub, topic: pubsubTopic)).isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc relayAddProtectedShard*(
    self: Waku, clusterId: uint16, shardId: uint16, publicKey: string
): Future[Result[bool, string]] {.async.} =
  try:
    if self.node.wakuRelay.isNil():
      return err("relayAddProtectedShard: WakuRelay not mounted")

    let pubKey = SkPublicKey.fromHex(publicKey).valueOr:
      return err("relayAddProtectedShard: invalid public key: " & $error)

    let protectedShard = ProtectedShard(shard: shardId, key: pubKey)
    self.node.wakuRelay.addSignedShardsValidator(@[protectedShard], clusterId)
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc relayConnectedPeers*(
    self: Waku, pubsubTopic: PubsubTopic
): Future[Result[seq[string], string]] {.async.} =
  try:
    if self.node.wakuRelay.isNil():
      return err("relayConnectedPeers: WakuRelay not mounted")

    let connPeers = self.node.wakuRelay.getConnectedPeers(pubsubTopic).valueOr:
      return err($error)

    return ok(connPeers.mapIt($it))
  except CatchableError as e:
    return err(e.msg)

proc relayPeersInMesh*(
    self: Waku, pubsubTopic: PubsubTopic
): Future[Result[seq[string], string]] {.async.} =
  try:
    if self.node.wakuRelay.isNil():
      return err("relayPeersInMesh: WakuRelay not mounted")

    let meshPeers = self.node.wakuRelay.getPeersInMesh(pubsubTopic).valueOr:
      return err($error)

    return ok(meshPeers.mapIt($it))
  except CatchableError as e:
    return err(e.msg)

# --- filter ---
proc filterSubscribe*(
    self: Waku,
    pubsubTopic: Option[PubsubTopic],
    contentTopics: seq[ContentTopic],
    peer: string,
): Future[Result[bool, string]] {.async.} =
  try:
    if self.node.wakuFilterClient.isNil():
      return err("wakuFilterClient is not mounted")

    let subFut = self.node.filterSubscribe(pubsubTopic, contentTopics, peer)
    if not await subFut.withTimeout(FilterOpTimeout):
      return err("filter subscription timed out")
    subFut.read().isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc filterUnsubscribe*(
    self: Waku,
    pubsubTopic: Option[PubsubTopic],
    contentTopics: seq[ContentTopic],
    peer: string,
): Future[Result[bool, string]] {.async.} =
  try:
    if self.node.wakuFilterClient.isNil():
      return err("wakuFilterClient is not mounted")

    let unsubFut = self.node.filterUnsubscribe(pubsubTopic, contentTopics, peer)
    if not await unsubFut.withTimeout(FilterOpTimeout):
      return err("filter un-subscription timed out")
    unsubFut.read().isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc filterUnsubscribeAll*(
    self: Waku, peer: string
): Future[Result[bool, string]] {.async.} =
  try:
    if self.node.wakuFilterClient.isNil():
      return err("wakuFilterClient is not mounted")

    let unsubFut = self.node.filterUnsubscribeAll(peer)
    if not await unsubFut.withTimeout(FilterOpTimeout):
      return err("filter un-subscription all timed out")
    unsubFut.read().isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

# --- lightpush ---
proc lightpushPublish*(
    self: Waku, pubsubTopic: PubsubTopic, message: WakuMessage, peer: string
): Future[Result[string, string]] {.async.} =
  try:
    if self.node.wakuLegacyLightpushClient.isNil():
      return err("wakuLegacyLightpushClient is not mounted")

    let remotePeer = parsePeerInfo(peer).valueOr:
      return err("lightpushPublish failed to parse peer addr: " & $error)

    let msgHashHex = (
      await self.node.wakuLegacyLightpushClient.publish(
        pubsubTopic, message, remotePeer
      )
    ).valueOr:
      return err($error)

    return ok(msgHashHex)
  except CatchableError as e:
    return err(e.msg)

# --- store ---
proc storeQuery*(
    self: Waku, request: StoreQueryRequest, peer: string, timeoutMs: int
): Future[Result[StoreQueryResponse, string]] {.async.} =
  try:
    if self.node.wakuStoreClient.isNil():
      return err("wakuStoreClient is not mounted")

    let remotePeer = parsePeerInfo(peer).valueOr:
      return err("storeQuery failed to parse peer addr: " & $error)

    let queryFut = self.node.wakuStoreClient.query(request, remotePeer)
    if not await queryFut.withTimeout(timeoutMs.milliseconds):
      return err("storeQuery timed out")

    let queryResponse = queryFut.read().valueOr:
      return err("storeQuery failed: " & $error)

    return ok(queryResponse)
  except CatchableError as e:
    return err(e.msg)

# --- peer management ---
proc connect*(
    self: Waku, peers: seq[string], timeoutMs: uint32
): Future[Result[bool, string]] {.async.} =
  try:
    await self.node.connectToNodes(peers.mapIt(strip(it)), source = "static")
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc disconnectPeerById*(
    self: Waku, peerId: string
): Future[Result[bool, string]] {.async.} =
  try:
    let pId = PeerId.init(peerId).valueOr:
      return err($error)
    await self.node.peerManager.disconnectNode(pId)
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc disconnectAllPeers*(self: Waku): Future[Result[bool, string]] {.async.} =
  try:
    await self.node.peerManager.disconnectAllPeers()
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc dialPeer*(
    self: Waku, peerAddr: string, protocol: string, timeoutMs: int
): Future[Result[bool, string]] {.async.} =
  try:
    let remotePeerInfo = parsePeerInfo(peerAddr).valueOr:
      return err($error)
    let conn = await self.node.peerManager.dialPeer(remotePeerInfo, protocol)
    if conn.isNone():
      return err("failed dialing peer")
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc dialPeerById*(
    self: Waku, peerId: string, protocol: string, timeoutMs: int
): Future[Result[bool, string]] {.async.} =
  try:
    let pId = PeerId.init(peerId).valueOr:
      return err($error)
    let conn = await self.node.peerManager.dialPeer(pId, protocol)
    if conn.isNone():
      return err("failed dialing peer")
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc peerIdsFromPeerstore*(self: Waku): Future[Result[seq[string], string]] {.async.} =
  try:
    return ok(self.node.peerManager.switch.peerStore.peers().mapIt($it.peerId))
  except CatchableError as e:
    return err(e.msg)

proc connectedPeersInfo*(self: Waku): Future[Result[seq[string], string]] {.async.} =
  try:
    return ok(
      self.node.peerManager.switch.peerStore
        .peers()
        .filterIt(it.connectedness == Connected)
        .mapIt($it.peerId)
    )
  except CatchableError as e:
    return err(e.msg)

proc connectedPeers*(self: Waku): Future[Result[seq[string], string]] {.async.} =
  try:
    let (inPeerIds, outPeerIds) = self.node.peerManager.connectedPeers()
    return ok(concat(inPeerIds, outPeerIds).mapIt($it))
  except CatchableError as e:
    return err(e.msg)

proc peerIdsByProtocol*(
    self: Waku, protocol: string
): Future[Result[seq[string], string]] {.async.} =
  try:
    return ok(
      self.node.peerManager.switch.peerStore
        .peers(protocol)
        .filterIt(it.connectedness == Connected)
        .mapIt($it.peerId)
    )
  except CatchableError as e:
    return err(e.msg)

# --- discovery ---
proc dnsDiscovery*(
    self: Waku, enrTreeUrl: string, nameServer: string, timeoutMs: int
): Future[Result[seq[string], string]] {.async.} =
  try:
    let dnsNameServers = @[parseIpAddress(nameServer)]
    let discoveredPeers = (
      await retrieveDynamicBootstrapNodes(enrTreeUrl, dnsNameServers)
    ).valueOr:
      return err("failed discovering peers from DNS: " & $error)

    var multiAddresses = newSeq[string]()
    for discPeer in discoveredPeers:
      for address in discPeer.addrs:
        multiAddresses.add($address & "/p2p/" & $discPeer)

    return ok(multiAddresses)
  except CatchableError as e:
    return err(e.msg)

proc discv5UpdateBootnodes*(
    self: Waku, bootnodes: seq[string]
): Future[Result[bool, string]] {.async.} =
  try:
    if self.wakuDiscv5.isNil():
      return err("discv5 not started")
    let jsonArray = "[" & bootnodes.mapIt("\"" & it & "\"").join(",") & "]"
    self.wakuDiscv5.updateBootstrapRecords(jsonArray).isOkOr:
      return err("error in discv5UpdateBootnodes: " & $error)
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc startDiscv5*(self: Waku): Future[Result[bool, string]] {.async.} =
  try:
    if self.wakuDiscv5.isNil():
      return err("discv5 not started")
    (await self.wakuDiscv5.start()).isOkOr:
      return err("error starting discv5: " & $error)
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc stopDiscv5*(self: Waku): Future[Result[bool, string]] {.async.} =
  try:
    if self.wakuDiscv5.isNil():
      return err("discv5 not started")
    await self.wakuDiscv5.stop()
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc peerExchangeRequest*(
    self: Waku, numPeers: uint64
): Future[Result[int, string]] {.async.} =
  try:
    let numPeersRecv = (await self.node.fetchPeerExchangePeers(numPeers)).valueOr:
      return err("failed peer exchange: " & $error)
    return ok(numPeersRecv)
  except CatchableError as e:
    return err(e.msg)

# --- debug / info ---
proc version*(self: Waku): Future[Result[string, string]] {.async.} =
  return ok(WakuNodeVersionString)

proc listenAddresses*(self: Waku): Future[Result[seq[string], string]] {.async.} =
  try:
    return ok(self.node.info().listenAddresses)
  except CatchableError as e:
    return err(e.msg)

proc myEnr*(self: Waku): Future[Result[string, string]] {.async.} =
  try:
    return ok(self.node.enr.toURI())
  except CatchableError as e:
    return err(e.msg)

proc myPeerId*(self: Waku): Future[Result[string, string]] {.async.} =
  try:
    return ok($self.node.peerId())
  except CatchableError as e:
    return err(e.msg)

proc metrics*(self: Waku): Future[Result[string, string]] {.async.} =
  {.gcsafe.}:
    try:
      return ok(defaultRegistry.toText())
    except CatchableError as e:
      return err(e.msg)

proc pingPeer*(
    self: Waku, peerAddr: string, timeoutMs: int
): Future[Result[int64, string]] {.async.} =
  try:
    let peerInfo = parsePeerInfo(peerAddr).valueOr:
      return err("pingPeer failed to parse peer addr: " & $error)

    let conn = await self.node.switch.dial(peerInfo.peerId, peerInfo.addrs, PingCodec)
    defer:
      await conn.close()
    let pingRTT = await self.node.libp2pPing.ping(conn)

    if pingRTT == 0.nanos:
      return err("could not ping peer: rtt-0")

    return ok(pingRTT.nanos)
  except CatchableError as e:
    return err(e.msg)

{.pop.}

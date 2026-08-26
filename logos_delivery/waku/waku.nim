{.push raises: [].}

import
  std/[sequtils, strformat],
  results,
  chronicles,
  chronos,
  libp2p/protocols/connectivity/relay/relay,
  libp2p/protocols/connectivity/relay/client,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/ping,
  libp2p/services/autorelayservice,
  libp2p/services/hpservice,
  libp2p/peerid,
  libp2p/wire,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  presto,
  metrics,
  metrics/chronos_httpserver,
  brokers/broker_context,
  logos_delivery/api/types,
  logos_delivery/api/kernel_api,
  logos_delivery/waku/[
    waku_core,
    waku_node,
    waku_archive,
    rln,
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

# Surfaces the Kernel API interface to consumers of the Waku layer.
# `MessageSeenEvent` now lives in `events/kernel_events` (surfaced by the concentrator).
export kernel_api

logScope:
  topics = "wakunode waku"

# Git version in git describe format (defined at compile time)
const git_version* {.strdefine.} = "n/a"

type Waku* = ref object ## Implements `KernelApi` (ops in `waku/api/*`).
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

  persistency*: Persistency

proc setupSwitchServices*(
    node: WakuNode, conf: WakuConf, circuitRelay: Relay, rng: crypto.Rng
) =
  proc onReservation(addresses: seq[MultiAddress]) {.gcsafe, raises: [].} =
    ## This callback only logs the change. When a reservation drops, libp2p
    ## keeps peerInfo unchanged and the route stays until the next update.
    info "circuit relay reservation change", addrs = $addresses

  let autonatService = getAutonatService(rng)
  let newService =
    if conf.circuitRelayClient:
      ## The node assumes it is behind NAT.
      ## It requests circuit-relay reservations to stay reachable.
      const MaxNumRelayServers = 2
      let autoRelayService = AutoRelayService.new(
        MaxNumRelayServers, RelayClient(circuitRelay), onReservation, rng
      )
      Service(HPService.new(autonatService, autoRelayService))
    else:
      Service(autonatService)

  node.switch.services.add(newService)

  # libp2p runs Service.setup only at build time.
  # This service attaches after build, so run its setup here.
  try:
    newService.setup(node.switch)
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
        healthMonitor, wakuConf.restServerConf.get()
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

  node.setupAppCallbacks(wakuConf, appCallbacks, healthMonitor).isOkOr:
    error "Failed setting up app callbacks", error = error
    return err("Failed setting up app callbacks: " & $error)

  var waku = Waku(
    stateInfo: WakuStateInfo.init(node, wakuConf),
    conf: wakuConf,
    rng: rng,
    key: wakuConf.nodeKey,
    node: node,
    healthMonitor: healthMonitor,
    appCallbacks: appCallbacks,
    restServer: restServer,
    brokerCtx: brokerCtx,
  )

  waku.node.setupSwitchServices(wakuConf, relay, rng)

  ok(waku)

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

  # Rebuild NetConfig from the bound ports already read back into `conf`.
  let netConf = (
    await networkConfiguration(
      conf.clusterId, conf.endpointConf, conf.discv5Conf, conf.webSocketConf,
      conf.quicConf, conf.wakuFlags, conf.dnsAddrsNameServers,
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

  return ok()

proc refreshEnrAddrs*(
    node: WakuNode, key: crypto.PrivateKey, wakuDiscv5: WakuDiscoveryV5
): Result[void, string] =
  ## Write the announced addresses into the ENR multiaddrs field.
  ## With discv5, update its live record and copy the result back.
  let addrs =
    node.announcedAddresses.filterIt(it.isCircuitRelayMA()) &
    node.announcedAddresses.filterIt(not it.isCircuitRelayMA())

  ## Dropping tail entries only helps when the record is too large.
  ## An empty set writes an empty field. A key or record failure also
  ## fails on the empty list and returns err.
  if not wakuDiscv5.isNil():
    for retained in countdown(addrs.len, 0):
      let encoded = multiaddr.encodeMultiaddrs(addrs[0 ..< retained])
      if wakuDiscv5.protocol.updateRecord([(MultiaddrEnrField, encoded)]).isOk():
        node.enr = wakuDiscv5.protocol.localNode.record
        debug "ENR multiaddrs updated", retained = retained, total = addrs.len
        return ok()
    return err("failed to update ENR multiaddrs at every prefix")

  let keyBytes = key.getRawBytes().valueOr:
    return err("failed to retrieve raw bytes from waku key: " & $error)
  let parsedPk = keys.PrivateKey.fromHex(keyBytes.toHex()).valueOr:
    return err("failed to parse the private key: " & $error)
  for retained in countdown(addrs.len, 0):
    let encoded = multiaddr.encodeMultiaddrs(addrs[0 ..< retained])
    let fields = @[toFieldPair(MultiaddrEnrField, encoded)]
    if node.enr.update(parsedPk, extraFields = fields).isOk():
      debug "ENR multiaddrs updated", retained = retained, total = addrs.len
      return ok()
  return err("failed to update ENR multiaddrs at every prefix")

proc updateWaku(waku: Waku): Future[Result[void, string]] {.async.} =
  (await updateEnr(waku)).isOkOr:
    return err("error calling updateEnr: " & $error)

  if not waku.wakuDiscv5.isNil():
    ## Copy the startup ENR into the live discv5 record once. Shard updates
    ## and multiaddr refreshes then update that record in place.
    waku.wakuDiscv5.protocol.localNode.record = waku.node.enr

  ?refreshEnrAddrs(waku.node, waku.key, waku.wakuDiscv5)

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
        debug "Retrieving dynamic bootstrap nodes failed", error = error
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
      debug "Failed to connect to dynamic bootstrap nodes",
        error = getCurrentExceptionMsg()
    return

proc closePersistency(waku: Waku) =
  ## Clear the GetPersistency provider and close the instance (joins any
  ## job worker threads). Idempotent; shared by `stop` and a failed `start`.
  GetPersistency.clearProvider(waku.brokerCtx)
  if not waku.persistency.isNil():
    waku.persistency.close()
    waku.persistency = nil

proc start*(waku: Waku): Future[Result[void, string]] {.async: (raises: []).} =
  if waku.node.started:
    debug "start: waku node already started"
    return ok()

  info "Retrieve dynamic bootstrap nodes"
  let conf = waku.conf

  ## Create this node's Persistency instance and provide it under the node's
  ## BrokerContext first, so any later startup stage can restore persisted
  ## state through it. Inert until the first openJob. The defer below tears
  ## it down again on every one of start's error return paths.
  waku.persistency = Persistency.new(conf.localStoragePath).valueOr:
    error "Failed to initialize persistency instance", error = $error
    return err("Failed to initialize persistency instance: " & $error)
  discard GetPersistency.reprovideIt(waku.brokerCtx):
    ok(waku.persistency)

  var startSucceeded = false
  defer:
    if not startSucceeded:
      waku.closePersistency()

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
      info "Retrieving dynamic bootstrap nodes failed, starting retry loop",
        error = dynamicBootstrapNodesRes.error
      waku.dnsRetryLoopHandle = waku.startDnsDiscoveryRetryLoop()
    else:
      waku.dynamicBootstrapNodes = dynamicBootstrapNodesRes.get()

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
      )
    ).valueOr:
      return err("failed to start waku discovery v5: " & error)

    waku.node.ports.discv5Udp = waku.wakuDiscV5.udpPort.uint16
    waku.conf.discv5Conf.get().udpPort = waku.wakuDiscV5.udpPort

  ## Set the callback before the explicit refresh in updateWaku,
  ## so a commit in between reaches the ENR.
  waku.node.onCommittedAddresses = proc() {.gcsafe, raises: [].} =
    refreshEnrAddrs(waku.node, waku.key, waku.wakuDiscv5).isOkOr:
      error "failed to refresh ENR multiaddrs", error = $error

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
        await waku_metrics.startMetricsServerAndLogging(conf.metricsServerConf.get())
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

  startSucceeded = true
  return ok()

proc stop*(waku: Waku): Future[Result[void, string]] {.async: (raises: []).} =
  if not waku.node.started:
    debug "stop: attempting to stop node that isn't running"

  try:
    waku.healthMonitor.setOverallHealth(HealthStatus.SHUTTING_DOWN)

    waku.closePersistency()

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

    ## Clear all providers registered in start() so a later start() can re-set them.
    RequestConnectionStatus.clearProvider(waku.brokerCtx)
    RequestProtocolHealth.clearProvider(waku.brokerCtx)
    RequestHealthReport.clearProvider(waku.brokerCtx)

    if not waku.restServer.isNil():
      await waku.restServer.stop()
  except Exception:
    error "Waku stop failed", error = getCurrentExceptionMsg()
    return err("waku stop failed: " & getCurrentExceptionMsg())

  return ok()

{.pop.}

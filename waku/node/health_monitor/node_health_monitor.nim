{.push raises: [].}

import
  std/[options, sets, random, sequtils, json, strutils, tables],
  chronos,
  chronicles,
  libp2p/protocols/rendezvous,
  libp2p/protocols/pubsub,
  libp2p/protocols/pubsub/rpc/messages

import
  ../waku_node,
  ../kernel_api,
  ../../waku_rln_relay,
  ../../waku_relay,
  ../peer_manager,
  ./online_monitor,
  ./health_status,
  ./connection_status,
  ./protocol_health

## This module is aimed to check the state of the "self" Waku Node

# randomize initializes sdt/random's random number generator
# if not called, the outcome of randomization procedures will be the same in every run
random.randomize()

const
  DefaultRelayFailoverThreshold* = 4
  FailoverThreshold* = 2

type
  HealthReport* = object
    ## Rest API type returned for /health endpoint
    ##
    nodeHealth*: HealthStatus # legacy "READY" health indicator
    connectionStatus*: ConnectionStatus # new "Connected" health indicator
    protocolsHealth*: seq[ProtocolHealth]

  NodeHealthMonitor* = ref object
    nodeHealth: HealthStatus
    node: WakuNode
    onlineMonitor*: OnlineMonitor
    keepAliveFut: Future[void]
    healthLoopFut: Future[void]
    healthUpdateEvent: AsyncEvent
    connectionStatus: ConnectionStatus
    onConnectionStatusChange*: ConnectionStatusChangeHandler
    cachedProtocols: seq[ProtocolHealth]
    strength: Table[WakuProtocol, int]
    relayObserver: PubSubObserver

func getHealth*(report: HealthReport, kind: WakuProtocol): ProtocolHealth =
  for h in report.protocolsHealth:
    if h.protocol == $kind:
      return h
  # Shouldn't happen, but if it does, then assume protocol is not mounted
  return ProtocolHealth.init(kind)

proc countConnectedPeers(hm: NodeHealthMonitor, codec: string): int =
  if isNil(hm.node) or isNil(hm.node.peerManager):
    return 0

  var peerCount = 0
  for remotePeerInfo in hm.node.peerManager.switch.peerStore.peers(codec):
    if hm.node.peerManager.switch.isConnected(remotePeerInfo.peerId):
      peerCount.inc()
  return peerCount

template checkWakuNodeNotNil(node: WakuNode, p: ProtocolHealth): untyped =
  if isNil(node):
    warn "WakuNode is not set, cannot check health", protocol_health_instance = $p
    return p.notMounted()

proc getRelayFailoverThreshold(hm: NodeHealthMonitor): int =
  if isNil(hm.node.wakuRelay):
    # Could return an Optional[int] instead, but for simplicity just use a default.
    # This also helps in writing mocks for the health monitor tests.
    return DefaultRelayFailoverThreshold
  return hm.node.wakuRelay.parameters.dLow

proc getRelayHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(WakuProtocol.RelayProtocol)
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuRelay == nil:
    hm.strength[WakuProtocol.RelayProtocol] = 0
    return p.notMounted()

  let relayPeers = hm.node.wakuRelay.getConnectedPubSubPeers(pubsubTopic = "").valueOr:
    hm.strength[WakuProtocol.RelayProtocol] = 0
    return p.notMounted()

  let count = relayPeers.len()
  hm.strength[WakuProtocol.RelayProtocol] = count
  if count == 0:
    return p.notReady("No connected peers")

  return p.ready()

proc getRlnRelayHealth(hm: NodeHealthMonitor): Future[ProtocolHealth] {.async.} =
  var p = ProtocolHealth.init(WakuProtocol.RlnRelayProtocol)
  if isNil(hm.node):
    warn "WakuNode is not set, cannot check health", protocol_health_instance = $p
    return p.notMounted()

  if isNil(hm.node.wakuRlnRelay):
    return p.notMounted()

  const FutIsReadyTimout = 5.seconds

  let isReadyStateFut = hm.node.wakuRlnRelay.isReady()
  if not await isReadyStateFut.withTimeout(FutIsReadyTimout):
    return p.notReady("Ready state check timed out")

  try:
    if not isReadyStateFut.completed():
      return p.notReady("Ready state check timed out")
    elif isReadyStateFut.read():
      return p.ready()

    return p.synchronizing()
  except:
    error "exception reading state: " & getCurrentExceptionMsg()
    return p.notReady("State cannot be determined")

proc getLightpushHealth(
    hm: NodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init(WakuProtocol.LightpushProtocol)
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuLightPush == nil:
    hm.strength[WakuProtocol.LightpushProtocol] = 0
    return p.notMounted()

  let peerCount = countConnectedPeers(hm, WakuLightPushCodec)
  hm.strength[WakuProtocol.LightpushProtocol] = peerCount

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Node has no relay peers to fullfill push requests")

proc getLegacyLightpushHealth(
    hm: NodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init(WakuProtocol.LegacyLightpushProtocol)
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuLegacyLightPush == nil:
    hm.strength[WakuProtocol.LegacyLightpushProtocol] = 0
    return p.notMounted()

  let peerCount = countConnectedPeers(hm, WakuLegacyLightPushCodec)
  hm.strength[WakuProtocol.LegacyLightpushProtocol] = peerCount

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Node has no relay peers to fullfill push requests")

proc getFilterHealth(hm: NodeHealthMonitor, relayHealth: HealthStatus): ProtocolHealth =
  var p = ProtocolHealth.init(WakuProtocol.FilterProtocol)
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuFilter == nil:
    hm.strength[WakuProtocol.FilterProtocol] = 0
    return p.notMounted()

  let peerCount = countConnectedPeers(hm, WakuFilterSubscribeCodec)
  hm.strength[WakuProtocol.FilterProtocol] = peerCount

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Relay is not ready, filter will not be able to sort out messages")

proc getStoreHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(WakuProtocol.StoreProtocol)
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuStore == nil:
    hm.strength[WakuProtocol.StoreProtocol] = 0
    return p.notMounted()

  let peerCount = countConnectedPeers(hm, WakuStoreCodec)
  hm.strength[WakuProtocol.StoreProtocol] = peerCount
  return p.ready()

proc getLegacyStoreHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(WakuProtocol.LegacyStoreProtocol)
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuLegacyStore == nil:
    hm.strength[WakuProtocol.LegacyStoreProtocol] = 0
    return p.notMounted()

  let peerCount = hm.node.peerManager.switch.peerStore.peers(WakuLegacyStoreCodec).len
  hm.strength[WakuProtocol.LegacyStoreProtocol] = peerCount
  return p.ready()

proc getLightpushClientHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(WakuProtocol.LightpushClientProtocol)
  checkWakuNodeNotNil(hm.node, p)

  if isNil(hm.node.wakuLightpushClient):
    hm.strength[WakuProtocol.LightpushClientProtocol] = 0
    return p.notMounted()

  let peerCount = countConnectedPeers(hm, WakuLightPushCodec)
  hm.strength[WakuProtocol.LightpushClientProtocol] = peerCount

  if peerCount > 0:
    return p.ready()
  return p.notReady("No Lightpush service peer available yet")

proc getLegacyLightpushClientHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(WakuProtocol.LegacyLightpushClientProtocol)
  checkWakuNodeNotNil(hm.node, p)

  if isNil(hm.node.wakuLegacyLightpushClient):
    hm.strength[WakuProtocol.LegacyLightpushClientProtocol] = 0
    return p.notMounted()

  let peerCount = countConnectedPeers(hm, WakuLegacyLightPushCodec)
  hm.strength[WakuProtocol.LegacyLightpushClientProtocol] = peerCount

  if peerCount > 0:
    return p.ready()
  return p.notReady("No Lightpush service peer available yet")

proc getFilterClientHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(WakuProtocol.FilterClientProtocol)
  checkWakuNodeNotNil(hm.node, p)
  if hm.node.wakuFilterClient == nil:
    hm.strength[WakuProtocol.FilterClientProtocol] = 0
    return p.notMounted()

  let peerCount = countConnectedPeers(hm, WakuFilterSubscribeCodec)
  hm.strength[WakuProtocol.FilterClientProtocol] = peerCount

  if peerCount > 0:
    return p.ready()
  return p.notReady("No Filter service peer available yet")

proc getStoreClientHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(WakuProtocol.StoreClientProtocol)
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuStoreClient == nil:
    hm.strength[WakuProtocol.StoreClientProtocol] = 0
    return p.notMounted()

  let peerCount = countConnectedPeers(hm, WakuStoreCodec)
  hm.strength[WakuProtocol.StoreClientProtocol] = peerCount

  if peerCount > 0 or hm.node.wakuStore != nil:
    return p.ready()

  return p.notReady(
    "No Store service peer available yet, neither Store service set up for the node"
  )

proc getLegacyStoreClientHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(WakuProtocol.LegacyStoreClientProtocol)
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuLegacyStoreClient == nil:
    hm.strength[WakuProtocol.LegacyStoreClientProtocol] = 0
    return p.notMounted()

  let peerCount = countConnectedPeers(hm, WakuLegacyStoreCodec)
  hm.strength[WakuProtocol.LegacyStoreClientProtocol] = peerCount

  if peerCount > 0 or hm.node.wakuLegacyStore != nil:
    return p.ready()

  return p.notReady(
    "No Legacy Store service peers are available yet, neither Store service set up for the node"
  )

proc getPeerExchangeHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(WakuProtocol.PeerExchangeProtocol)
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuPeerExchange == nil:
    hm.strength[WakuProtocol.PeerExchangeProtocol] = 0
    return p.notMounted()

  let peerCount = countConnectedPeers(hm, WakuPeerExchangeCodec)
  hm.strength[WakuProtocol.PeerExchangeProtocol] = peerCount

  return p.ready()

proc getRendezvousHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(WakuProtocol.RendezvousProtocol)
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuRendezvous == nil:
    hm.strength[WakuProtocol.RendezvousProtocol] = 0
    return p.notMounted()

  let peerCount = countConnectedPeers(hm, RendezVousCodec)
  hm.strength[WakuProtocol.RendezvousProtocol] = peerCount
  if peerCount == 0:
    return p.notReady("No Rendezvous peers are available yet")

  return p.ready()

proc getMixHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(WakuProtocol.MixProtocol)
  checkWakuNodeNotNil(hm.node, p)

  if isNil(hm.node.wakuMix):
    return p.notMounted()

  return p.ready()

proc calculateConnectionState*(
    protocols: seq[ProtocolHealth],
    strength: Table[WakuProtocol, int],
    relayFailoverThreshold: int,
): ConnectionStatus =
  var
    relayCount = 0
    lightpushCount = 0
    filterCount = 0
    storeClientCount = 0

  for p in protocols:
    let kind =
      try:
        parseEnum[WakuProtocol](p.protocol)
      except ValueError:
        continue

    if p.health != HealthStatus.READY:
      continue

    let strength = strength.getOrDefault(kind, 0)

    if kind in RelayProtocols:
      relayCount = max(relayCount, strength)
    elif kind in StoreClientProtocols:
      storeClientCount = max(storeClientCount, strength)
    elif kind in LightpushClientProtocols:
      lightpushCount = max(lightpushCount, strength)
    elif kind in FilterClientProtocols:
      filterCount = max(filterCount, strength)

  # Relay connectivity should be a sufficient check in Core mode.
  # "Store peers" are relay peers because incoming messages in
  # the relay are input to the store server.
  # But if Store server (or client, even) is not mounted as well, this logic assumes
  # the user knows what they're doing.

  if relayCount >= relayFailoverThreshold:
    return ConnectionStatus.Connected

  if relayCount > 0:
    return ConnectionStatus.PartiallyConnected

  # No relay connectivity. Relay might not be mounted, or may just have zero peers.
  # Fall back to Edge check in any case to be sure.

  let canSend = lightpushCount > 0
  let canReceive = filterCount > 0
  let canStore = storeClientCount > 0

  let meetsMinimum = canSend and canReceive and canStore

  if not meetsMinimum:
    return ConnectionStatus.Disconnected

  let isEdgeRobust =
    (lightpushCount >= FailoverThreshold) and (filterCount >= FailoverThreshold) and
    (storeClientCount >= FailoverThreshold)

  if isEdgeRobust:
    return ConnectionStatus.Connected

  return ConnectionStatus.PartiallyConnected

proc calculateConnectionState*(hm: NodeHealthMonitor): ConnectionStatus =
  return calculateConnectionState(
    hm.cachedProtocols, hm.strength, hm.getRelayFailoverThreshold()
  )

proc getAllProtocolHealthInfo(
    hm: NodeHealthMonitor
): Future[seq[ProtocolHealth]] {.async.} =
  var protocols: seq[ProtocolHealth] = @[]
  let relayHealth = hm.getRelayHealth()
  protocols.add(relayHealth)

  protocols.add(await hm.getRlnRelayHealth())

  protocols.add(hm.getLightpushHealth(relayHealth.health))
  protocols.add(hm.getLegacyLightpushHealth(relayHealth.health))
  protocols.add(hm.getFilterHealth(relayHealth.health))
  protocols.add(hm.getStoreHealth())
  protocols.add(hm.getLegacyStoreHealth())
  protocols.add(hm.getPeerExchangeHealth())
  protocols.add(hm.getRendezvousHealth())
  protocols.add(hm.getMixHealth())

  protocols.add(hm.getLightpushClientHealth())
  protocols.add(hm.getLegacyLightpushClientHealth())
  protocols.add(hm.getStoreClientHealth())
  protocols.add(hm.getLegacyStoreClientHealth())
  protocols.add(hm.getFilterClientHealth())
  return protocols

proc getNodeHealthReport*(hm: NodeHealthMonitor): Future[HealthReport] {.async.} =
  var report: HealthReport

  if isNil(hm.node):
    report.nodeHealth = HealthStatus.INITIALIZING
    report.connectionStatus = ConnectionStatus.Disconnected
    return report

  if hm.nodeHealth == HealthStatus.INITIALIZING or
      hm.nodeHealth == HealthStatus.SHUTTING_DOWN:
    report.nodeHealth = hm.nodeHealth
    report.connectionStatus = ConnectionStatus.Disconnected
    return report

  if hm.cachedProtocols.len == 0:
    hm.cachedProtocols = await hm.getAllProtocolHealthInfo()
  report.protocolsHealth = hm.cachedProtocols

  report.nodeHealth = HealthStatus.READY
  report.connectionStatus = hm.connectionStatus
  return report

proc onPeerEvent(
    hm: NodeHealthMonitor, peerId: PeerId, event: PeerEvent
) {.async.} =
  case event.kind
  of PeerEventKind.Joined, PeerEventKind.Left, PeerEventKind.Identified:
    # recomputing node health when peer connection events of interest trigger
    hm.healthUpdateEvent.fire()
  else:
    discard

proc onRelayMsg(
    hm: NodeHealthMonitor, peer: PubSubPeer, msg: var RPCMsg
) {.gcsafe, raises: [].} =
  if msg.subscriptions.len == 0:
    if msg.control.isNone():
      return
    let ctrl = msg.control.get()
    if ctrl.graft.len == 0 and ctrl.prune.len == 0:
      return

  # recomputing node health when peer relay events of interest trigger
  hm.healthUpdateEvent.fire()

proc healthLoop(hm: NodeHealthMonitor) {.async.} =
  while true:
    try:
      await hm.healthUpdateEvent.wait()
      hm.healthUpdateEvent.clear()

      hm.cachedProtocols = await hm.getAllProtocolHealthInfo()
      let newConnectionStatus = hm.calculateConnectionState()

      if newConnectionStatus != hm.connectionStatus:
        hm.connectionStatus = newConnectionStatus

        if not isNil(hm.onConnectionStatusChange):
          await hm.onConnectionStatusChange(newConnectionStatus)
    except CancelledError:
      break
    except Exception as e:
      error "HealthMonitor: error in update loop", error = e.msg

proc selectRandomPeersForKeepalive(
    node: WakuNode, outPeers: seq[PeerId], numRandomPeers: int
): Future[seq[PeerId]] {.async.} =
  ## Select peers for random keepalive, prioritizing mesh peers

  if isNil(node.wakuRelay):
    return selectRandomPeers(outPeers, numRandomPeers)

  let meshPeers = node.wakuRelay.getPeersInMesh().valueOr:
    error "Failed getting peers in mesh for ping", error = error
    # Fallback to random selection from all outgoing peers
    return selectRandomPeers(outPeers, numRandomPeers)

  trace "Mesh peers for keepalive", meshPeers = meshPeers

  # Get non-mesh peers and shuffle them
  var nonMeshPeers = outPeers.filterIt(it notin meshPeers)
  shuffle(nonMeshPeers)

  # Combine mesh peers + random non-mesh peers up to numRandomPeers total
  let numNonMeshPeers = max(0, numRandomPeers - len(meshPeers))
  let selectedNonMeshPeers = nonMeshPeers[0 ..< min(len(nonMeshPeers), numNonMeshPeers)]

  let selectedPeers = meshPeers & selectedNonMeshPeers
  trace "Selected peers for keepalive", selected = selectedPeers
  return selectedPeers

proc keepAliveLoop(
    node: WakuNode,
    randomPeersKeepalive: chronos.Duration,
    allPeersKeepAlive: chronos.Duration,
    numRandomPeers = 10,
) {.async.} =
  # Calculate how many random peer cycles before pinging all peers
  let randomToAllRatio =
    int(allPeersKeepAlive.seconds() / randomPeersKeepalive.seconds())
  var countdownToPingAll = max(0, randomToAllRatio - 1)

  # Sleep detection configuration
  let sleepDetectionInterval = 3 * randomPeersKeepalive

  # Failure tracking
  var consecutiveIterationFailures = 0
  const maxAllowedConsecutiveFailures = 2

  var lastTimeExecuted = Moment.now()

  while true:
    trace "Running keepalive loop"
    await sleepAsync(randomPeersKeepalive)

    if not node.started:
      continue

    let currentTime = Moment.now()

    # Check for sleep detection
    if currentTime - lastTimeExecuted > sleepDetectionInterval:
      warn "Keep alive hasn't been executed recently. Killing all connections"
      await node.peerManager.disconnectAllPeers()
      lastTimeExecuted = currentTime
      consecutiveIterationFailures = 0
      continue

    # Check for consecutive failures
    if consecutiveIterationFailures > maxAllowedConsecutiveFailures:
      warn "Too many consecutive ping failures, node likely disconnected. Killing all connections",
        consecutiveIterationFailures, maxAllowedConsecutiveFailures
      await node.peerManager.disconnectAllPeers()
      consecutiveIterationFailures = 0
      lastTimeExecuted = currentTime
      continue

    # Determine which peers to ping
    let outPeers = node.peerManager.connectedPeers()[1]
    let peersToPing =
      if countdownToPingAll > 0:
        await selectRandomPeersForKeepalive(node, outPeers, numRandomPeers)
      else:
        outPeers

    let numPeersToPing = len(peersToPing)

    if countdownToPingAll > 0:
      trace "Pinging random peers",
        count = numPeersToPing, countdownToPingAll = countdownToPingAll
      countdownToPingAll.dec()
    else:
      trace "Pinging all peers", count = numPeersToPing
      countdownToPingAll = max(0, randomToAllRatio - 1)

    # Execute keepalive pings
    let successfulPings = await parallelPings(node, peersToPing)

    if successfulPings != numPeersToPing:
      waku_node_errors.inc(
        amount = numPeersToPing - successfulPings, labelValues = ["keep_alive_failure"]
      )

    trace "Keepalive results",
      attemptedPings = numPeersToPing, successfulPings = successfulPings

    # Update failure tracking
    if numPeersToPing > 0 and successfulPings == 0:
      consecutiveIterationFailures.inc()
      error "All pings failed", consecutiveFailures = consecutiveIterationFailures
    else:
      consecutiveIterationFailures = 0

    lastTimeExecuted = currentTime

# 2 minutes default - 20% of the default chronosstream timeout duration
proc startKeepalive*(
    hm: NodeHealthMonitor,
    randomPeersKeepalive = 10.seconds,
    allPeersKeepalive = 2.minutes,
): Result[void, string] =
  # Validate input parameters
  if randomPeersKeepalive.isZero() or allPeersKeepAlive.isZero():
    error "startKeepalive: allPeersKeepAlive and randomPeersKeepalive must be greater than 0",
      randomPeersKeepalive = $randomPeersKeepalive,
      allPeersKeepAlive = $allPeersKeepAlive
    return err(
      "startKeepalive: allPeersKeepAlive and randomPeersKeepalive must be greater than 0"
    )

  if allPeersKeepAlive < randomPeersKeepalive:
    error "startKeepalive: allPeersKeepAlive can't be less than randomPeersKeepalive",
      allPeersKeepAlive = $allPeersKeepAlive,
      randomPeersKeepalive = $randomPeersKeepalive
    return
      err("startKeepalive: allPeersKeepAlive can't be less than randomPeersKeepalive")

  info "starting keepalive",
    randomPeersKeepalive = randomPeersKeepalive, allPeersKeepalive = allPeersKeepalive

  hm.keepAliveFut = hm.node.keepAliveLoop(randomPeersKeepalive, allPeersKeepalive)
  return ok()

proc setNodeToHealthMonitor*(hm: NodeHealthMonitor, node: WakuNode) =
  hm.node = node

proc setOverallHealth*(hm: NodeHealthMonitor, health: HealthStatus) =
  hm.nodeHealth = health

proc startHealthMonitor*(hm: NodeHealthMonitor): Result[void, string] =
  hm.onlineMonitor.startOnlineMonitor()

  if isNil(hm.node):
    return err("startHealthMonitor: no node to monitor")

  if isNil(hm.node.peerManager):
    return err("startHealthMonitor: no node peerManager to monitor")

  if not isNil(hm.node.wakuRelay):
    hm.relayObserver = PubSubObserver(
      onRecv: proc(peer: PubSubPeer, msgs: var RPCMsg) {.gcsafe, raises: [].} =
        hm.onRelayMsg(peer, msgs)
    )
    hm.node.wakuRelay.addObserver(hm.relayObserver)

  proc handlePeerEvent(
      peerId: PeerId, event: PeerEvent
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).} =
    try:
      await hm.onPeerEvent(peerId, event)
    except:
      error "exception in health monitor onPeerEvent: " & getCurrentExceptionMsg()

  hm.node.peerManager.addExtPeerEventHandler(handlePeerEvent, PeerEventKind.Joined)
  hm.node.peerManager.addExtPeerEventHandler(handlePeerEvent, PeerEventKind.Left)
  hm.node.peerManager.addExtPeerEventHandler(handlePeerEvent, PeerEventKind.Identified)

  hm.healthUpdateEvent = newAsyncEvent()
  hm.healthUpdateEvent.fire()

  hm.healthLoopFut = hm.healthLoop()

  hm.startKeepalive().isOkOr:
    return err("startHealthMonitor: failed starting keep alive: " & error)
  return ok()

proc stopHealthMonitor*(hm: NodeHealthMonitor) {.async.} =
  if not isNil(hm.onlineMonitor):
    await hm.onlineMonitor.stopOnlineMonitor()

  if not isNil(hm.keepAliveFut):
    await hm.keepAliveFut.cancelAndWait()

  if not isNil(hm.healthLoopFut):
    await hm.healthLoopFut.cancelAndWait()

  if not isNil(hm.node.wakuRelay) and not isNil(hm.relayObserver):
    hm.node.wakuRelay.removeObserver(hm.relayObserver)

proc new*(
    T: type NodeHealthMonitor,
    dnsNameServers = @[parseIpAddress("1.1.1.1"), parseIpAddress("1.0.0.1")],
): T =
  T(
    nodeHealth: INITIALIZING,
    node: nil,
    onlineMonitor: OnlineMonitor.init(dnsNameServers),
    connectionStatus: ConnectionStatus.Disconnected,
    strength: initTable[WakuProtocol, int](),
  )

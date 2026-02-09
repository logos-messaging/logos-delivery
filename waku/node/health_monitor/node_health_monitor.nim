{.push raises: [].}

import
  std/[options, sets, random, sequtils],
  chronos,
  chronicles,
  libp2p/protocols/rendezvous

import
  ../waku_node,
  ../kernel_api,
  ../../waku_rln_relay,
  ../../waku_relay,
  ../peer_manager,
  ./online_monitor,
  ./health_status,
  ./protocol_health

## This module is aimed to check the state of the "self" Waku Node

# randomize initializes sdt/random's random number generator
# if not called, the outcome of randomization procedures will be the same in every run
randomize()

type
  HealthReport* = object
    nodeHealth*: HealthStatus
    protocolsHealth*: seq[ProtocolHealth]

  NodeHealthMonitor* = ref object
    nodeHealth: HealthStatus
    node: WakuNode
    onlineMonitor*: OnlineMonitor
    keepAliveFut: Future[void]

proc getRelayHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Relay")

  if hm.node.wakuRelay == nil:
    return p.notMounted()

  let relayPeers = hm.node.wakuRelay.getConnectedPubSubPeers(pubsubTopic = "").valueOr:
    return p.notMounted()

  if relayPeers.len() == 0:
    return p.notReady("No connected peers")

  return p.ready()

proc getRlnRelayHealth(hm: NodeHealthMonitor): Future[ProtocolHealth] {.async.} =
  var p = ProtocolHealth.init("Rln Relay")
  if hm.node.wakuRlnRelay.isNil():
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
  var p = ProtocolHealth.init("Lightpush")

  if hm.node.wakuLightPush == nil:
    return p.notMounted()

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Node has no relay peers to fullfill push requests")

proc getLightpushClientHealth(
    hm: NodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init("Lightpush Client")

  if hm.node.wakuLightpushClient == nil:
    return p.notMounted()

  let selfServiceAvailable =
    hm.node.wakuLightPush != nil and relayHealth == HealthStatus.READY
  let servicePeerAvailable = hm.node.peerManager.selectPeer(WakuLightPushCodec).isSome()

  if selfServiceAvailable or servicePeerAvailable:
    return p.ready()

  return p.notReady("No Lightpush service peer available yet")

proc getLegacyLightpushHealth(
    hm: NodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init("Legacy Lightpush")

  if hm.node.wakuLegacyLightPush == nil:
    return p.notMounted()

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Node has no relay peers to fullfill push requests")

proc getLegacyLightpushClientHealth(
    hm: NodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init("Legacy Lightpush Client")

  if hm.node.wakuLegacyLightpushClient == nil:
    return p.notMounted()

  if (hm.node.wakuLegacyLightPush != nil and relayHealth == HealthStatus.READY) or
      hm.node.peerManager.selectPeer(WakuLegacyLightPushCodec).isSome():
    return p.ready()

  return p.notReady("No Lightpush service peer available yet")

proc getFilterHealth(hm: NodeHealthMonitor, relayHealth: HealthStatus): ProtocolHealth =
  var p = ProtocolHealth.init("Filter")

  if hm.node.wakuFilter == nil:
    return p.notMounted()

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Relay is not ready, filter will not be able to sort out messages")

proc getFilterClientHealth(
    hm: NodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init("Filter Client")

  if hm.node.wakuFilterClient == nil:
    return p.notMounted()

  if hm.node.peerManager.selectPeer(WakuFilterSubscribeCodec).isSome():
    return p.ready()

  return p.notReady("No Filter service peer available yet")

proc getStoreHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Store")

  if hm.node.wakuStore == nil:
    return p.notMounted()

  return p.ready()

proc getStoreClientHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Store Client")

  if hm.node.wakuStoreClient == nil:
    return p.notMounted()

  if hm.node.peerManager.selectPeer(WakuStoreCodec).isSome() or hm.node.wakuStore != nil:
    return p.ready()

  return p.notReady(
    "No Store service peer available yet, neither Store service set up for the node"
  )

proc getLegacyStoreHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Legacy Store")

  if hm.node.wakuLegacyStore == nil:
    return p.notMounted()

  return p.ready()

proc getLegacyStoreClientHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Legacy Store Client")

  if hm.node.wakuLegacyStoreClient == nil:
    return p.notMounted()

  if hm.node.peerManager.selectPeer(WakuLegacyStoreCodec).isSome() or
      hm.node.wakuLegacyStore != nil:
    return p.ready()

  return p.notReady(
    "No Legacy Store service peers are available yet, neither Store service set up for the node"
  )

proc getPeerExchangeHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Peer Exchange")

  if hm.node.wakuPeerExchange == nil:
    return p.notMounted()

  return p.ready()

proc getRendezvousHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Rendezvous")

  if hm.node.wakuRendezvous == nil:
    return p.notMounted()

  if hm.node.peerManager.switch.peerStore.peers(RendezVousCodec).len() == 0:
    return p.notReady("No Rendezvous peers are available yet")

  return p.ready()

proc getMixHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Mix")

  if hm.node.wakuMix.isNil():
    return p.notMounted()

  return p.ready()

proc selectRandomPeersForKeepalive(
    node: WakuNode, outPeers: seq[PeerId], numRandomPeers: int
): Future[seq[PeerId]] {.async.} =
  ## Select peers for random keepalive, prioritizing mesh peers

  if node.wakuRelay.isNil():
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

proc getNodeHealthReport*(hm: NodeHealthMonitor): Future[HealthReport] {.async.} =
  var report: HealthReport
  report.nodeHealth = hm.nodeHealth

  let relayHealth = hm.getRelayHealth()
  report.protocolsHealth.add(relayHealth)
  report.protocolsHealth.add(await hm.getRlnRelayHealth())
  report.protocolsHealth.add(hm.getLightpushHealth(relayHealth.health))
  report.protocolsHealth.add(hm.getLegacyLightpushHealth(relayHealth.health))
  report.protocolsHealth.add(hm.getFilterHealth(relayHealth.health))
  report.protocolsHealth.add(hm.getStoreHealth())
  report.protocolsHealth.add(hm.getLegacyStoreHealth())
  report.protocolsHealth.add(hm.getPeerExchangeHealth())
  report.protocolsHealth.add(hm.getRendezvousHealth())
  report.protocolsHealth.add(hm.getMixHealth())

  report.protocolsHealth.add(hm.getLightpushClientHealth(relayHealth.health))
  report.protocolsHealth.add(hm.getLegacyLightpushClientHealth(relayHealth.health))
  report.protocolsHealth.add(hm.getStoreClientHealth())
  report.protocolsHealth.add(hm.getLegacyStoreClientHealth())
  report.protocolsHealth.add(hm.getFilterClientHealth(relayHealth.health))
  return report

proc setOverallHealth*(hm: NodeHealthMonitor, health: HealthStatus) =
  hm.nodeHealth = health

proc startHealthMonitor*(hm: NodeHealthMonitor): Result[void, string] =
  hm.onlineMonitor.startOnlineMonitor()
  hm.startKeepalive().isOkOr:
    return err("startHealthMonitor: failed starting keep alive: " & error)
  return ok()

proc stopHealthMonitor*(hm: NodeHealthMonitor) {.async.} =
  if not hm.onlineMonitor.isNil():
    await hm.onlineMonitor.stopOnlineMonitor()

  if not hm.keepAliveFut.isNil():
    await hm.keepAliveFut.cancelAndWait()

proc new*(
    T: type NodeHealthMonitor,
    node: WakuNode,
    dnsNameServers = @[parseIpAddress("1.1.1.1"), parseIpAddress("1.0.0.1")],
): T =
  let om = OnlineMonitor.init(dnsNameServers)
  om.setPeerStoreToOnlineMonitor(node.switch.peerStore)
  om.addOnlineStateObserver(node.peerManager.getOnlineStateObserver())
  T(
    nodeHealth: INITIALIZING,
    node: node,
    onlineMonitor: om,
  )

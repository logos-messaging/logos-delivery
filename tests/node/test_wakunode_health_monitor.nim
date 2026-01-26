{.used.}

import
  std/[json, options, sequtils, strutils, tables], testutils/unittests, chronos, results

import
  waku/[
    waku_core,
    common/waku_protocol,
    node/waku_node,
    node/peer_manager,
    node/health_monitor/health_status,
    node/health_monitor/connection_status,
    node/health_monitor/protocol_health,
    node/health_monitor/node_health_monitor,
    node/kernel_api/relay,
    node/kernel_api/store,
    node/kernel_api/lightpush,
    node/kernel_api/filter,
    waku_archive,
  ]

import ../testlib/[wakunode, wakucore], ../waku_archive/archive_utils

proc p(kind: WakuProtocol, health: HealthStatus): ProtocolHealth =
  var ph = ProtocolHealth.init(kind)
  if health == HealthStatus.READY:
    return ph.ready()
  else:
    return ph.notReady("mock")

suite "Health Monitor - health state calculation":
  test "Disconnected, zero peers":
    let protocols =
      @[
        p(RelayProtocol, HealthStatus.NOT_READY),
        p(StoreClientProtocol, HealthStatus.NOT_READY),
        p(FilterClientProtocol, HealthStatus.NOT_READY),
        p(LightpushClientProtocol, HealthStatus.NOT_READY),
      ]
    let strength = initTable[WakuProtocol, int]()
    let state =
      calculateConnectionState(protocols, strength, DefaultRelayFailoverThreshold)
    check state == ConnectionStatus.Disconnected

  test "PartiallyConnected, weak relay":
    let weakCount = DefaultRelayFailoverThreshold - 1
    let protocols =
      @[
        p(RelayProtocol, HealthStatus.READY), p(StoreClientProtocol, HealthStatus.READY)
      ]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = weakCount
    strength[StoreClientProtocol] = 1
    let state =
      calculateConnectionState(protocols, strength, DefaultRelayFailoverThreshold)
    check state == ConnectionStatus.PartiallyConnected

  test "Connected, robust relay":
    let protocols =
      @[
        p(RelayProtocol, HealthStatus.READY), p(StoreClientProtocol, HealthStatus.READY)
      ]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = DefaultRelayFailoverThreshold
    strength[StoreClientProtocol] = FailoverThreshold
    let state =
      calculateConnectionState(protocols, strength, DefaultRelayFailoverThreshold)
    check state == ConnectionStatus.Connected

  test "Connected, robust edge":
    let protocols =
      @[
        p(RelayProtocol, HealthStatus.NOT_MOUNTED),
        p(LightpushClientProtocol, HealthStatus.READY),
        p(FilterClientProtocol, HealthStatus.READY),
        p(StoreClientProtocol, HealthStatus.READY),
      ]
    var strength = initTable[WakuProtocol, int]()
    strength[LightpushClientProtocol] = FailoverThreshold
    strength[FilterClientProtocol] = FailoverThreshold
    strength[StoreClientProtocol] = FailoverThreshold
    let state =
      calculateConnectionState(protocols, strength, DefaultRelayFailoverThreshold)
    check state == ConnectionStatus.Connected

  test "Disconnected, edge missing store":
    let protocols =
      @[
        p(LightpushClientProtocol, HealthStatus.READY),
        p(FilterClientProtocol, HealthStatus.READY),
        p(StoreClientProtocol, HealthStatus.NOT_READY),
      ]
    var strength = initTable[WakuProtocol, int]()
    strength[LightpushClientProtocol] = FailoverThreshold
    strength[FilterClientProtocol] = FailoverThreshold
    strength[StoreClientProtocol] = 0
    let state =
      calculateConnectionState(protocols, strength, DefaultRelayFailoverThreshold)
    check state == ConnectionStatus.Disconnected

  test "PartiallyConnected, edge meets minimum failover requirement":
    let weakCount = max(1, FailoverThreshold - 1)
    let protocols =
      @[
        p(LightpushClientProtocol, HealthStatus.READY),
        p(FilterClientProtocol, HealthStatus.READY),
        p(StoreClientProtocol, HealthStatus.READY),
      ]
    var strength = initTable[WakuProtocol, int]()
    strength[LightpushClientProtocol] = weakCount
    strength[FilterClientProtocol] = weakCount
    strength[StoreClientProtocol] = weakCount
    let state =
      calculateConnectionState(protocols, strength, DefaultRelayFailoverThreshold)
    check state == ConnectionStatus.PartiallyConnected

  test "Connected, robust relay ignores store server":
    let protocols =
      @[p(RelayProtocol, HealthStatus.READY), p(StoreProtocol, HealthStatus.READY)]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = DefaultRelayFailoverThreshold
    strength[StoreProtocol] = 0
    let state =
      calculateConnectionState(protocols, strength, DefaultRelayFailoverThreshold)
    check state == ConnectionStatus.Connected

  test "Connected, robust relay ignores store client":
    let protocols =
      @[
        p(RelayProtocol, HealthStatus.READY),
        p(StoreProtocol, HealthStatus.READY),
        p(StoreClientProtocol, HealthStatus.NOT_READY),
      ]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = DefaultRelayFailoverThreshold
    strength[StoreProtocol] = 0
    strength[StoreClientProtocol] = 0
    let state =
      calculateConnectionState(protocols, strength, DefaultRelayFailoverThreshold)
    check state == ConnectionStatus.Connected

suite "Health Monitor - events":
  asyncTest "Core (relay) health update":
    let
      nodeAKey = generateSecp256k1Key()
      nodeA = newTestWakuNode(nodeAKey, parseIpAddress("127.0.0.1"), Port(0))

    (await nodeA.mountRelay()).expect("Node A failed to mount Relay")

    nodeA.mountStoreClient()

    await nodeA.start()

    let monitorA = NodeHealthMonitor.new()
    monitorA.setNodeToHealthMonitor(nodeA)

    var
      lastStatus = ConnectionStatus.Disconnected
      callbackCount = 0
      healthChangeSignal = newFuture[void]()

    monitorA.onConnectionStatusChange = proc(status: ConnectionStatus) {.async.} =
      lastStatus = status
      callbackCount.inc()
      if not healthChangeSignal.finished:
        healthChangeSignal.complete()

    monitorA.startHealthMonitor().expect("Health monitor failed to start")

    let
      nodeBKey = generateSecp256k1Key()
      nodeB = newTestWakuNode(nodeBKey, parseIpAddress("127.0.0.1"), Port(0))

    let driver = newSqliteArchiveDriver()
    nodeB.mountArchive(driver).expect("Node B failed to mount archive")

    (await nodeB.mountRelay()).expect("Node B failed to mount relay")
    await nodeB.mountStore()

    await nodeB.start()

    await nodeA.connectToNodes(@[nodeB.switch.peerInfo.toRemotePeerInfo()])

    proc dummyHandler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async.} =
      discard

    nodeA.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), dummyHandler).expect(
      "Node A failed to subscribe"
    )
    nodeB.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), dummyHandler).expect(
      "Node B failed to subscribe"
    )

    let connectTimeLimit = Moment.now() + 10.seconds
    var gotConnected = false

    while Moment.now() < connectTimeLimit:
      if lastStatus != ConnectionStatus.Disconnected:
        gotConnected = true
        break

      if healthChangeSignal.finished:
        healthChangeSignal = newFuture[void]()

      discard await healthChangeSignal.withTimeout(connectTimeLimit - Moment.now())

    check:
      gotConnected == true
      callbackCount >= 1

    if healthChangeSignal.finished:
      healthChangeSignal = newFuture[void]()

    await nodeB.stop()
    await nodeA.disconnectNode(nodeB.switch.peerInfo.toRemotePeerInfo())

    let disconnectTimeLimit = Moment.now() + 10.seconds
    var gotDisconnected = false

    while Moment.now() < disconnectTimeLimit:
      if lastStatus == ConnectionStatus.Disconnected:
        gotDisconnected = true
        break

      if healthChangeSignal.finished:
        healthChangeSignal = newFuture[void]()

      discard await healthChangeSignal.withTimeout(disconnectTimeLimit - Moment.now())

    check:
      gotDisconnected == true

    await monitorA.stopHealthMonitor()
    await nodeA.stop()

  asyncTest "Edge (light client) health update":
    let
      nodeAKey = generateSecp256k1Key()
      nodeA = newTestWakuNode(nodeAKey, parseIpAddress("127.0.0.1"), Port(0))

    nodeA.mountLightpushClient()
    await nodeA.mountFilterClient()
    nodeA.mountStoreClient()

    await nodeA.start()

    let monitorA = NodeHealthMonitor.new()
    monitorA.setNodeToHealthMonitor(nodeA)

    var
      lastStatus = ConnectionStatus.Disconnected
      callbackCount = 0
      healthChangeSignal = newFuture[void]()

    monitorA.onConnectionStatusChange = proc(status: ConnectionStatus) {.async.} =
      lastStatus = status
      callbackCount.inc()
      if not healthChangeSignal.finished:
        healthChangeSignal.complete()

    monitorA.startHealthMonitor().expect("Health monitor failed to start")

    let
      nodeBKey = generateSecp256k1Key()
      nodeB = newTestWakuNode(nodeBKey, parseIpAddress("127.0.0.1"), Port(0))

    let driver = newSqliteArchiveDriver()
    nodeB.mountArchive(driver).expect("Node B failed to mount archive")

    (await nodeB.mountRelay()).expect("Node B failed to mount relay")

    (await nodeB.mountLightpush()).expect("Node B failed to mount lightpush")
    await nodeB.mountFilter()
    await nodeB.mountStore()

    await nodeB.start()

    await nodeA.connectToNodes(@[nodeB.switch.peerInfo.toRemotePeerInfo()])

    let connectTimeLimit = Moment.now() + 10.seconds
    var gotConnected = false

    while Moment.now() < connectTimeLimit:
      if lastStatus == ConnectionStatus.PartiallyConnected:
        gotConnected = true
        break

      if healthChangeSignal.finished:
        healthChangeSignal = newFuture[void]()

      discard await healthChangeSignal.withTimeout(connectTimeLimit - Moment.now())

    check:
      gotConnected == true
      callbackCount >= 1
      lastStatus == ConnectionStatus.PartiallyConnected

    if healthChangeSignal.finished:
      healthChangeSignal = newFuture[void]()

    await nodeB.stop()
    await nodeA.disconnectNode(nodeB.switch.peerInfo.toRemotePeerInfo())

    let disconnectTimeLimit = Moment.now() + 10.seconds
    var gotDisconnected = false

    while Moment.now() < disconnectTimeLimit:
      if lastStatus == ConnectionStatus.Disconnected:
        gotDisconnected = true
        break

      if healthChangeSignal.finished:
        healthChangeSignal = newFuture[void]()

      discard await healthChangeSignal.withTimeout(disconnectTimeLimit - Moment.now())

    check:
      gotDisconnected == true
      lastStatus == ConnectionStatus.Disconnected

    await monitorA.stopHealthMonitor()
    await nodeA.stop()


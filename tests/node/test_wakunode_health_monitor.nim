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

const MockDLow = 4 # Mocked GossipSub DLow value

const TestConnectivityTimeLimit = 3.seconds

proc protoHealthMock(kind: WakuProtocol, health: HealthStatus): ProtocolHealth =
  var ph = ProtocolHealth.init(kind)
  if health == HealthStatus.READY:
    return ph.ready()
  else:
    return ph.notReady("mock")

suite "Health Monitor - health state calculation":
  test "Disconnected, zero peers":
    let protocols =
      @[
        protoHealthMock(RelayProtocol, HealthStatus.NOT_READY),
        protoHealthMock(StoreClientProtocol, HealthStatus.NOT_READY),
        protoHealthMock(FilterClientProtocol, HealthStatus.NOT_READY),
        protoHealthMock(LightpushClientProtocol, HealthStatus.NOT_READY),
      ]
    let strength = initTable[WakuProtocol, int]()
    let state =
      calculateConnectionState(protocols, strength, some(MockDLow))
    check state == ConnectionStatus.Disconnected

  test "PartiallyConnected, weak relay":
    let weakCount = MockDLow - 1
    let protocols =
      @[
        protoHealthMock(RelayProtocol, HealthStatus.READY),
      ]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = weakCount
    let state =
      calculateConnectionState(protocols, strength, some(MockDLow))
    # Partially connected since relay connectivity is weak (> 0, but < dLow)
    check state == ConnectionStatus.PartiallyConnected

  test "Connected, robust relay":
    let protocols =
      @[
        protoHealthMock(RelayProtocol, HealthStatus.READY),
      ]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = MockDLow
    let state =
      calculateConnectionState(protocols, strength, some(MockDLow))
    # Fully connected since relay connectivity is ideal (>= dLow)
    check state == ConnectionStatus.Connected

  test "Connected, robust edge":
    let protocols =
      @[
        protoHealthMock(RelayProtocol, HealthStatus.NOT_MOUNTED),
        protoHealthMock(LightpushClientProtocol, HealthStatus.READY),
        protoHealthMock(FilterClientProtocol, HealthStatus.READY),
        protoHealthMock(StoreClientProtocol, HealthStatus.READY),
      ]
    var strength = initTable[WakuProtocol, int]()
    strength[LightpushClientProtocol] = HealthyThreshold
    strength[FilterClientProtocol] = HealthyThreshold
    strength[StoreClientProtocol] = HealthyThreshold
    let state =
      calculateConnectionState(protocols, strength, some(MockDLow))
    check state == ConnectionStatus.Connected

  test "Disconnected, edge missing store":
    let protocols =
      @[
        protoHealthMock(LightpushClientProtocol, HealthStatus.READY),
        protoHealthMock(FilterClientProtocol, HealthStatus.READY),
        protoHealthMock(StoreClientProtocol, HealthStatus.NOT_READY),
      ]
    var strength = initTable[WakuProtocol, int]()
    strength[LightpushClientProtocol] = HealthyThreshold
    strength[FilterClientProtocol] = HealthyThreshold
    strength[StoreClientProtocol] = 0
    let state =
      calculateConnectionState(protocols, strength, some(MockDLow))
    check state == ConnectionStatus.Disconnected

  test "PartiallyConnected, edge meets minimum failover requirement":
    let weakCount = max(1, HealthyThreshold - 1)
    let protocols =
      @[
        protoHealthMock(LightpushClientProtocol, HealthStatus.READY),
        protoHealthMock(FilterClientProtocol, HealthStatus.READY),
        protoHealthMock(StoreClientProtocol, HealthStatus.READY),
      ]
    var strength = initTable[WakuProtocol, int]()
    strength[LightpushClientProtocol] = weakCount
    strength[FilterClientProtocol] = weakCount
    strength[StoreClientProtocol] = weakCount
    let state =
      calculateConnectionState(protocols, strength, some(MockDLow))
    check state == ConnectionStatus.PartiallyConnected

  test "Connected, robust relay ignores store server":
    let protocols =
      @[
        protoHealthMock(RelayProtocol, HealthStatus.READY),
        protoHealthMock(StoreProtocol, HealthStatus.READY),
      ]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = MockDLow
    strength[StoreProtocol] = 0
    let state =
      calculateConnectionState(protocols, strength, some(MockDLow))
    check state == ConnectionStatus.Connected

  test "Connected, robust relay ignores store client":
    let protocols =
      @[
        protoHealthMock(RelayProtocol, HealthStatus.READY),
        protoHealthMock(StoreProtocol, HealthStatus.READY),
        protoHealthMock(StoreClientProtocol, HealthStatus.NOT_READY),
      ]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = MockDLow
    strength[StoreProtocol] = 0
    strength[StoreClientProtocol] = 0
    let state =
      calculateConnectionState(protocols, strength, some(MockDLow))
    check state == ConnectionStatus.Connected

suite "Health Monitor - events":
  asyncTest "Core (relay) health update":
    let
      nodeAKey = generateSecp256k1Key()
      nodeA = newTestWakuNode(nodeAKey, parseIpAddress("127.0.0.1"), Port(0))

    (await nodeA.mountRelay()).expect("Node A failed to mount Relay")

    await nodeA.start()

    let monitorA = NodeHealthMonitor.new(nodeA)

    var
      lastStatus = ConnectionStatus.Disconnected
      callbackCount = 0
      healthChangeSignal = newAsyncEvent()

    monitorA.onConnectionStatusChange = proc(status: ConnectionStatus) {.async.} =
      lastStatus = status
      callbackCount.inc()
      healthChangeSignal.fire()

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

    let connectTimeLimit = Moment.now() + TestConnectivityTimeLimit
    var gotConnected = false

    while Moment.now() < connectTimeLimit:
      if lastStatus == ConnectionStatus.PartiallyConnected:
        gotConnected = true
        break

      if await healthChangeSignal.wait().withTimeout(connectTimeLimit - Moment.now()):
        healthChangeSignal.clear()

    check:
      gotConnected == true
      callbackCount >= 1
      lastStatus == ConnectionStatus.PartiallyConnected

    healthChangeSignal.clear()

    await nodeB.stop()
    await nodeA.disconnectNode(nodeB.switch.peerInfo.toRemotePeerInfo())

    let disconnectTimeLimit = Moment.now() + TestConnectivityTimeLimit
    var gotDisconnected = false

    while Moment.now() < disconnectTimeLimit:
      if lastStatus == ConnectionStatus.Disconnected:
        gotDisconnected = true
        break

      if await healthChangeSignal.wait().withTimeout(disconnectTimeLimit - Moment.now()):
        healthChangeSignal.clear()

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

    let monitorA = NodeHealthMonitor.new(nodeA)

    var
      lastStatus = ConnectionStatus.Disconnected
      callbackCount = 0
      healthChangeSignal = newAsyncEvent()

    monitorA.onConnectionStatusChange = proc(status: ConnectionStatus) {.async.} =
      lastStatus = status
      callbackCount.inc()
      healthChangeSignal.fire()

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

    let connectTimeLimit = Moment.now() + TestConnectivityTimeLimit
    var gotConnected = false

    while Moment.now() < connectTimeLimit:
      if lastStatus == ConnectionStatus.PartiallyConnected:
        gotConnected = true
        break

      if await healthChangeSignal.wait().withTimeout(connectTimeLimit - Moment.now()):
        healthChangeSignal.clear()

    check:
      gotConnected == true
      callbackCount >= 1
      lastStatus == ConnectionStatus.PartiallyConnected

    healthChangeSignal.clear()

    await nodeB.stop()
    await nodeA.disconnectNode(nodeB.switch.peerInfo.toRemotePeerInfo())

    let disconnectTimeLimit = Moment.now() + TestConnectivityTimeLimit
    var gotDisconnected = false

    while Moment.now() < disconnectTimeLimit:
      if lastStatus == ConnectionStatus.Disconnected:
        gotDisconnected = true
        break

      if await healthChangeSignal.wait().withTimeout(disconnectTimeLimit - Moment.now()):
        healthChangeSignal.clear()

    check:
      gotDisconnected == true
      lastStatus == ConnectionStatus.Disconnected

    await monitorA.stopHealthMonitor()
    await nodeA.stop()

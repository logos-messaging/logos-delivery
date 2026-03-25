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
    node/health_monitor/topic_health,
    node/health_monitor/node_health_monitor,
    node/delivery_service/delivery_service,
    node/delivery_service/subscription_manager,
    node/kernel_api/relay,
    node/kernel_api/store,
    node/kernel_api/lightpush,
    node/kernel_api/filter,
    events/health_events,
    events/peer_events,
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
    let protocols = @[
      protoHealthMock(RelayProtocol, HealthStatus.NOT_READY),
      protoHealthMock(StoreClientProtocol, HealthStatus.NOT_READY),
      protoHealthMock(FilterClientProtocol, HealthStatus.NOT_READY),
      protoHealthMock(LightpushClientProtocol, HealthStatus.NOT_READY),
    ]
    let strength = initTable[WakuProtocol, int]()
    let state = calculateConnectionState(protocols, strength, some(MockDLow))
    check state == ConnectionStatus.Disconnected

  test "PartiallyConnected, weak relay":
    let weakCount = MockDLow - 1
    let protocols = @[protoHealthMock(RelayProtocol, HealthStatus.READY)]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = weakCount
    let state = calculateConnectionState(protocols, strength, some(MockDLow))
    # Partially connected since relay connectivity is weak (> 0, but < dLow)
    check state == ConnectionStatus.PartiallyConnected

  test "Connected, robust relay":
    let protocols = @[protoHealthMock(RelayProtocol, HealthStatus.READY)]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = MockDLow
    let state = calculateConnectionState(protocols, strength, some(MockDLow))
    # Fully connected since relay connectivity is ideal (>= dLow)
    check state == ConnectionStatus.Connected

  test "Connected, robust edge":
    let protocols = @[
      protoHealthMock(RelayProtocol, HealthStatus.NOT_MOUNTED),
      protoHealthMock(LightpushClientProtocol, HealthStatus.READY),
      protoHealthMock(FilterClientProtocol, HealthStatus.READY),
      protoHealthMock(StoreClientProtocol, HealthStatus.READY),
    ]
    var strength = initTable[WakuProtocol, int]()
    strength[LightpushClientProtocol] = HealthyThreshold
    strength[FilterClientProtocol] = HealthyThreshold
    strength[StoreClientProtocol] = HealthyThreshold
    let state = calculateConnectionState(protocols, strength, some(MockDLow))
    check state == ConnectionStatus.Connected

  test "Disconnected, edge missing store":
    let protocols = @[
      protoHealthMock(LightpushClientProtocol, HealthStatus.READY),
      protoHealthMock(FilterClientProtocol, HealthStatus.READY),
      protoHealthMock(StoreClientProtocol, HealthStatus.NOT_READY),
    ]
    var strength = initTable[WakuProtocol, int]()
    strength[LightpushClientProtocol] = HealthyThreshold
    strength[FilterClientProtocol] = HealthyThreshold
    strength[StoreClientProtocol] = 0
    let state = calculateConnectionState(protocols, strength, some(MockDLow))
    check state == ConnectionStatus.Disconnected

  test "PartiallyConnected, edge meets minimum failover requirement":
    let weakCount = max(1, HealthyThreshold - 1)
    let protocols = @[
      protoHealthMock(LightpushClientProtocol, HealthStatus.READY),
      protoHealthMock(FilterClientProtocol, HealthStatus.READY),
      protoHealthMock(StoreClientProtocol, HealthStatus.READY),
    ]
    var strength = initTable[WakuProtocol, int]()
    strength[LightpushClientProtocol] = weakCount
    strength[FilterClientProtocol] = weakCount
    strength[StoreClientProtocol] = weakCount
    let state = calculateConnectionState(protocols, strength, some(MockDLow))
    check state == ConnectionStatus.PartiallyConnected

  test "Connected, robust relay ignores store server":
    let protocols = @[
      protoHealthMock(RelayProtocol, HealthStatus.READY),
      protoHealthMock(StoreProtocol, HealthStatus.READY),
    ]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = MockDLow
    strength[StoreProtocol] = 0
    let state = calculateConnectionState(protocols, strength, some(MockDLow))
    check state == ConnectionStatus.Connected

  test "Connected, robust relay ignores store client":
    let protocols = @[
      protoHealthMock(RelayProtocol, HealthStatus.READY),
      protoHealthMock(StoreProtocol, HealthStatus.READY),
      protoHealthMock(StoreClientProtocol, HealthStatus.NOT_READY),
    ]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = MockDLow
    strength[StoreProtocol] = 0
    strength[StoreClientProtocol] = 0
    let state = calculateConnectionState(protocols, strength, some(MockDLow))
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

  asyncTest "Edge health driven by confirmed filter subscriptions":
    let
      nodeAKey = generateSecp256k1Key()
      nodeA = newTestWakuNode(nodeAKey, parseIpAddress("127.0.0.1"), Port(0))

    await nodeA.mountFilterClient()
    nodeA.mountLightpushClient()
    nodeA.mountStoreClient()
    require nodeA.mountAutoSharding(1, 8).isOk
    nodeA.mountMetadata(1, @[0'u16]).expect("Node A failed to mount metadata")

    await nodeA.start()

    let ds =
      DeliveryService.new(false, nodeA).expect("Failed to create DeliveryService")
    ds.startDeliveryService()
    let subMgr = ds.subscriptionManager

    let
      nodeBKey = generateSecp256k1Key()
      nodeB = newTestWakuNode(nodeBKey, parseIpAddress("127.0.0.1"), Port(0))

    let driver = newSqliteArchiveDriver()
    nodeB.mountArchive(driver).expect("Node B failed to mount archive")

    (await nodeB.mountRelay()).expect("Node B failed to mount relay")
    (await nodeB.mountLightpush()).expect("Node B failed to mount lightpush")
    await nodeB.mountFilter()
    await nodeB.mountStore()
    require nodeB.mountAutoSharding(1, 8).isOk
    nodeB.mountMetadata(1, toSeq(0'u16 ..< 8'u16)).expect(
      "Node B failed to mount metadata"
    )

    await nodeB.start()

    let monitorA = NodeHealthMonitor.new(nodeA)

    var
      lastStatus = ConnectionStatus.Disconnected
      healthSignal = newAsyncEvent()

    monitorA.onConnectionStatusChange = proc(status: ConnectionStatus) {.async.} =
      lastStatus = status
      healthSignal.fire()

    monitorA.startHealthMonitor().expect("Health monitor failed to start")

    var metadataFut = newFuture[void]("waitForMetadata")
    let metadataLis = WakuPeerEvent
      .listen(
        nodeA.brokerCtx,
        proc(evt: WakuPeerEvent): Future[void] {.async: (raises: []), gcsafe.} =
          if not metadataFut.finished and
              evt.kind == WakuPeerEventKind.EventMetadataUpdated:
            metadataFut.complete()
        ,
      )
      .expect("Failed to listen for metadata")

    await nodeA.connectToNodes(@[nodeB.switch.peerInfo.toRemotePeerInfo()])

    let metadataOk = await metadataFut.withTimeout(TestConnectivityTimeLimit)
    WakuPeerEvent.dropListener(nodeA.brokerCtx, metadataLis)
    require metadataOk

    var deadline = Moment.now() + TestConnectivityTimeLimit
    while Moment.now() < deadline:
      if lastStatus == ConnectionStatus.PartiallyConnected:
        break
      if await healthSignal.wait().withTimeout(deadline - Moment.now()):
        healthSignal.clear()

    check lastStatus == ConnectionStatus.PartiallyConnected

    var shardHealthFut = newFuture[EventShardTopicHealthChange]("waitForShardHealth")

    let shardHealthLis = EventShardTopicHealthChange
      .listen(
        nodeA.brokerCtx,
        proc(
            evt: EventShardTopicHealthChange
        ): Future[void] {.async: (raises: []), gcsafe.} =
          if not shardHealthFut.finished and (
            evt.health == TopicHealth.MINIMALLY_HEALTHY or
            evt.health == TopicHealth.SUFFICIENTLY_HEALTHY
          ):
            shardHealthFut.complete(evt)
        ,
      )
      .expect("Failed to listen for shard health")

    let contentTopic = ContentTopic("/waku/2/default-content/proto")
    subMgr.subscribe(contentTopic).expect("Failed to subscribe")

    let shardHealthOk = await shardHealthFut.withTimeout(TestConnectivityTimeLimit)
    EventShardTopicHealthChange.dropListener(nodeA.brokerCtx, shardHealthLis)

    check shardHealthOk == true
    check subMgr.edgeFilterSubStates.len > 0

    healthSignal.clear()
    deadline = Moment.now() + TestConnectivityTimeLimit
    while Moment.now() < deadline:
      if lastStatus == ConnectionStatus.PartiallyConnected:
        break
      if await healthSignal.wait().withTimeout(deadline - Moment.now()):
        healthSignal.clear()

    check lastStatus == ConnectionStatus.PartiallyConnected

    await ds.stopDeliveryService()
    await monitorA.stopHealthMonitor()
    await nodeB.stop()
    await nodeA.stop()

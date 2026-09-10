{.used.}

import std/[json, sequtils, strutils, tables], testutils/unittests, chronos, results
import brokers/broker_context
import libp2p_mix/[curve25519, pool], libp2p/[peerid, multiaddress]

import
  logos_delivery/waku/[
    waku_core,
    common/waku_protocol,
    node/waku_node,
    node/peer_manager,
    node/health_monitor/health_status,
    node/health_monitor/connection_status,
    node/health_monitor/protocol_health,
    node/health_monitor/topic_health,
    node/health_monitor/node_health_monitor,
    node/waku_node/relay,
    node/waku_node/store,
    node/waku_node/lightpush,
    node/waku_node/filter,
    api/events/health_events,
    api/events/peer_events,
    waku_archive,
    waku_mix,
  ]

import ../testlib/[wakunode, wakucore], ../waku_archive/archive_utils
import logos_delivery/waku/node/subscription_manager
import logos_delivery/waku/waku
import logos_delivery/waku/factory/waku_state_info
import logos_delivery/messaging/messaging_client
import logos_delivery/messaging/messaging_client_lifecycle

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
    let state = calculateConnectionState(protocols, strength, Opt.some(MockDLow))
    check state == ConnectionStatus.Disconnected

  test "PartiallyConnected, weak relay":
    let weakCount = MockDLow - 1
    let protocols = @[protoHealthMock(RelayProtocol, HealthStatus.READY)]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = weakCount
    let state = calculateConnectionState(protocols, strength, Opt.some(MockDLow))
    # Partially connected since relay connectivity is weak (> 0, but < dLow)
    check state == ConnectionStatus.PartiallyConnected

  test "Connected, robust relay":
    let protocols = @[protoHealthMock(RelayProtocol, HealthStatus.READY)]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = MockDLow
    let state = calculateConnectionState(protocols, strength, Opt.some(MockDLow))
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
    let state = calculateConnectionState(protocols, strength, Opt.some(MockDLow))
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
    let state = calculateConnectionState(protocols, strength, Opt.some(MockDLow))
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
    let state = calculateConnectionState(protocols, strength, Opt.some(MockDLow))
    check state == ConnectionStatus.PartiallyConnected

  test "Connected, robust relay ignores store server":
    let protocols = @[
      protoHealthMock(RelayProtocol, HealthStatus.READY),
      protoHealthMock(StoreProtocol, HealthStatus.READY),
    ]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = MockDLow
    strength[StoreProtocol] = 0
    let state = calculateConnectionState(protocols, strength, Opt.some(MockDLow))
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
    let state = calculateConnectionState(protocols, strength, Opt.some(MockDLow))
    check state == ConnectionStatus.Connected

  test "Disconnected, mix required but pool too small":
    let protocols = @[
      protoHealthMock(RelayProtocol, HealthStatus.READY),
      protoHealthMock(MixProtocol, HealthStatus.NOT_READY),
    ]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = MockDLow
    let state = requireMixReady(
      calculateConnectionState(protocols, strength, Opt.some(MockDLow)), protocols
    )
    check state == ConnectionStatus.Disconnected

  test "Disconnected, mix required but not mounted":
    let protocols = @[
      protoHealthMock(RelayProtocol, HealthStatus.READY),
      ProtocolHealth.init(MixProtocol), # not mounted
    ]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = MockDLow
    let state = requireMixReady(
      calculateConnectionState(protocols, strength, Opt.some(MockDLow)), protocols
    )
    check state == ConnectionStatus.Disconnected

  test "Connected, mix required and ready":
    let protocols = @[
      protoHealthMock(RelayProtocol, HealthStatus.READY),
      protoHealthMock(MixProtocol, HealthStatus.READY),
    ]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = MockDLow
    let state = requireMixReady(
      calculateConnectionState(protocols, strength, Opt.some(MockDLow)), protocols
    )
    check state == ConnectionStatus.Connected

  test "Connected, mix not ready but not required":
    # anonymityLevel None/Preferred: the plain send path still works
    let protocols = @[
      protoHealthMock(RelayProtocol, HealthStatus.READY),
      protoHealthMock(MixProtocol, HealthStatus.NOT_READY),
    ]
    var strength = initTable[WakuProtocol, int]()
    strength[RelayProtocol] = MockDLow
    let state = calculateConnectionState(protocols, strength, Opt.some(MockDLow))
    check state == ConnectionStatus.Connected

  test "Disconnected, mix required on an edge node":
    let protocols = @[
      protoHealthMock(RelayProtocol, HealthStatus.NOT_MOUNTED),
      protoHealthMock(LightpushClientProtocol, HealthStatus.READY),
      protoHealthMock(FilterClientProtocol, HealthStatus.READY),
      protoHealthMock(StoreClientProtocol, HealthStatus.READY),
      protoHealthMock(MixProtocol, HealthStatus.NOT_READY),
    ]
    var strength = initTable[WakuProtocol, int]()
    strength[LightpushClientProtocol] = HealthyThreshold
    strength[FilterClientProtocol] = HealthyThreshold
    strength[StoreClientProtocol] = HealthyThreshold
    let state = requireMixReady(
      calculateConnectionState(protocols, strength, Opt.none(int)), protocols
    )
    check state == ConnectionStatus.Disconnected

suite "Health Monitor - events":
  asyncTest "Core (relay) health update":
    var nodeA: WakuNode
    lockNewGlobalBrokerContext:
      let nodeAKey = generateSecp256k1Key()
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

    var nodeB: WakuNode
    lockNewGlobalBrokerContext:
      let nodeBKey = generateSecp256k1Key()
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
    var nodeA: WakuNode
    lockNewGlobalBrokerContext:
      let nodeAKey = generateSecp256k1Key()
      nodeA = newTestWakuNode(nodeAKey, parseIpAddress("127.0.0.1"), Port(0))
      nodeA.mountLightpushClient()
      await nodeA.mountFilterClient()
      nodeA.mountStoreClient()
      require nodeA.mountAutoSharding(1, 8).isOk
      nodeA.mountMetadata(1, @[0'u16]).expect("Node A failed to mount metadata")
      await nodeA.start()

    # MessagingClient now depends on the Waku kernel, not the raw node. Only
    # `waku.node` is read on the messaging path; `conf`/`stateInfo` are supplied
    # solely to satisfy Waku's {.requiresInit.} fields.
    let waku = Waku(
      node: nodeA,
      conf: defaultTestWakuConf(),
      stateInfo: WakuStateInfo.init(nodeA, defaultTestWakuConf()),
    )
    let ds = MessagingClient
      .new(MessagingClientConf(reliabilityEnabled: Opt.some(false)), waku)
      .expect("Failed to create MessagingClient")
    ds.start().expect("Failed to start MessagingClient")

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

    var nodeB: WakuNode
    lockNewGlobalBrokerContext:
      let nodeBKey = generateSecp256k1Key()
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
    await WakuPeerEvent.dropListener(nodeA.brokerCtx, metadataLis)
    require metadataOk

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
    await ds.stop()
    await nodeA.stop()

  asyncTest "Edge health driven by confirmed filter subscriptions":
    var nodeA: WakuNode
    lockNewGlobalBrokerContext:
      let nodeAKey = generateSecp256k1Key()
      nodeA = newTestWakuNode(nodeAKey, parseIpAddress("127.0.0.1"), Port(0))
      await nodeA.mountFilterClient()
      nodeA.mountLightpushClient()
      nodeA.mountStoreClient()
      require nodeA.mountAutoSharding(1, 8).isOk
      nodeA.mountMetadata(1, @[0'u16]).expect("Node A failed to mount metadata")
      await nodeA.start()

    # MessagingClient now depends on the Waku kernel, not the raw node. Only
    # `waku.node` is read on the messaging path; `conf`/`stateInfo` are supplied
    # solely to satisfy Waku's {.requiresInit.} fields.
    let waku = Waku(
      node: nodeA,
      conf: defaultTestWakuConf(),
      stateInfo: WakuStateInfo.init(nodeA, defaultTestWakuConf()),
    )
    let ds = MessagingClient
      .new(MessagingClientConf(reliabilityEnabled: Opt.some(false)), waku)
      .expect("Failed to create MessagingClient")
    ds.start().expect("Failed to start MessagingClient")
    let subMgr = nodeA.subscriptionManager

    var nodeB: WakuNode
    lockNewGlobalBrokerContext:
      let nodeBKey = generateSecp256k1Key()
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
    await WakuPeerEvent.dropListener(nodeA.brokerCtx, metadataLis)
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
    await EventShardTopicHealthChange.dropListener(nodeA.brokerCtx, shardHealthLis)

    check shardHealthOk == true
    check nodeA.subscriptionManager.edgeFilterSubStates.len > 0

    healthSignal.clear()
    deadline = Moment.now() + TestConnectivityTimeLimit
    while Moment.now() < deadline:
      if lastStatus == ConnectionStatus.PartiallyConnected:
        break
      if await healthSignal.wait().withTimeout(deadline - Moment.now()):
        healthSignal.clear()

    check lastStatus == ConnectionStatus.PartiallyConnected

    await ds.stop()
    await monitorA.stopHealthMonitor()
    await nodeB.stop()
    await nodeA.stop()

proc mixPeerInfo(port: int, lightpush = false): RemotePeerInfo =
  let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
  let keyPair = generateKeyPair().expect("mix key pair")
  return RemotePeerInfo.init(
    peerId,
    @[MultiAddress.init("/ip4/127.0.0.1/tcp/" & $port).tryGet()],
    protocols = (if lightpush: @[WakuLightPushCodec] else: @[]),
    mixPubKey = Opt.some(keyPair.publicKey),
  )

proc addMixPeer(node: WakuNode, port: int, lightpush = false) =
  ## Mix pool size is the count of peer-store entries carrying a mix key.
  node.peerManager.addPeer(mixPeerInfo(port, lightpush))

proc mountTestMix(node: WakuNode) {.async.} =
  let (mixPrivKey, _) = generateKeyPair().expect("mix key pair")
  (await node.mountMix(DefaultClusterId, mixPrivKey, @[])).expect("failed to mount mix")

suite "Health Monitor - mix readiness":
  asyncTest "Mix health follows the pool size":
    var node: WakuNode
    lockNewGlobalBrokerContext:
      node =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))

    let monitor = NodeHealthMonitor.new(node)
    check monitor.getSyncProtocolHealthInfo(MixProtocol).health ==
      HealthStatus.NOT_MOUNTED

    await node.mountTestMix()

    let shortPool = monitor.getSyncProtocolHealthInfo(MixProtocol)
    check:
      shortPool.health == HealthStatus.NOT_READY
      shortPool.desc.isSome()

    for i in 0 ..< MinMixPoolSize:
      node.addMixPeer(61000 + i)

    # Large enough, but no member can be the lightpush exit.
    check monitor.getSyncProtocolHealthInfo(MixProtocol).health == HealthStatus.NOT_READY

    node.addMixPeer(61100, lightpush = true)
    check monitor.getSyncProtocolHealthInfo(MixProtocol).health == HealthStatus.READY

  asyncTest "Mix health accepts the slotted lightpush peer as exit":
    var node: WakuNode
    lockNewGlobalBrokerContext:
      node =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    await node.mountTestMix()
    let monitor = NodeHealthMonitor.new(node)

    for i in 0 ..< MinMixPoolSize - 1:
      node.addMixPeer(63000 + i)
    # Not identified yet, so the codec is not in its ProtoBook.
    node.peerManager.addServicePeer(mixPeerInfo(63100), WakuLightPushCodec)

    check monitor.getSyncProtocolHealthInfo(MixProtocol).health == HealthStatus.READY

  asyncTest "Required mix keeps the status Disconnected while the pool is short":
    var nodeA: WakuNode
    lockNewGlobalBrokerContext:
      nodeA =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
      (await nodeA.mountRelay()).expect("Node A failed to mount Relay")
      await nodeA.mountTestMix()
      await nodeA.start()

    let monitorA = NodeHealthMonitor.new(nodeA)
    monitorA.adjustConnectionStatus = requireMixReady

    var
      lastStatus = ConnectionStatus.Disconnected
      healthChangeSignal = newAsyncEvent()

    monitorA.onConnectionStatusChange = proc(status: ConnectionStatus) {.async.} =
      lastStatus = status
      healthChangeSignal.fire()

    monitorA.startHealthMonitor().expect("Health monitor failed to start")

    var nodeB: WakuNode
    lockNewGlobalBrokerContext:
      nodeB =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
      (await nodeB.mountRelay()).expect("Node B failed to mount relay")
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

    let deadline = Moment.now() + TestConnectivityTimeLimit
    while Moment.now() < deadline:
      if await healthChangeSignal.wait().withTimeout(deadline - Moment.now()):
        healthChangeSignal.clear()

    check:
      # relay is up, so only the mix gate can be holding the status down
      monitorA.getSyncProtocolHealthInfo(RelayProtocol).health == HealthStatus.READY
      lastStatus == ConnectionStatus.Disconnected

    await monitorA.stopHealthMonitor()
    await nodeB.stop()
    await nodeA.stop()

  asyncTest "Required mix status follows the pool as it fills and drains":
    var nodeA: WakuNode
    lockNewGlobalBrokerContext:
      nodeA =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
      (await nodeA.mountRelay()).expect("Node A failed to mount Relay")
      await nodeA.mountTestMix()
      await nodeA.start()

    let monitorA = NodeHealthMonitor.new(nodeA)
    monitorA.adjustConnectionStatus = requireMixReady

    var
      lastStatus = ConnectionStatus.Disconnected
      healthChangeSignal = newAsyncEvent()

    monitorA.onConnectionStatusChange = proc(status: ConnectionStatus) {.async.} =
      lastStatus = status
      healthChangeSignal.fire()

    monitorA.startHealthMonitor().expect("Health monitor failed to start")

    var nodeB: WakuNode
    lockNewGlobalBrokerContext:
      nodeB =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
      (await nodeB.mountRelay()).expect("Node B failed to mount relay")
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

    proc waitForStatus(expected: ConnectionStatus): Future[bool] {.async.} =
      let deadline = Moment.now() + TestConnectivityTimeLimit
      while lastStatus != expected and Moment.now() < deadline:
        if await healthChangeSignal.wait().withTimeout(deadline - Moment.now()):
          healthChangeSignal.clear()
      return lastStatus == expected

    let relayDeadline = Moment.now() + TestConnectivityTimeLimit
    while monitorA.getSyncProtocolHealthInfo(RelayProtocol).health != HealthStatus.READY and
        Moment.now() < relayDeadline:
      await sleepAsync(100.milliseconds)

    # Let the relay mesh go quiet, so that only a pool change can trigger the
    # next health recomputation.
    await sleepAsync(1.seconds)
    check:
      monitorA.getSyncProtocolHealthInfo(RelayProtocol).health == HealthStatus.READY
      lastStatus == ConnectionStatus.Disconnected

    # Discovery adds mix peers to the peer store without any peer event.
    for i in 0 ..< MinMixPoolSize:
      nodeA.addMixPeer(62000 + i, lightpush = true)
    check await waitForStatus(ConnectionStatus.PartiallyConnected)

    # Pruning a single mix peer takes the pool below the minimum again.
    nodeA.peerManager.switch.peerStore.delete(nodeA.wakuMix.nodePool.peerIds()[0])
    check await waitForStatus(ConnectionStatus.Disconnected)

    await monitorA.stopHealthMonitor()
    await nodeB.stop()
    await nodeA.stop()

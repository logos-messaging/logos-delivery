{.used.}

import std/[strutils, sequtils, net, options, sets, tables]
import chronos, testutils/unittests, stew/byteutils
import libp2p/[peerid, peerinfo, multiaddress, crypto/crypto]
import ../testlib/[common, wakucore, wakunode, testasync]

import
  waku,
  waku/[
    waku_node,
    waku_core,
    common/broker/broker_context,
    events/message_events,
    waku_relay/protocol,
    node/kernel_api/filter,
    node/delivery_service/subscription_manager,
  ]
import waku/factory/waku_conf
import tools/confutils/cli_args

const TestTimeout = chronos.seconds(10)
const NegativeTestTimeout = chronos.seconds(2)

type ReceiveEventListenerManager = ref object
  brokerCtx: BrokerContext
  receivedListener: MessageReceivedEventListener
  receivedEvent: AsyncEvent
  receivedMessages: seq[WakuMessage]
  targetCount: int

proc newReceiveEventListenerManager(
    brokerCtx: BrokerContext, expectedCount: int = 1
): ReceiveEventListenerManager =
  let manager = ReceiveEventListenerManager(
    brokerCtx: brokerCtx, receivedMessages: @[], targetCount: expectedCount
  )
  manager.receivedEvent = newAsyncEvent()

  manager.receivedListener = MessageReceivedEvent
    .listen(
      brokerCtx,
      proc(event: MessageReceivedEvent) {.async: (raises: []).} =
        manager.receivedMessages.add(event.message)

        if manager.receivedMessages.len >= manager.targetCount:
          manager.receivedEvent.fire()
      ,
    )
    .expect("Failed to listen to MessageReceivedEvent")

  return manager

proc teardown(manager: ReceiveEventListenerManager) =
  MessageReceivedEvent.dropListener(manager.brokerCtx, manager.receivedListener)

proc waitForEvents(
    manager: ReceiveEventListenerManager, timeout: Duration
): Future[bool] {.async.} =
  return await manager.receivedEvent.wait().withTimeout(timeout)

type TestNetwork = ref object
  publisher: WakuNode # Relay node that publishes messages in tests.
  meshBuddy: WakuNode # Extra relay peer for publisher's mesh (Edge tests only).
  subscriber: Waku
    # The receiver node in tests. Edge node in edge tests, Core node in relay tests.
  publisherPeerInfo: RemotePeerInfo

proc createApiNodeConf(
    mode: cli_args.WakuMode = cli_args.WakuMode.Core, numShards: uint16 = 1
): WakuNodeConf =
  var conf = defaultWakuNodeConf().valueOr:
    raiseAssert error
  conf.mode = mode
  conf.listenAddress = parseIpAddress("0.0.0.0")
  conf.tcpPort = Port(0)
  conf.discv5UdpPort = Port(0)
  conf.clusterId = 3'u16
  conf.numShardsInNetwork = numShards
  conf.reliabilityEnabled = true
  conf.rest = false
  result = conf

proc setupSubscriberNode(conf: WakuNodeConf): Future[Waku] {.async.} =
  var node: Waku
  lockNewGlobalBrokerContext:
    node = (await createNode(conf)).expect("Failed to create subscriber node")
    (await startWaku(addr node)).expect("Failed to start subscriber node")
  return node

proc setupNetwork(
    numShards: uint16 = 1, mode: cli_args.WakuMode = cli_args.WakuMode.Core
): Future[TestNetwork] {.async.} =
  var net = TestNetwork()

  lockNewGlobalBrokerContext:
    net.publisher =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
    net.publisher.mountMetadata(3, toSeq(0'u16 ..< numShards)).expect(
      "Failed to mount metadata"
    )
    (await net.publisher.mountRelay()).expect("Failed to mount relay")
    if mode == cli_args.WakuMode.Edge:
      await net.publisher.mountFilter()
    await net.publisher.mountLibp2pPing()
    await net.publisher.start()

  net.publisherPeerInfo = net.publisher.peerInfo.toRemotePeerInfo()

  proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    discard

  var shards: seq[PubsubTopic]
  for i in 0 ..< numShards.int:
    shards.add(PubsubTopic("/waku/2/rs/3/" & $i))

  for shard in shards:
    net.publisher.subscribe((kind: PubsubSub, topic: shard), dummyHandler).expect(
      "Failed to sub publisher"
    )

  if mode == cli_args.WakuMode.Edge:
    lockNewGlobalBrokerContext:
      net.meshBuddy =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      net.meshBuddy.mountMetadata(3, toSeq(0'u16 ..< numShards)).expect(
        "Failed to mount metadata on meshBuddy"
      )
      (await net.meshBuddy.mountRelay()).expect("Failed to mount relay on meshBuddy")
      await net.meshBuddy.start()

    for shard in shards:
      net.meshBuddy.subscribe((kind: PubsubSub, topic: shard), dummyHandler).expect(
        "Failed to sub meshBuddy"
      )

    await net.meshBuddy.connectToNodes(@[net.publisherPeerInfo])

  net.subscriber = await setupSubscriberNode(createApiNodeConf(mode, numShards))

  await net.subscriber.node.connectToNodes(@[net.publisherPeerInfo])

  return net

proc teardown(net: TestNetwork) {.async.} =
  if not isNil(net.subscriber):
    (await net.subscriber.stop()).expect("Failed to stop subscriber node")
    net.subscriber = nil

  if not isNil(net.meshBuddy):
    await net.meshBuddy.stop()
    net.meshBuddy = nil

  if not isNil(net.publisher):
    await net.publisher.stop()
    net.publisher = nil

proc getRelayShard(node: WakuNode, contentTopic: ContentTopic): PubsubTopic =
  let autoSharding = node.wakuAutoSharding.get()
  let shardObj = autoSharding.getShard(contentTopic).expect("Failed to get shard")
  return PubsubTopic($shardObj)

proc waitForMesh(node: WakuNode, shard: PubsubTopic) {.async.} =
  for _ in 0 ..< 50:
    if node.wakuRelay.getNumPeersInMesh(shard).valueOr(0) > 0:
      return
    await sleepAsync(100.milliseconds)
  raise newException(ValueError, "GossipSub Mesh failed to stabilize on " & shard)

proc waitForEdgeSubs(w: Waku, shard: PubsubTopic) {.async.} =
  let sm = w.deliveryService.subscriptionManager
  for _ in 0 ..< 50:
    if sm.edgeFilterPeerCount(shard) > 0:
      return
    await sleepAsync(100.milliseconds)
  raise newException(ValueError, "Edge filter subscription failed on " & shard)

proc publishToMesh(
    net: TestNetwork, contentTopic: ContentTopic, payload: seq[byte]
): Future[Result[int, string]] {.async.} =
  # Publishes a message from "publisher" via relay into the gossipsub mesh.
  let shard = net.subscriber.node.getRelayShard(contentTopic)
  await waitForMesh(net.publisher, shard)
  let msg = WakuMessage(
    payload: payload, contentTopic: contentTopic, version: 0, timestamp: now()
  )
  return await net.publisher.publish(some(shard), msg)

proc publishToMeshAfterEdgeReady(
    net: TestNetwork, contentTopic: ContentTopic, payload: seq[byte]
): Future[Result[int, string]] {.async.} =
  # First, ensure "subscriber" node (an edge node) is subscribed and ready to receive.
  # Afterwards, "publisher" (relay node) sends the message in the gossipsub network.
  let shard = net.subscriber.node.getRelayShard(contentTopic)
  await waitForEdgeSubs(net.subscriber, shard)
  return await net.publishToMesh(contentTopic, payload)

suite "Messaging API, SubscriptionManager":
  asyncTest "Subscription API, relay node auto subscribe and receive message":
    let net = await setupNetwork(1)
    defer:
      await net.teardown()

    let testTopic = ContentTopic("/waku/2/test-content/proto")
    (await net.subscriber.subscribe(testTopic)).expect(
      "subscriberNode failed to subscribe"
    )

    let eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)
    defer:
      eventManager.teardown()

    discard (await net.publishToMesh(testTopic, "Hello, world!".toBytes())).expect(
      "Publish failed"
    )

    require await eventManager.waitForEvents(TestTimeout)
    require eventManager.receivedMessages.len == 1
    check eventManager.receivedMessages[0].contentTopic == testTopic

  asyncTest "Subscription API, relay node ignores unsubscribed content topics on same shard":
    let net = await setupNetwork(1)
    defer:
      await net.teardown()

    let subbedTopic = ContentTopic("/waku/2/subbed-topic/proto")
    let ignoredTopic = ContentTopic("/waku/2/ignored-topic/proto")
    (await net.subscriber.subscribe(subbedTopic)).expect("failed to subscribe")

    let eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)
    defer:
      eventManager.teardown()

    discard (await net.publishToMesh(ignoredTopic, "Ghost Msg".toBytes())).expect(
      "Publish failed"
    )

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    check eventManager.receivedMessages.len == 0

  asyncTest "Subscription API, relay node unsubscribe stops message receipt":
    let net = await setupNetwork(1)
    defer:
      await net.teardown()

    let testTopic = ContentTopic("/waku/2/unsub-test/proto")

    (await net.subscriber.subscribe(testTopic)).expect("failed to subscribe")
    net.subscriber.unsubscribe(testTopic).expect("failed to unsubscribe")

    let eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)
    defer:
      eventManager.teardown()

    discard (await net.publishToMesh(testTopic, "Should be dropped".toBytes())).expect(
      "Publish failed"
    )

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    check eventManager.receivedMessages.len == 0

  asyncTest "Subscription API, overlapping topics on same shard maintain correct isolation":
    let net = await setupNetwork(1)
    defer:
      await net.teardown()

    let topicA = ContentTopic("/waku/2/topic-a/proto")
    let topicB = ContentTopic("/waku/2/topic-b/proto")
    (await net.subscriber.subscribe(topicA)).expect("failed to sub A")
    (await net.subscriber.subscribe(topicB)).expect("failed to sub B")

    let eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)
    defer:
      eventManager.teardown()

    net.subscriber.unsubscribe(topicA).expect("failed to unsub A")

    discard (await net.publishToMesh(topicA, "Dropped Message".toBytes())).expect(
      "Publish A failed"
    )
    discard
      (await net.publishToMesh(topicB, "Kept Msg".toBytes())).expect("Publish B failed")

    require await eventManager.waitForEvents(TestTimeout)
    require eventManager.receivedMessages.len == 1
    check eventManager.receivedMessages[0].contentTopic == topicB

  asyncTest "Subscription API, redundant subs tolerated and subs are removed":
    let net = await setupNetwork(1)
    defer:
      await net.teardown()

    let glitchTopic = ContentTopic("/waku/2/glitch/proto")

    (await net.subscriber.subscribe(glitchTopic)).expect("failed to sub")
    (await net.subscriber.subscribe(glitchTopic)).expect("failed to double sub")
    net.subscriber.unsubscribe(glitchTopic).expect("failed to unsub")

    let eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)
    defer:
      eventManager.teardown()

    discard (await net.publishToMesh(glitchTopic, "Ghost Msg".toBytes())).expect(
      "Publish failed"
    )

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    check eventManager.receivedMessages.len == 0

  asyncTest "Subscription API, resubscribe to an unsubscribed topic":
    let net = await setupNetwork(1)
    defer:
      await net.teardown()

    let testTopic = ContentTopic("/waku/2/resub-test/proto")

    # Subscribe
    (await net.subscriber.subscribe(testTopic)).expect("Initial sub failed")

    var eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)
    discard
      (await net.publishToMesh(testTopic, "Msg 1".toBytes())).expect("Pub 1 failed")

    require await eventManager.waitForEvents(TestTimeout)
    eventManager.teardown()

    # Unsubscribe and verify teardown
    net.subscriber.unsubscribe(testTopic).expect("Unsub failed")
    eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)

    discard
      (await net.publishToMesh(testTopic, "Ghost".toBytes())).expect("Ghost pub failed")

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    eventManager.teardown()

    # Resubscribe
    (await net.subscriber.subscribe(testTopic)).expect("Resub failed")
    eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)

    discard
      (await net.publishToMesh(testTopic, "Msg 2".toBytes())).expect("Pub 2 failed")

    require await eventManager.waitForEvents(TestTimeout)
    check eventManager.receivedMessages[0].payload == "Msg 2".toBytes()

  asyncTest "Subscription API, two content topics in different shards":
    let net = await setupNetwork(8)
    defer:
      await net.teardown()

    var topicA = ContentTopic("/appA/2/shard-test-a/proto")
    var topicB = ContentTopic("/appB/2/shard-test-b/proto")

    # generate two content topics that land in two different shards
    var i = 0
    while net.subscriber.node.getRelayShard(topicA) ==
        net.subscriber.node.getRelayShard(topicB):
      topicB = ContentTopic("/appB" & $i & "/2/shard-test-b/proto")
      inc i

    (await net.subscriber.subscribe(topicA)).expect("failed to sub A")
    (await net.subscriber.subscribe(topicB)).expect("failed to sub B")

    let eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 2)
    defer:
      eventManager.teardown()

    discard (await net.publishToMesh(topicA, "Msg on Shard A".toBytes())).expect(
      "Publish A failed"
    )
    discard (await net.publishToMesh(topicB, "Msg on Shard B".toBytes())).expect(
      "Publish B failed"
    )

    require await eventManager.waitForEvents(TestTimeout)
    require eventManager.receivedMessages.len == 2

  asyncTest "Subscription API, many content topics in many shards":
    let net = await setupNetwork(8)
    defer:
      await net.teardown()

    var allTopics: seq[ContentTopic]
    for i in 0 ..< 100:
      allTopics.add(ContentTopic("/stress-app-" & $i & "/2/state-test/proto"))

    var activeSubs: seq[ContentTopic]

    proc verifyNetworkState(expected: seq[ContentTopic]) {.async.} =
      let eventManager =
        newReceiveEventListenerManager(net.subscriber.brokerCtx, expected.len)

      for topic in allTopics:
        discard (await net.publishToMesh(topic, "Stress Payload".toBytes())).expect(
          "publish failed"
        )

      require await eventManager.waitForEvents(TestTimeout)

      # here we just give a chance for any messages that we don't expect to arrive
      await sleepAsync(1.seconds)
      eventManager.teardown()

      # weak check (but catches most bugs)
      require eventManager.receivedMessages.len == expected.len

      # strict expected receipt test
      var receivedTopics = initHashSet[ContentTopic]()
      for msg in eventManager.receivedMessages:
        receivedTopics.incl(msg.contentTopic)
      var expectedTopics = initHashSet[ContentTopic]()
      for t in expected:
        expectedTopics.incl(t)

      check receivedTopics == expectedTopics

    # subscribe to all content topics we generated
    for t in allTopics:
      (await net.subscriber.subscribe(t)).expect("sub failed")
      activeSubs.add(t)

    await verifyNetworkState(activeSubs)

    # unsubscribe from some content topics
    for i in 0 ..< 50:
      let t = allTopics[i]
      net.subscriber.unsubscribe(t).expect("unsub failed")

      let idx = activeSubs.find(t)
      if idx >= 0:
        activeSubs.del(idx)

    await verifyNetworkState(activeSubs)

    # re-subscribe to some content topics
    for i in 0 ..< 25:
      let t = allTopics[i]
      (await net.subscriber.subscribe(t)).expect("resub failed")
      activeSubs.add(t)

    await verifyNetworkState(activeSubs)

  asyncTest "Subscription API, edge node subscribe and receive message":
    let net = await setupNetwork(1, cli_args.WakuMode.Edge)
    defer:
      await net.teardown()

    let testTopic = ContentTopic("/waku/2/test-content/proto")
    (await net.subscriber.subscribe(testTopic)).expect("failed to subscribe")

    let eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)
    defer:
      eventManager.teardown()

    discard (await net.publishToMeshAfterEdgeReady(testTopic, "Hello, edge!".toBytes())).expect(
      "Publish failed"
    )

    require await eventManager.waitForEvents(TestTimeout)
    require eventManager.receivedMessages.len == 1
    check eventManager.receivedMessages[0].contentTopic == testTopic

  asyncTest "Subscription API, edge node ignores unsubscribed content topics":
    let net = await setupNetwork(1, cli_args.WakuMode.Edge)
    defer:
      await net.teardown()

    let subbedTopic = ContentTopic("/waku/2/subbed-topic/proto")
    let ignoredTopic = ContentTopic("/waku/2/ignored-topic/proto")
    (await net.subscriber.subscribe(subbedTopic)).expect("failed to subscribe")

    let eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)
    defer:
      eventManager.teardown()

    discard (await net.publishToMesh(ignoredTopic, "Ghost Msg".toBytes())).expect(
      "Publish failed"
    )

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    check eventManager.receivedMessages.len == 0

  asyncTest "Subscription API, edge node unsubscribe stops message receipt":
    let net = await setupNetwork(1, cli_args.WakuMode.Edge)
    defer:
      await net.teardown()

    let testTopic = ContentTopic("/waku/2/unsub-test/proto")

    (await net.subscriber.subscribe(testTopic)).expect("failed to subscribe")
    net.subscriber.unsubscribe(testTopic).expect("failed to unsubscribe")

    let eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)
    defer:
      eventManager.teardown()

    discard (await net.publishToMesh(testTopic, "Should be dropped".toBytes())).expect(
      "Publish failed"
    )

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    check eventManager.receivedMessages.len == 0

  asyncTest "Subscription API, edge node overlapping topics isolation":
    let net = await setupNetwork(1, cli_args.WakuMode.Edge)
    defer:
      await net.teardown()

    let topicA = ContentTopic("/waku/2/topic-a/proto")
    let topicB = ContentTopic("/waku/2/topic-b/proto")
    (await net.subscriber.subscribe(topicA)).expect("failed to sub A")
    (await net.subscriber.subscribe(topicB)).expect("failed to sub B")

    let shard = net.subscriber.node.getRelayShard(topicA)
    await waitForEdgeSubs(net.subscriber, shard)

    let eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)
    defer:
      eventManager.teardown()

    net.subscriber.unsubscribe(topicA).expect("failed to unsub A")

    discard (await net.publishToMesh(topicA, "Dropped Message".toBytes())).expect(
      "Publish A failed"
    )
    discard
      (await net.publishToMesh(topicB, "Kept Msg".toBytes())).expect("Publish B failed")

    require await eventManager.waitForEvents(TestTimeout)
    require eventManager.receivedMessages.len == 1
    check eventManager.receivedMessages[0].contentTopic == topicB

  asyncTest "Subscription API, edge node resubscribe after unsubscribe":
    let net = await setupNetwork(1, cli_args.WakuMode.Edge)
    defer:
      await net.teardown()

    let testTopic = ContentTopic("/waku/2/resub-test/proto")

    (await net.subscriber.subscribe(testTopic)).expect("Initial sub failed")

    var eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)
    discard (await net.publishToMeshAfterEdgeReady(testTopic, "Msg 1".toBytes())).expect(
      "Pub 1 failed"
    )

    require await eventManager.waitForEvents(TestTimeout)
    eventManager.teardown()

    net.subscriber.unsubscribe(testTopic).expect("Unsub failed")
    eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)

    discard
      (await net.publishToMesh(testTopic, "Ghost".toBytes())).expect("Ghost pub failed")

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    eventManager.teardown()

    (await net.subscriber.subscribe(testTopic)).expect("Resub failed")
    eventManager = newReceiveEventListenerManager(net.subscriber.brokerCtx, 1)

    discard (await net.publishToMeshAfterEdgeReady(testTopic, "Msg 2".toBytes())).expect(
      "Pub 2 failed"
    )

    require await eventManager.waitForEvents(TestTimeout)
    check eventManager.receivedMessages[0].payload == "Msg 2".toBytes()

  asyncTest "Subscription API, edge node failover after service peer dies":
    # NOTE: This test is a bit more verbose because it defines a custom topology.
    #       It doesn't use the shared TestNetwork helper.
    #       This mounts two service peers for the edge node then fails one.
    let numShards: uint16 = 1
    let shards = @[PubsubTopic("/waku/2/rs/3/0")]

    proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      discard

    var publisher: WakuNode
    lockNewGlobalBrokerContext:
      publisher =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      publisher.mountMetadata(3, toSeq(0'u16 ..< numShards)).expect(
        "Failed to mount metadata on publisher"
      )
      (await publisher.mountRelay()).expect("Failed to mount relay on publisher")
      await publisher.mountFilter()
      await publisher.mountLibp2pPing()
      await publisher.start()

    for shard in shards:
      publisher.subscribe((kind: PubsubSub, topic: shard), dummyHandler).expect(
        "Failed to sub publisher"
      )

    let publisherPeerInfo = publisher.peerInfo.toRemotePeerInfo()

    var meshBuddy: WakuNode
    lockNewGlobalBrokerContext:
      meshBuddy =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      meshBuddy.mountMetadata(3, toSeq(0'u16 ..< numShards)).expect(
        "Failed to mount metadata on meshBuddy"
      )
      (await meshBuddy.mountRelay()).expect("Failed to mount relay on meshBuddy")
      await meshBuddy.mountFilter()
      await meshBuddy.mountLibp2pPing()
      await meshBuddy.start()

    for shard in shards:
      meshBuddy.subscribe((kind: PubsubSub, topic: shard), dummyHandler).expect(
        "Failed to sub meshBuddy"
      )

    let meshBuddyPeerInfo = meshBuddy.peerInfo.toRemotePeerInfo()

    await meshBuddy.connectToNodes(@[publisherPeerInfo])

    let conf = createApiNodeConf(cli_args.WakuMode.Edge, numShards)
    var subscriber: Waku
    lockNewGlobalBrokerContext:
      subscriber = (await createNode(conf)).expect("Failed to create edge subscriber")
      (await startWaku(addr subscriber)).expect("Failed to start edge subscriber")

    # Connect edge subscriber to both filter servers so selectPeers finds both
    await subscriber.node.connectToNodes(@[publisherPeerInfo, meshBuddyPeerInfo])

    let testTopic = ContentTopic("/waku/2/failover-test/proto")
    let shard = subscriber.node.getRelayShard(testTopic)

    (await subscriber.subscribe(testTopic)).expect("Failed to subscribe")

    # Wait for dialing both filter servers (HealthyThreshold = 2)
    for _ in 0 ..< 100:
      if subscriber.deliveryService.subscriptionManager.edgeFilterPeerCount(shard) >= 2:
        break
      await sleepAsync(100.milliseconds)

    check subscriber.deliveryService.subscriptionManager.edgeFilterPeerCount(shard) >= 2

    # Verify message delivery with both servers alive
    await waitForMesh(publisher, shard)

    var eventManager = newReceiveEventListenerManager(subscriber.brokerCtx, 1)
    let msg1 = WakuMessage(
      payload: "Before failover".toBytes(),
      contentTopic: testTopic,
      version: 0,
      timestamp: now(),
    )
    discard (await publisher.publish(some(shard), msg1)).expect("Publish 1 failed")

    require await eventManager.waitForEvents(TestTimeout)
    check eventManager.receivedMessages[0].payload == "Before failover".toBytes()
    eventManager.teardown()

    # Disconnect meshBuddy from edge (keeps relay mesh alive for publishing)
    await subscriber.node.disconnectNode(meshBuddyPeerInfo)

    # Wait for the dead peer to be pruned
    for _ in 0 ..< 50:
      if subscriber.deliveryService.subscriptionManager.edgeFilterPeerCount(shard) < 2:
        break
      await sleepAsync(100.milliseconds)

    check subscriber.deliveryService.subscriptionManager.edgeFilterPeerCount(shard) >= 1

    # Verify messages still arrive through the surviving filter server (publisher)
    eventManager = newReceiveEventListenerManager(subscriber.brokerCtx, 1)
    let msg2 = WakuMessage(
      payload: "After failover".toBytes(),
      contentTopic: testTopic,
      version: 0,
      timestamp: now(),
    )
    discard (await publisher.publish(some(shard), msg2)).expect("Publish 2 failed")

    require await eventManager.waitForEvents(TestTimeout)
    check eventManager.receivedMessages[0].payload == "After failover".toBytes()
    eventManager.teardown()

    (await subscriber.stop()).expect("Failed to stop subscriber")
    await meshBuddy.stop()
    await publisher.stop()

  asyncTest "Subscription API, edge node dials replacement after peer eviction":
    # 3 service peers: publisher, meshBuddy, sparePeer. Edge subscribes and
    # confirms 2 (HealthyThreshold). After one is disconnected, the sub loop
    # should detect the loss and dial the spare to recover back to threshold.
    let numShards: uint16 = 1
    let shards = @[PubsubTopic("/waku/2/rs/3/0")]

    proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      discard

    var publisher: WakuNode
    lockNewGlobalBrokerContext:
      publisher =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      publisher.mountMetadata(3, toSeq(0'u16 ..< numShards)).expect(
        "Failed to mount metadata on publisher"
      )
      (await publisher.mountRelay()).expect("Failed to mount relay on publisher")
      await publisher.mountFilter()
      await publisher.mountLibp2pPing()
      await publisher.start()

    for shard in shards:
      publisher.subscribe((kind: PubsubSub, topic: shard), dummyHandler).expect(
        "Failed to sub publisher"
      )

    let publisherPeerInfo = publisher.peerInfo.toRemotePeerInfo()

    var meshBuddy: WakuNode
    lockNewGlobalBrokerContext:
      meshBuddy =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      meshBuddy.mountMetadata(3, toSeq(0'u16 ..< numShards)).expect(
        "Failed to mount metadata on meshBuddy"
      )
      (await meshBuddy.mountRelay()).expect("Failed to mount relay on meshBuddy")
      await meshBuddy.mountFilter()
      await meshBuddy.mountLibp2pPing()
      await meshBuddy.start()

    for shard in shards:
      meshBuddy.subscribe((kind: PubsubSub, topic: shard), dummyHandler).expect(
        "Failed to sub meshBuddy"
      )

    let meshBuddyPeerInfo = meshBuddy.peerInfo.toRemotePeerInfo()

    var sparePeer: WakuNode
    lockNewGlobalBrokerContext:
      sparePeer =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      sparePeer.mountMetadata(3, toSeq(0'u16 ..< numShards)).expect(
        "Failed to mount metadata on sparePeer"
      )
      (await sparePeer.mountRelay()).expect("Failed to mount relay on sparePeer")
      await sparePeer.mountFilter()
      await sparePeer.mountLibp2pPing()
      await sparePeer.start()

    for shard in shards:
      sparePeer.subscribe((kind: PubsubSub, topic: shard), dummyHandler).expect(
        "Failed to sub sparePeer"
      )

    let sparePeerInfo = sparePeer.peerInfo.toRemotePeerInfo()

    await meshBuddy.connectToNodes(@[publisherPeerInfo])
    await sparePeer.connectToNodes(@[publisherPeerInfo])

    let conf = createApiNodeConf(cli_args.WakuMode.Edge, numShards)
    var subscriber: Waku
    lockNewGlobalBrokerContext:
      subscriber = (await createNode(conf)).expect("Failed to create edge subscriber")
      (await startWaku(addr subscriber)).expect("Failed to start edge subscriber")

    await subscriber.node.connectToNodes(
      @[publisherPeerInfo, meshBuddyPeerInfo, sparePeerInfo]
    )

    let testTopic = ContentTopic("/waku/2/replacement-test/proto")
    let shard = subscriber.node.getRelayShard(testTopic)

    (await subscriber.subscribe(testTopic)).expect("Failed to subscribe")

    # Wait for 2 confirmed peers (HealthyThreshold). The 3rd is available but not dialed.
    for _ in 0 ..< 100:
      if subscriber.deliveryService.subscriptionManager.edgeFilterPeerCount(shard) >= 2:
        break
      await sleepAsync(100.milliseconds)

    require subscriber.deliveryService.subscriptionManager.edgeFilterPeerCount(shard) == 2

    await subscriber.node.disconnectNode(meshBuddyPeerInfo)

    # Wait for the sub loop to detect the loss and dial a replacement
    for _ in 0 ..< 100:
      if subscriber.deliveryService.subscriptionManager.edgeFilterPeerCount(shard) >= 2:
        break
      await sleepAsync(100.milliseconds)

    check subscriber.deliveryService.subscriptionManager.edgeFilterPeerCount(shard) >= 2

    await waitForMesh(publisher, shard)

    var eventManager = newReceiveEventListenerManager(subscriber.brokerCtx, 1)
    let msg = WakuMessage(
      payload: "After replacement".toBytes(),
      contentTopic: testTopic,
      version: 0,
      timestamp: now(),
    )
    discard (await publisher.publish(some(shard), msg)).expect("Publish failed")

    require await eventManager.waitForEvents(TestTimeout)
    check eventManager.receivedMessages[0].payload == "After replacement".toBytes()
    eventManager.teardown()

    (await subscriber.stop()).expect("Failed to stop subscriber")
    await sparePeer.stop()
    await meshBuddy.stop()
    await publisher.stop()

{.used.}

import std/[strutils, net, options, sets]
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
  ]
import waku/api/api_conf, waku/factory/waku_conf

# TODO: Edge testing (after MAPI edge support is completed)

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
  publisher: WakuNode
  subscriber: Waku
  publisherPeerInfo: RemotePeerInfo

proc createApiNodeConf(
    mode: WakuMode = WakuMode.Core, numShards: uint16 = 1
): NodeConfig =
  let netConf = NetworkingConfig(listenIpv4: "0.0.0.0", p2pTcpPort: 0, discv5UdpPort: 0)
  result = NodeConfig.init(
    mode = mode,
    protocolsConfig = ProtocolsConfig.init(
      entryNodes = @[],
      clusterId = 1,
      autoShardingConfig = AutoShardingConfig(numShardsInCluster: numShards),
    ),
    networkingConfig = netConf,
    p2pReliability = true,
  )

proc setupSubscriberNode(conf: NodeConfig): Future[Waku] {.async.} =
  var node: Waku
  lockNewGlobalBrokerContext:
    node = (await createNode(conf)).expect("Failed to create subscriber node")
    (await startWaku(addr node)).expect("Failed to start subscriber node")
  return node

proc setupNetwork(
    numShards: uint16 = 1, mode: WakuMode = WakuMode.Core
): Future[TestNetwork] {.async.} =
  var net = TestNetwork()

  lockNewGlobalBrokerContext:
    net.publisher =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
    net.publisher.mountMetadata(1, @[0'u16]).expect("Failed to mount metadata")
    (await net.publisher.mountRelay()).expect("Failed to mount relay")
    await net.publisher.mountLibp2pPing()
    await net.publisher.start()

  net.publisherPeerInfo = net.publisher.peerInfo.toRemotePeerInfo()

  proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    discard

  # Subscribe the publisher to all shards to guarantee a GossipSub mesh with the subscriber.
  # Currently, Core/Relay nodes auto-subscribe to all network shards on boot, but if
  # that changes, this will be needed to cause the publisher to have shard interest
  # for any shards the subscriber may want to use, which is required for waitForMesh to work.
  for i in 0 ..< numShards.int:
    let shard = PubsubTopic("/waku/2/rs/1/" & $i)
    net.publisher.subscribe((kind: PubsubSub, topic: shard), dummyHandler).expect(
      "Failed to sub publisher"
    )

  net.subscriber = await setupSubscriberNode(createApiNodeConf(mode, numShards))

  await net.subscriber.node.connectToNodes(@[net.publisherPeerInfo])

  return net

proc teardown(net: TestNetwork) {.async.} =
  if not isNil(net.subscriber):
    (await net.subscriber.stop()).expect("Failed to stop subscriber node")
    net.subscriber = nil

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

proc publishToMesh(
    net: TestNetwork, contentTopic: ContentTopic, payload: seq[byte]
): Future[Result[int, string]] {.async.} =
  let shard = net.subscriber.node.getRelayShard(contentTopic)

  await waitForMesh(net.publisher, shard)

  let msg = WakuMessage(
    payload: payload, contentTopic: contentTopic, version: 0, timestamp: now()
  )
  return await net.publisher.publish(some(shard), msg)

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

{.used.}

import results, std/[strutils, sequtils, net, sets, tables]
import chronos, metrics, testutils/unittests, stew/byteutils
import libp2p/[peerid, peerinfo, multiaddress, crypto/crypto]
import brokers/broker_context
import ../testlib/[common, wakucore, wakunode, wakunodeconf, testasync, short_intervals]
import logos_delivery/messaging/messaging_client
import logos_delivery/messaging/messaging_metrics

import
  logos_delivery,
  logos_delivery/waku/[
    waku_node,
    waku_core,
    waku_relay/protocol,
    node/waku_node/filter,
    node/subscription_manager,
  ]
import logos_delivery/waku/factory/waku_conf
import tools/confutils/cli_args
import logos_delivery/api/conf/messaging_conf
import logos_delivery/api/conf/logos_delivery_conf
import logos_delivery/api/events/kernel_events
import logos_delivery/waku/api/events/filter_subscribe_events
import logos_delivery/waku/node/peer_manager/waku_peer_store
import logos_delivery/waku/waku_filter_v2/subscriptions

const TestTimeout = chronos.seconds(10)
const NegativeTestTimeout = chronos.seconds(2)
const EdgeWaitTimeout = chronos.seconds(60)

type ReceiveEventListenerManager = ref object
  brokerCtx: BrokerContext
  receivedListener: MessageReceivedEventListener
  receivedEvent: AsyncEvent
  receivedMessages: seq[WakuMessage]
  receivedSources: seq[MessageSource] ## one per `receivedMessages` entry
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
        manager.receivedSources.add(event.source)

        if manager.receivedMessages.len >= manager.targetCount:
          manager.receivedEvent.fire()
      ,
    )
    .expect("Failed to listen to MessageReceivedEvent")

  return manager

proc teardown(manager: ReceiveEventListenerManager) {.async.} =
  await MessageReceivedEvent.dropListener(manager.brokerCtx, manager.receivedListener)

proc waitForEvents(
    manager: ReceiveEventListenerManager, timeout: Duration
): Future[bool] {.async.} =
  return await manager.receivedEvent.wait().withTimeout(timeout)

type TestNetwork = ref object
  publisher: WakuNode # Relay node that publishes messages in tests.
  meshBuddy: WakuNode # Extra relay peer for publisher's mesh (Edge tests only).
  subscriber: LogosDelivery
    # The receiver node in tests. Edge node in edge tests, Core node in relay tests.
  publisherPeerInfo: RemotePeerInfo

proc setupSubscriberNode(conf: LogosDeliveryNodeConf): Future[LogosDelivery] {.async.} =
  var node: LogosDelivery
  lockNewGlobalBrokerContext:
    node = (await LogosDelivery.new(conf)).expect("Failed to create subscriber node")
    node.shortenIntervals()
    (await node.start()).expect("Failed to start subscriber node")
  return node

proc setupNetwork(
    numShards: uint16 = 1,
    mode: messaging_conf.LogosDeliveryMode = messaging_conf.LogosDeliveryMode.Core,
): Future[TestNetwork] {.async.} =
  var net = TestNetwork()

  lockNewGlobalBrokerContext:
    net.publisher = newTestWakuNode(generateSecp256k1Key())
    net.publisher.mountMetadata(TestClusterId, toSeq(0'u16 ..< numShards)).expect(
      "Failed to mount metadata"
    )
    (await net.publisher.mountRelay()).expect("Failed to mount relay")
    if mode == messaging_conf.LogosDeliveryMode.Edge:
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

  if mode == messaging_conf.LogosDeliveryMode.Edge:
    lockNewGlobalBrokerContext:
      net.meshBuddy = newTestWakuNode(generateSecp256k1Key())
      net.meshBuddy.mountMetadata(TestClusterId, toSeq(0'u16 ..< numShards)).expect(
        "Failed to mount metadata on meshBuddy"
      )
      (await net.meshBuddy.mountRelay()).expect("Failed to mount relay on meshBuddy")
      await net.meshBuddy.start()

    for shard in shards:
      net.meshBuddy.subscribe((kind: PubsubSub, topic: shard), dummyHandler).expect(
        "Failed to sub meshBuddy"
      )

    await net.meshBuddy.connectToNodes(@[net.publisherPeerInfo])

  net.subscriber = await setupSubscriberNode(defaultTestNodeConf(mode, numShards))

  await net.subscriber.waku.node.connectToNodes(@[net.publisherPeerInfo])

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
  let deadline = Moment.now() + EdgeWaitTimeout
  while Moment.now() < deadline:
    if node.wakuRelay.getNumPeersInMesh(shard).valueOr(0) > 0:
      return
    await sleepAsync(100.milliseconds)
  raise newException(ValueError, "GossipSub Mesh failed to stabilize on " & shard)

proc waitForEdgeSubs(w: LogosDelivery, shard: PubsubTopic) {.async.} =
  let deadline = Moment.now() + EdgeWaitTimeout
  while Moment.now() < deadline:
    if w.waku.node.subscriptionManager.edgeFilterPeerCount(shard) > 0:
      return
    await sleepAsync(100.milliseconds)
  raise newException(ValueError, "Edge filter subscription failed on " & shard)

proc edgePeersReached(
    w: LogosDelivery, shard: PubsubTopic, n: int
): Future[bool] {.async.} =
  let deadline = Moment.now() + EdgeWaitTimeout
  while Moment.now() < deadline:
    if w.waku.node.subscriptionManager.edgeFilterPeerCount(shard) >= n:
      return true
    await sleepAsync(100.milliseconds)
  return false

proc edgePeersDroppedBelow(
    w: LogosDelivery, shard: PubsubTopic, n: int
): Future[bool] {.async.} =
  let deadline = Moment.now() + EdgeWaitTimeout
  while Moment.now() < deadline:
    if w.waku.node.subscriptionManager.edgeFilterPeerCount(shard) < n:
      return true
    await sleepAsync(100.milliseconds)
  return false

proc publishToMesh(
    net: TestNetwork, contentTopic: ContentTopic, payload: seq[byte]
): Future[Result[int, string]] {.async.} =
  # Publishes a message from "publisher" via relay into the gossipsub mesh.
  let shard = net.subscriber.waku.node.getRelayShard(contentTopic)
  await waitForMesh(net.publisher, shard)
  let msg = WakuMessage(
    payload: payload, contentTopic: contentTopic, version: 0, timestamp: now()
  )
  return await net.publisher.publish(Opt.some(shard), msg)

proc publishToMeshAfterEdgeReady(
    net: TestNetwork, contentTopic: ContentTopic, payload: seq[byte]
): Future[Result[int, string]] {.async.} =
  # First, ensure "subscriber" node (an edge node) is subscribed and ready to receive.
  # Afterwards, "publisher" (relay node) sends the message in the gossipsub network.
  let shard = net.subscriber.waku.node.getRelayShard(contentTopic)
  await waitForEdgeSubs(net.subscriber, shard)
  return await net.publishToMesh(contentTopic, payload)

suite "Messaging API, SubscriptionManager":
  asyncTest "Subscription API, relay node auto subscribe and receive message":
    let net = await setupNetwork(1)
    defer:
      await net.teardown()

    let testTopic = ContentTopic("/waku/2/test-content/proto")
    (await net.subscriber.messagingClient.subscribe(testTopic)).expect(
      "subscriberNode failed to subscribe"
    )

    let eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
    defer:
      await eventManager.teardown()

    let live = $MessageSource.Live
    let countBefore = logos_delivery_recv_messages.value([live])
    let bytesBefore = logos_delivery_recv_message_bytes.value([live])
    let payload = "Hello, world!".toBytes()
    discard (await net.publishToMesh(testTopic, payload)).expect("Publish failed")

    require await eventManager.waitForEvents(TestTimeout)
    require eventManager.receivedMessages.len == 1
    check eventManager.receivedMessages[0].contentTopic == testTopic
    check eventManager.receivedSources[0] == MessageSource.Live
    check logos_delivery_recv_messages.value([live]) == countBefore + 1
    check logos_delivery_recv_message_bytes.value([live]) ==
      bytesBefore + float64(payload.len)

  asyncTest "Subscription API, relay node ignores unsubscribed content topics on same shard":
    let net = await setupNetwork(1)
    defer:
      await net.teardown()

    let subbedTopic = ContentTopic("/waku/2/subbed-topic/proto")
    let ignoredTopic = ContentTopic("/waku/2/ignored-topic/proto")
    (await net.subscriber.messagingClient.subscribe(subbedTopic)).expect(
      "failed to subscribe"
    )

    let eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
    defer:
      await eventManager.teardown()

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

    (await net.subscriber.messagingClient.subscribe(testTopic)).expect(
      "failed to subscribe"
    )
    net.subscriber.messagingClient.unsubscribe(testTopic).expect(
      "failed to unsubscribe"
    )

    let eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
    defer:
      await eventManager.teardown()

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
    (await net.subscriber.messagingClient.subscribe(topicA)).expect("failed to sub A")
    (await net.subscriber.messagingClient.subscribe(topicB)).expect("failed to sub B")

    let eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
    defer:
      await eventManager.teardown()

    net.subscriber.messagingClient.unsubscribe(topicA).expect("failed to unsub A")

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

    (await net.subscriber.messagingClient.subscribe(glitchTopic)).expect(
      "failed to sub"
    )
    (await net.subscriber.messagingClient.subscribe(glitchTopic)).expect(
      "failed to double sub"
    )
    net.subscriber.messagingClient.unsubscribe(glitchTopic).expect("failed to unsub")

    let eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
    defer:
      await eventManager.teardown()

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
    (await net.subscriber.messagingClient.subscribe(testTopic)).expect(
      "Initial sub failed"
    )

    var eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
    discard
      (await net.publishToMesh(testTopic, "Msg 1".toBytes())).expect("Pub 1 failed")

    require await eventManager.waitForEvents(TestTimeout)
    await eventManager.teardown()

    # Unsubscribe and verify teardown
    net.subscriber.messagingClient.unsubscribe(testTopic).expect("Unsub failed")
    eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)

    discard
      (await net.publishToMesh(testTopic, "Ghost".toBytes())).expect("Ghost pub failed")

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    await eventManager.teardown()

    # Resubscribe
    (await net.subscriber.messagingClient.subscribe(testTopic)).expect("Resub failed")
    eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)

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
    while net.subscriber.waku.node.getRelayShard(topicA) ==
        net.subscriber.waku.node.getRelayShard(topicB):
      topicB = ContentTopic("/appB" & $i & "/2/shard-test-b/proto")
      inc i

    (await net.subscriber.messagingClient.subscribe(topicA)).expect("failed to sub A")
    (await net.subscriber.messagingClient.subscribe(topicB)).expect("failed to sub B")

    let eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 2)
    defer:
      await eventManager.teardown()

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
        newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, expected.len)

      for topic in allTopics:
        discard (await net.publishToMesh(topic, "Stress Payload".toBytes())).expect(
          "publish failed"
        )

      require await eventManager.waitForEvents(TestTimeout)

      # here we just give a chance for any messages that we don't expect to arrive
      await sleepAsync(1.seconds)
      await eventManager.teardown()

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
      (await net.subscriber.messagingClient.subscribe(t)).expect("sub failed")
      activeSubs.add(t)

    await verifyNetworkState(activeSubs)

    # unsubscribe from some content topics
    for i in 0 ..< 50:
      let t = allTopics[i]
      net.subscriber.messagingClient.unsubscribe(t).expect("unsub failed")

      let idx = activeSubs.find(t)
      if idx >= 0:
        activeSubs.del(idx)

    await verifyNetworkState(activeSubs)

    # re-subscribe to some content topics
    for i in 0 ..< 25:
      let t = allTopics[i]
      (await net.subscriber.messagingClient.subscribe(t)).expect("resub failed")
      activeSubs.add(t)

    await verifyNetworkState(activeSubs)

  asyncTest "Subscription API, relay node configured with one shard is subscribed to every shard":
    var conf = defaultTestNodeConf(numShards = 8)
    conf.kernel.shards = @[1'u16]
    let node = await setupSubscriberNode(conf)
    defer:
      (await node.stop()).expect("Failed to stop node")

    let allShards =
      toSeq(0'u16 ..< 8'u16).mapIt($RelayShard(clusterId: TestClusterId, shardId: it))

    # The configured shards do not limit the relay subscription under autosharding.
    check:
      node.waku.node.wakuRelay.subscribedTopics().toHashSet() == allShards.toHashSet()

  asyncTest "Subscription API, edge node subscribe and receive message":
    let net = await setupNetwork(1, messaging_conf.LogosDeliveryMode.Edge)
    defer:
      await net.teardown()

    let testTopic = ContentTopic("/waku/2/test-content/proto")
    (await net.subscriber.messagingClient.subscribe(testTopic)).expect(
      "failed to subscribe"
    )

    let eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
    defer:
      await eventManager.teardown()

    discard (await net.publishToMeshAfterEdgeReady(testTopic, "Hello, edge!".toBytes())).expect(
      "Publish failed"
    )

    require await eventManager.waitForEvents(TestTimeout)
    require eventManager.receivedMessages.len == 1
    check eventManager.receivedMessages[0].contentTopic == testTopic
    check eventManager.receivedSources[0] == MessageSource.Live

  asyncTest "Subscription API, edge node ignores unsubscribed content topics":
    let net = await setupNetwork(1, messaging_conf.LogosDeliveryMode.Edge)
    defer:
      await net.teardown()

    let subbedTopic = ContentTopic("/waku/2/subbed-topic/proto")
    let ignoredTopic = ContentTopic("/waku/2/ignored-topic/proto")
    (await net.subscriber.messagingClient.subscribe(subbedTopic)).expect(
      "failed to subscribe"
    )

    let eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
    defer:
      await eventManager.teardown()

    discard (await net.publishToMesh(ignoredTopic, "Ghost Msg".toBytes())).expect(
      "Publish failed"
    )

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    check eventManager.receivedMessages.len == 0

  asyncTest "Subscription API, edge node unsubscribe stops message receipt":
    let net = await setupNetwork(1, messaging_conf.LogosDeliveryMode.Edge)
    defer:
      await net.teardown()

    let testTopic = ContentTopic("/waku/2/unsub-test/proto")

    (await net.subscriber.messagingClient.subscribe(testTopic)).expect(
      "failed to subscribe"
    )
    net.subscriber.messagingClient.unsubscribe(testTopic).expect(
      "failed to unsubscribe"
    )

    let eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
    defer:
      await eventManager.teardown()

    discard (await net.publishToMesh(testTopic, "Should be dropped".toBytes())).expect(
      "Publish failed"
    )

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    check eventManager.receivedMessages.len == 0

  asyncTest "Subscription API, edge node overlapping topics isolation":
    let net = await setupNetwork(1, messaging_conf.LogosDeliveryMode.Edge)
    defer:
      await net.teardown()

    let topicA = ContentTopic("/waku/2/topic-a/proto")
    let topicB = ContentTopic("/waku/2/topic-b/proto")
    (await net.subscriber.messagingClient.subscribe(topicA)).expect("failed to sub A")
    (await net.subscriber.messagingClient.subscribe(topicB)).expect("failed to sub B")

    let shard = net.subscriber.waku.node.getRelayShard(topicA)
    await waitForEdgeSubs(net.subscriber, shard)

    let eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
    defer:
      await eventManager.teardown()

    net.subscriber.messagingClient.unsubscribe(topicA).expect("failed to unsub A")

    discard (await net.publishToMesh(topicA, "Dropped Message".toBytes())).expect(
      "Publish A failed"
    )
    discard
      (await net.publishToMesh(topicB, "Kept Msg".toBytes())).expect("Publish B failed")

    require await eventManager.waitForEvents(TestTimeout)
    require eventManager.receivedMessages.len == 1
    check eventManager.receivedMessages[0].contentTopic == topicB

  asyncTest "Subscription API, edge node resubscribe after unsubscribe":
    let net = await setupNetwork(1, messaging_conf.LogosDeliveryMode.Edge)
    defer:
      await net.teardown()

    let testTopic = ContentTopic("/waku/2/resub-test/proto")

    (await net.subscriber.messagingClient.subscribe(testTopic)).expect(
      "Initial sub failed"
    )

    var eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
    discard (await net.publishToMeshAfterEdgeReady(testTopic, "Msg 1".toBytes())).expect(
      "Pub 1 failed"
    )

    require await eventManager.waitForEvents(TestTimeout)
    await eventManager.teardown()

    net.subscriber.messagingClient.unsubscribe(testTopic).expect("Unsub failed")
    eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)

    discard
      (await net.publishToMesh(testTopic, "Ghost".toBytes())).expect("Ghost pub failed")

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    await eventManager.teardown()

    (await net.subscriber.messagingClient.subscribe(testTopic)).expect("Resub failed")
    eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)

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
      publisher = newTestWakuNode(generateSecp256k1Key())
      publisher.mountMetadata(TestClusterId, toSeq(0'u16 ..< numShards)).expect(
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
      meshBuddy = newTestWakuNode(generateSecp256k1Key())
      meshBuddy.mountMetadata(TestClusterId, toSeq(0'u16 ..< numShards)).expect(
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

    let conf = defaultTestWakuNodeConf(messaging_conf.LogosDeliveryMode.Edge, numShards)
    var subscriber: LogosDelivery
    # The shipped debounce keeps the drop below two peers long enough to observe.
    lockNewGlobalBrokerContext:
      subscriber = (
        await LogosDelivery.new(
          testNodeConf(conf, mode = messaging_conf.LogosDeliveryMode.Edge)
        )
      ).expect("Failed to create edge subscriber")
      (await subscriber.start()).expect("Failed to start edge subscriber")

    # Connect edge subscriber to both filter servers so selectPeers finds both
    await subscriber.waku.node.connectToNodes(@[publisherPeerInfo, meshBuddyPeerInfo])

    let testTopic = ContentTopic("/waku/2/failover-test/proto")
    let shard = subscriber.waku.node.getRelayShard(testTopic)

    (await subscriber.messagingClient.subscribe(testTopic)).expect(
      "Failed to subscribe"
    )

    # Wait for dialing both filter servers (HealthyThreshold = 2)
    check await edgePeersReached(subscriber, shard, 2)

    # Verify message delivery with both servers alive
    await waitForMesh(publisher, shard)

    var eventManager = newReceiveEventListenerManager(subscriber.waku.brokerCtx, 1)
    let msg1 = WakuMessage(
      payload: "Before failover".toBytes(),
      contentTopic: testTopic,
      version: 0,
      timestamp: now(),
    )
    discard (await publisher.publish(Opt.some(shard), msg1)).expect("Publish 1 failed")

    require await eventManager.waitForEvents(TestTimeout)
    check eventManager.receivedMessages[0].payload == "Before failover".toBytes()
    await eventManager.teardown()

    # Disconnect meshBuddy from edge (keeps relay mesh alive for publishing)
    await subscriber.waku.node.disconnectNode(meshBuddyPeerInfo)

    # Wait for the dead peer to be pruned
    check await edgePeersDroppedBelow(subscriber, shard, 2)
    check subscriber.waku.node.subscriptionManager.edgeFilterPeerCount(shard) >= 1

    # Verify messages still arrive through the surviving filter server (publisher)
    eventManager = newReceiveEventListenerManager(subscriber.waku.brokerCtx, 1)
    let msg2 = WakuMessage(
      payload: "After failover".toBytes(),
      contentTopic: testTopic,
      version: 0,
      timestamp: now(),
    )
    discard (await publisher.publish(Opt.some(shard), msg2)).expect("Publish 2 failed")

    require await eventManager.waitForEvents(TestTimeout)
    check eventManager.receivedMessages[0].payload == "After failover".toBytes()
    await eventManager.teardown()

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
      publisher = newTestWakuNode(generateSecp256k1Key())
      publisher.mountMetadata(TestClusterId, toSeq(0'u16 ..< numShards)).expect(
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
      meshBuddy = newTestWakuNode(generateSecp256k1Key())
      meshBuddy.mountMetadata(TestClusterId, toSeq(0'u16 ..< numShards)).expect(
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
      sparePeer = newTestWakuNode(generateSecp256k1Key())
      sparePeer.mountMetadata(TestClusterId, toSeq(0'u16 ..< numShards)).expect(
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

    let conf = defaultTestWakuNodeConf(messaging_conf.LogosDeliveryMode.Edge, numShards)
    var subscriber: LogosDelivery
    lockNewGlobalBrokerContext:
      subscriber = (
        await LogosDelivery.new(
          testNodeConf(conf, mode = messaging_conf.LogosDeliveryMode.Edge)
        )
      ).expect("Failed to create edge subscriber")
      subscriber.shortenIntervals()
      (await subscriber.start()).expect("Failed to start edge subscriber")

    await subscriber.waku.node.connectToNodes(
      @[publisherPeerInfo, meshBuddyPeerInfo, sparePeerInfo]
    )

    let testTopic = ContentTopic("/waku/2/replacement-test/proto")
    let shard = subscriber.waku.node.getRelayShard(testTopic)

    (await subscriber.messagingClient.subscribe(testTopic)).expect(
      "Failed to subscribe"
    )

    # Wait for 2 confirmed peers (HealthyThreshold). The 3rd is available but not dialed.
    check await edgePeersReached(subscriber, shard, 2)
    require subscriber.waku.node.subscriptionManager.edgeFilterPeerCount(shard) == 2

    await subscriber.waku.node.disconnectNode(meshBuddyPeerInfo)

    # Wait for the sub loop to detect the loss and dial a replacement
    check await edgePeersReached(subscriber, shard, 2)

    await waitForMesh(publisher, shard)

    var eventManager = newReceiveEventListenerManager(subscriber.waku.brokerCtx, 1)
    let msg = WakuMessage(
      payload: "After replacement".toBytes(),
      contentTopic: testTopic,
      version: 0,
      timestamp: now(),
    )
    discard (await publisher.publish(Opt.some(shard), msg)).expect("Publish failed")

    require await eventManager.waitForEvents(TestTimeout)
    check eventManager.receivedMessages[0].payload == "After replacement".toBytes()
    await eventManager.teardown()

    (await subscriber.stop()).expect("Failed to stop subscriber")
    await sparePeer.stop()
    await meshBuddy.stop()
    await publisher.stop()

type WeakInterestNet = ref object
  servers: seq[WakuNode] ## relay and filter service nodes on `shard`
  edge: LogosDelivery
  shard: PubsubTopic
  unsubscribed: seq[ContentTopic] ## each `ContentTopicUnsubscribedEvent` of `edge`
  requests: seq[seq[ContentTopic]] ## the topics of each filter subscribe of `edge`
  unsubscribedListener: ContentTopicUnsubscribedEventListener
  requestListener: OnFilterSubscribeEventListener

proc setupWeakInterestNet(
    level = AnonymityLevel.None, pingInterval = Opt.none(Duration)
): Future[WeakInterestNet] {.async.} =
  ## Three service nodes, and an Edge node at `level` that connects to them.
  ## `pingInterval` replaces the short interval of the filter ping loop.
  let net = WeakInterestNet(shard: PubsubTopic("/waku/2/rs/" & $TestClusterId & "/0"))

  proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    discard

  for i in 0 ..< 3:
    var server: WakuNode
    lockNewGlobalBrokerContext:
      server = newTestWakuNode(generateSecp256k1Key())
      server.mountMetadata(TestClusterId, @[0'u16]).expect("mount metadata")
      (await server.mountRelay()).expect("mount relay")
      await server.mountFilter()
      await server.mountLibp2pPing()
      await server.start()
    server.subscribe((kind: PubsubSub, topic: net.shard), dummyHandler).expect(
      "subscribe the shard"
    )
    net.servers.add(server)

  let conf = LogosDeliveryConf(
    kernelConf:
      KernelConf(defaultTestWakuNodeConf(messaging_conf.LogosDeliveryMode.Edge)),
    messagingConf: Opt.some(MessagingClientConf(anonymityLevel: Opt.some(level))),
  )
  lockNewGlobalBrokerContext:
    net.edge = (await LogosDelivery.new(conf)).expect("create the edge node")
    net.edge.shortenIntervals()
    if pingInterval.isSome():
      net.edge.waku.node.subscriptionManager.edgeFilterLoopInterval = pingInterval.get()
    (await net.edge.start()).expect("start the edge node")

  let ctx = net.edge.waku.brokerCtx
  net.unsubscribedListener = ContentTopicUnsubscribedEvent
    .listen(
      ctx,
      proc(event: ContentTopicUnsubscribedEvent) {.async: (raises: []).} =
        net.unsubscribed.add(event.contentTopic),
    )
    .expect("listen to unsubscribes")
  net.requestListener = OnFilterSubscribeEvent
    .listen(
      ctx,
      proc(event: OnFilterSubscribeEvent) {.async: (raises: []).} =
        net.requests.add(event.contentTopics),
    )
    .expect("listen to filter subscribes")

  await net.edge.waku.node.connectToNodes(
    net.servers.mapIt(it.peerInfo.toRemotePeerInfo())
  )
  return net

proc teardown(net: WeakInterestNet) {.async.} =
  let ctx = net.edge.waku.brokerCtx
  await ContentTopicUnsubscribedEvent.dropListener(ctx, net.unsubscribedListener)
  await OnFilterSubscribeEvent.dropListener(ctx, net.requestListener)
  (await net.edge.stop()).expect("stop the edge node")
  for server in net.servers:
    await server.stop()

proc holds(net: WeakInterestNet, server: WakuNode, topic: ContentTopic): bool =
  ## True when `server` has a filter subscription of the edge node to `topic`.
  let edgePeerId = net.edge.waku.node.peerInfo.peerId
  return
    (net.shard, topic) in
    server.wakuFilter.subscriptions.getPeerSubscriptions(edgePeerId)

proc holders(net: WeakInterestNet): seq[WakuNode] =
  ## The service nodes that the edge node tracks for the shard.
  var tracked: seq[WakuNode]
  net.edge.waku.node.subscriptionManager.edgeFilterSubStates.withValue(net.shard, state):
    for server in net.servers:
      if state.peers.anyIt(it.peerId == server.peerInfo.peerId):
        tracked.add(server)
  return tracked

proc subscribed(net: WeakInterestNet, topic: ContentTopic): bool =
  return net.edge.waku.isSubscribed(topic).valueOr(false)

proc isWeak(net: WeakInterestNet, topic: ContentTopic): bool =
  net.edge.waku.node.subscriptionManager.shards.withValue(net.shard, sub):
    return topic in sub.weakTopics
  return false

proc holdsAll(net: WeakInterestNet, server: WakuNode, topics: seq[ContentTopic]): bool =
  return topics.allIt(net.holds(server, it))

proc requestCount(net: WeakInterestNet, topic: ContentTopic): int =
  return net.requests.countIt(topic in it)

proc placeInterest(
    net: WeakInterestNet, strong: seq[ContentTopic], weak: seq[ContentTopic]
) {.async.} =
  ## Subscribes `strong` as the app does and `weak` as a send does. Waits until
  ## two service nodes hold each topic, and the events of their requests came.
  for topic in strong:
    (await net.edge.messagingClient.subscribe(topic)).expect("subscribe")
  for topic in weak:
    net.edge.waku.subscribe(topic, weak = true).expect("weak subscribe")
  let topics = strong & weak
  checkUntilTimeout:
    net.holders().len == 2
    net.holders().allIt(net.holdsAll(it, topics))
    topics.allIt(net.requestCount(it) >= 2)
  require net.holders().len == 2

suite "Subscription API - the weak interest of a send":
  const Strong = ContentTopic("/waku/2/weak-interest-strong/proto")
  const Weak = ContentTopic("/waku/2/weak-interest-weak/proto")
  const Sent = ContentTopic("/waku/2/weak-interest-sent/proto")

  asyncTest "an Edge node at the Required level makes no subscription for a send":
    let net = await setupWeakInterestNet(AnonymityLevel.Required)
    defer:
      await net.teardown()
    let ctx = net.edge.waku.brokerCtx
    var failed: seq[RequestId]
    let listener = MessageErrorEvent
      .listen(
        ctx,
        proc(event: MessageErrorEvent) {.async: (raises: []).} =
          failed.add(event.requestId),
      )
      .expect("listen to send errors")
    defer:
      await MessageErrorEvent.dropListener(ctx, listener)

    let requestId = (
      await net.edge.messagingClient.send(MessageEnvelope.init(Sent, "anonymous"))
    ).expect("send")
    check not net.subscribed(Sent)
    # Mix is not mounted, so the send fails after `SendService.send` passed its
    # subscribe.
    checkUntilTimeout:
      requestId in failed
    check not net.subscribed(Sent)

    # A subscribe to a new filter peer carries the full interest set.
    await net.placeInterest(@[Strong], @[])
    check:
      net.servers.allIt(not net.holds(it, Sent))
      net.requests.allIt(Sent notin it)

  asyncTest "an Edge node drops a weak interest when it loses a filter service peer":
    let net = await setupWeakInterestNet()
    defer:
      await net.teardown()
    await net.placeInterest(@[Strong], @[Weak])
    let lost = net.holders()[0]
    let kept = net.holders()[1]

    await net.edge.waku.node.disconnectNode(lost.peerInfo.toRemotePeerInfo())

    checkUntilTimeout:
      Weak in net.unsubscribed
    check:
      not net.subscribed(Weak)
      net.subscribed(Strong)
    checkUntilTimeout:
      not net.holds(kept, Weak) # the other holder gets the unsubscribe

  asyncTest "an Edge node drops a weak interest when a filter service peer fails the ping":
    let net = await setupWeakInterestNet()
    defer:
      await net.teardown()
    await net.placeInterest(@[Strong], @[Weak])

    await net.holders()[0].wakuFilter.subscriptions.removePeer(
      net.edge.waku.node.peerInfo.peerId
    )

    checkUntilTimeout:
      Weak in net.unsubscribed
    check:
      not net.subscribed(Weak)
      net.subscribed(Strong)

  asyncTest "an Edge node drops a weak interest when a filter service peer refuses a request":
    const Strong2 = ContentTopic("/waku/2/weak-interest-strong-2/proto")
    # No ping comes first.
    let net = await setupWeakInterestNet(pingInterval = Opt.some(chronos.hours(1)))
    defer:
      await net.teardown()
    await net.placeInterest(@[Strong, Strong2], @[Weak])
    await net.holders()[0].wakuFilter.subscriptions.removePeer(
      net.edge.waku.node.peerInfo.peerId
    )

    # The holder that lost the subscription refuses this unsubscribe.
    net.edge.messagingClient.unsubscribe(Strong2).expect("unsubscribe")

    checkUntilTimeout:
      Weak in net.unsubscribed
    check:
      not net.subscribed(Weak)
      net.subscribed(Strong)

  asyncTest "an Edge node drops a weak interest when the peer store shows a filter service peer as not connected":
    ## The peer store shows the holder as not connected, and no disconnect
    ## event comes.
    let net = await setupWeakInterestNet()
    defer:
      await net.teardown()
    await net.placeInterest(@[Strong], @[Weak])
    let before = net.requests.len

    let peerStore = net.edge.waku.node.peerManager.switch.peerStore
    peerStore[ConnectionBook][net.holders()[0].peerInfo.peerId] = CannotConnect
    net.edge.waku.node.subscriptionManager.edgeFilterWakeup.fire()

    checkUntilTimeout:
      Weak in net.unsubscribed
      net.requests.len > before
    check:
      not net.subscribed(Weak)
      net.subscribed(Strong)
      net.requests[before ..^ 1].allIt(it == @[Strong])

  asyncTest "an app subscribe makes the weak interest of a send strong":
    let net = await setupWeakInterestNet()
    defer:
      await net.teardown()
    await net.placeInterest(@[Strong], @[Weak])

    # No lightpush peer, so the send does not go out.
    let envelope = MessageEnvelope.init(Sent, "plain")
    discard (await net.edge.messagingClient.send(envelope)).expect("send")
    check net.isWeak(Sent)
    (await net.edge.messagingClient.subscribe(Sent)).expect("subscribe")
    check not net.isWeak(Sent)

    await net.edge.waku.node.disconnectNode(
      net.holders()[0].peerInfo.toRemotePeerInfo()
    )

    checkUntilTimeout:
      Weak in net.unsubscribed
    check:
      net.subscribed(Sent)
      Sent notin net.unsubscribed

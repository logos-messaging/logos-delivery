{.used.}

import results, std/[strutils, sequtils, net, sets, tables]
import chronos, metrics, testutils/unittests, stew/byteutils
import libp2p/[peerid, peerinfo, peerstore, multiaddress, crypto/crypto]
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
    node/peer_manager,
    node/subscription_manager {.all.},
    node/edge_filter_sub_state,
    node/node_telemetry,
    node/health_monitor/connection_status,
    waku_filter_v2/subscriptions,
    waku_lightpush/common,
    api/events/peer_events,
  ]
import logos_delivery/waku/factory/waku_conf
import tools/confutils/cli_args
import logos_delivery/api/conf/messaging_conf
import logos_delivery/api/conf/logos_delivery_conf
import logos_delivery/waku/api/events/filter_subscribe_events
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

proc serveShard(node: WakuNode, shard: PubsubTopic) =
  proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    discard

  node.subscribe((kind: PubsubSub, topic: shard), dummyHandler).expect(
    "Failed to sub filterNode"
  )

proc newFilterServiceNode(
    shard: PubsubTopic, clusterId = TestClusterId, bindPort = Port(0), start = true
): Future[WakuNode] {.async.} =
  ## A relay node that serves filter on `shard`. With `start` false, the caller
  ## starts it and subscribes it to `shard` with `serveShard`.
  let shardId = RelayShard.parse(shard).get().shardId
  var filterNode: WakuNode
  lockNewGlobalBrokerContext:
    filterNode =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), bindPort)
    filterNode.mountMetadata(clusterId, @[shardId]).expect(
      "Failed to mount metadata on filterNode"
    )
    (await filterNode.mountRelay()).expect("Failed to mount relay on filterNode")
    await filterNode.mountFilter()
    await filterNode.mountLibp2pPing()
    if start:
      await filterNode.start()
  if start:
    filterNode.serveShard(shard)
  return filterNode

proc multiaddrOf(node: WakuNode): string =
  let info = node.peerInfo.toRemotePeerInfo()
  return $info.addrs[0] & "/p2p/" & $info.peerId

proc staticFilterPeerFailureCount(): float64 =
  try:
    return logos_delivery_node_errors.valueByName(
      "logos_delivery_node_errors_total", ["static_filter_peer_failure"]
    )
  except ValueError:
    return 0.0

proc checkEdgeSubscribesThroughFilternode(protocolsKnown: bool) {.async.} =
  ## An edge configured with only a filternode subscribes through it. With
  ## `protocolsKnown`, the peer store has the protocols of the filter node and
  ## no shards, as after peer persistence loads it from an earlier run.
  let shard = PubsubTopic("/waku/2/rs/3/0")

  let filterNode = await newFilterServiceNode(shard)
  defer:
    await filterNode.stop()

  let filterPeerInfo = filterNode.peerInfo.toRemotePeerInfo()
  let filterAddr = filterNode.multiaddrOf()

  var conf = defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
  conf.kernel.filternode = filterAddr
  let subscriber = await setupSubscriberNode(conf)
  defer:
    (await subscriber.stop()).expect("Failed to stop subscriber")

  let peerStore = subscriber.waku.node.peerManager.switch.peerStore
  if protocolsKnown:
    peerStore[ProtoBook][filterPeerInfo.peerId] = @[WakuFilterSubscribeCodec]
  check:
    subscriber.waku.node.peerManager.serviceSlots.getOrDefault(
      WakuFilterSubscribeCodec, RemotePeerInfo()
    ).peerId == filterPeerInfo.peerId
    peerStore.connectedness(filterPeerInfo.peerId) == NotConnected

  let testTopic = ContentTopic("/waku/2/filternode/proto")
  (await subscriber.messagingClient.subscribe(testTopic)).expect("Failed to subscribe")

  check subscriber.waku.node.getRelayShard(testTopic) == shard
  let edgePeerId = subscriber.waku.node.peerInfo.peerId
  checkUntilTimeout:
    edgePeerId in
      filterNode.wakuFilter.subscriptions.findSubscribedPeers(shard, testTopic)
    subscriber.waku.node.subscriptionManager.edgeFilterPeerCount(shard) == 1
    peerStore.connectedness(filterPeerInfo.peerId) == Connected

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

  asyncTest "Subscription API, relay node configured with one shard is subscribed to that shard only":
    var conf = defaultTestNodeConf(numShards = 8)
    conf.kernel.shards = @[1'u16]
    let node = await setupSubscriberNode(conf)
    defer:
      (await node.stop()).expect("Failed to stop node")

    check:
      node.waku.node.wakuRelay.subscribedTopics().toHashSet() ==
        [$RelayShard(clusterId: TestClusterId, shardId: 1)].toHashSet()

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

  asyncTest "Subscription API, edge node unsubscribes a topic the service no longer holds without dropping its service peer":
    let net = await setupNetwork(1, messaging_conf.LogosDeliveryMode.Edge)
    defer:
      await net.teardown()

    let keptTopic = ContentTopic("/waku/2/kept-topic/proto")
    let staleTopic = ContentTopic("/waku/2/stale-topic/proto")
    let removedTopic = ContentTopic("/waku/2/removed-topic/proto")
    for topic in [keptTopic, staleTopic, removedTopic]:
      (await net.subscriber.messagingClient.subscribe(topic)).expect(
        "failed to subscribe"
      )

    let shard = net.subscriber.waku.node.getRelayShard(keptTopic)
    let edgePeerId = net.subscriber.waku.node.peerInfo.peerId
    let subscriptions = net.publisher.wakuFilter.subscriptions

    checkUntilTimeout:
      edgePeerId in subscriptions.findSubscribedPeers(shard, keptTopic)
      edgePeerId in subscriptions.findSubscribedPeers(shard, staleTopic)
      edgePeerId in subscriptions.findSubscribedPeers(shard, removedTopic)

    (
      await net.subscriber.waku.node.filterUnsubscribe(
        Opt.some(shard), removedTopic, net.publisherPeerInfo
      )
    ).expect("failed to filter-unsubscribe")

    # The service ignores removedTopic, which the edge no longer holds, and removes staleTopic.
    net.subscriber.messagingClient.unsubscribe(staleTopic).expect(
      "failed to unsub stale"
    )
    net.subscriber.messagingClient.unsubscribe(removedTopic).expect(
      "failed to unsub removed"
    )

    checkUntilTimeout:
      edgePeerId notin subscriptions.findSubscribedPeers(shard, staleTopic)
    check:
      edgePeerId in subscriptions.findSubscribedPeers(shard, keptTopic)
      edgePeerId notin subscriptions.findSubscribedPeers(shard, removedTopic)

  asyncTest "Subscription API, edge node subscribes through its filternode":
    await checkEdgeSubscribesThroughFilternode(protocolsKnown = false)

  asyncTest "Subscription API, edge node subscribes through its filternode with known protocols":
    await checkEdgeSubscribesThroughFilternode(protocolsKnown = true)

  asyncTest "Subscription API, edge node counts its filternode as one of the filter peers a shard needs":
    let shard = PubsubTopic("/waku/2/rs/3/0")
    var conf = defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
    conf.kernel.filternode =
      "/ip4/127.0.0.1/tcp/1/p2p/" & $PeerId.random(crypto.newRng()).get()
    let subscriber = await setupSubscriberNode(conf)
    defer:
      (await subscriber.stop()).expect("Failed to stop subscriber")

    # Filter peer A serves the shard. The filternode S is down.
    let peerStore = subscriber.waku.node.peerManager.switch.peerStore
    let peerA = RemotePeerInfo.init(
      PeerId.random(crypto.newRng()).get(),
      @[MultiAddress.init("/ip4/127.0.0.1/tcp/2").get()],
      protocols = @[WakuFilterSubscribeCodec],
    )
    peerStore.addPeer(peerA)
    peerStore.setShardInfo(peerA.peerId, @[0'u16])
    let staticPeer = subscriber.waku.node.peerManager.serviceSlots.getOrDefault(
      WakuFilterSubscribeCodec, RemotePeerInfo()
    )

    let manager = subscriber.waku.node.subscriptionManager
    check:
      manager
        .selectFilterCandidates(shard, initHashSet[PeerId](), 1, Opt.some(staticPeer))
        .mapIt(it.peerId) == @[staticPeer.peerId]
      manager
        .selectFilterCandidates(shard, initHashSet[PeerId](), 2, Opt.some(staticPeer))
        .mapIt(it.peerId) == @[staticPeer.peerId, peerA.peerId]

  asyncTest "Subscription API, edge node skips a filternode whose known protocols miss filter":
    let shard = PubsubTopic("/waku/2/rs/3/0")
    let staticPeerId = PeerId.random(crypto.newRng()).get()
    var conf = defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
    conf.kernel.filternode = "/ip4/127.0.0.1/tcp/1/p2p/" & $staticPeerId
    let subscriber = await setupSubscriberNode(conf)
    defer:
      (await subscriber.stop()).expect("Failed to stop subscriber")

    let peerStore = subscriber.waku.node.peerManager.switch.peerStore
    peerStore[ProtoBook][staticPeerId] = @[WakuLightPushCodec]
    let failuresBefore = staticFilterPeerFailureCount()

    let manager = subscriber.waku.node.subscriptionManager
    var state = EdgeFilterSubState()
    check:
      manager.staticFilterPeer(shard, state, initHashSet[PeerId]()).isNone()
      state.staticFilterPeerTries == MaxStaticFilterPeerTries
      staticFilterPeerFailureCount() == failuresBefore + 1

    # With its tries done, the edge skips it with no new failure.
    check:
      manager.staticFilterPeer(shard, state, initHashSet[PeerId]()).isNone()
      staticFilterPeerFailureCount() == failuresBefore + 1

  asyncTest "Subscription API, edge node fills the shard with other filter peers after the tries of a down filternode":
    let shard = PubsubTopic("/waku/2/rs/3/0")
    let filterNodeA = await newFilterServiceNode(shard)
    let filterNodeB = await newFilterServiceNode(shard)
    let filterNodes = @[filterNodeA, filterNodeB]
    defer:
      for filterNode in filterNodes:
        await filterNode.stop()

    # The filternode is down.
    var conf = defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
    conf.kernel.filternode =
      "/ip4/127.0.0.1/tcp/1/p2p/" & $PeerId.random(crypto.newRng()).get()
    let subscriber = await setupSubscriberNode(conf)
    defer:
      (await subscriber.stop()).expect("Failed to stop subscriber")

    let peerStore = subscriber.waku.node.peerManager.switch.peerStore
    for filterNode in filterNodes:
      let info = filterNode.peerInfo.toRemotePeerInfo()
      peerStore.addPeer(
        RemotePeerInfo.init(
          info.peerId, info.addrs, protocols = @[WakuFilterSubscribeCodec]
        )
      )
      peerStore.setShardInfo(info.peerId, @[0'u16])
    let failuresBefore = staticFilterPeerFailureCount()

    let testTopic = ContentTopic("/waku/2/filternode/proto")
    (await subscriber.messagingClient.subscribe(testTopic)).expect(
      "Failed to subscribe"
    )
    check subscriber.waku.node.getRelayShard(testTopic) == shard

    let manager = subscriber.waku.node.subscriptionManager
    let edgePeerId = subscriber.waku.node.peerInfo.peerId
    checkUntilTimeout:
      manager.edgeFilterPeerCount(shard) == HealthyThreshold
      filterNodes.allIt(
        edgePeerId in it.wakuFilter.subscriptions.findSubscribedPeers(shard, testTopic)
      )
    check:
      staticFilterPeerFailureCount() >= failuresBefore + MaxStaticFilterPeerTries

  asyncTest "Subscription API, edge node drops a filternode whose metadata misses the shard":
    let shard = PubsubTopic("/waku/2/rs/3/0")
    let otherShardNode = await newFilterServiceNode(PubsubTopic("/waku/2/rs/3/1"))
    defer:
      await otherShardNode.stop()
    let otherId = otherShardNode.peerInfo.peerId

    var conf = defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
    conf.kernel.filternode = otherShardNode.multiaddrOf()
    let subscriber = await setupSubscriberNode(conf)
    defer:
      (await subscriber.stop()).expect("Failed to stop subscriber")

    let testTopic = ContentTopic("/waku/2/filternode/proto")
    (await subscriber.messagingClient.subscribe(testTopic)).expect(
      "Failed to subscribe"
    )
    check subscriber.waku.node.getRelayShard(testTopic) == shard

    let peerStore = subscriber.waku.node.peerManager.switch.peerStore
    checkUntilTimeout:
      peerStore.getPeer(otherId).shards == @[1'u16]
    # Three intervals of the edge loops give each loop time to act on the metadata.
    await sleepAsync(
      subscriber.waku.node.subscriptionManager.edgeFilterLoopInterval * 3
    )
    let edgePeerId = subscriber.waku.node.peerInfo.peerId
    check:
      subscriber.waku.node.subscriptionManager.edgeFilterPeerCount(shard) == 0
      edgePeerId notin
        otherShardNode.wakuFilter.subscriptions.findSubscribedPeers(shard, testTopic)

  asyncTest "Subscription API, edge node dials a filternode of another cluster at most its tries each interval":
    let otherCluster = TestClusterId + 1
    let otherClusterNode = await newFilterServiceNode(
      PubsubTopic("/waku/2/rs/" & $otherCluster & "/0"), clusterId = otherCluster
    )
    defer:
      await otherClusterNode.stop()
    let otherId = otherClusterNode.peerInfo.peerId

    var conf = defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
    conf.kernel.filternode = otherClusterNode.multiaddrOf()
    let subscriber = await setupSubscriberNode(conf)
    defer:
      (await subscriber.stop()).expect("Failed to stop subscriber")

    let brokerCtx = subscriber.waku.node.brokerCtx
    var connects = 0
    let onPeerEvent = proc(
        evt: WakuPeerEvent
    ): Future[void] {.async: (raises: []), gcsafe.} =
      if evt.peerId == otherId and evt.kind == WakuPeerEventKind.EventConnected:
        inc connects

    let listener = WakuPeerEvent.listen(brokerCtx, onPeerEvent).expect(
        "Failed to listen to peer events"
      )
    defer:
      await WakuPeerEvent.dropListener(brokerCtx, listener)

    (
      await subscriber.messagingClient.subscribe(
        ContentTopic("/waku/2/filternode/proto")
      )
    ).expect("Failed to subscribe")

    # The metadata check drops the peer after each dial. Over three intervals,
    # the edge dials it about `MaxStaticFilterPeerTries` times each interval,
    # not once each wake.
    await sleepAsync(
      subscriber.waku.node.subscriptionManager.edgeFilterLoopInterval * 3
    )
    check connects in 1 .. 4 * MaxStaticFilterPeerTries

  asyncTest "Subscription API, edge node subscribes through a filternode that starts later":
    let shard = PubsubTopic("/waku/2/rs/3/0")
    let port = block:
      let probe = createStreamServer(initTAddress("127.0.0.1", Port(0)))
      let p = probe.localAddress().port
      await probe.closeWait()
      p
    let lateNode = await newFilterServiceNode(shard, bindPort = port, start = false)
    defer:
      await lateNode.stop()

    var conf = defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
    conf.kernel.filternode =
      "/ip4/127.0.0.1/tcp/" & $port & "/p2p/" & $lateNode.peerInfo.peerId
    let subscriber = await setupSubscriberNode(conf)
    defer:
      (await subscriber.stop()).expect("Failed to stop subscriber")

    let testTopic = ContentTopic("/waku/2/filternode/proto")
    (await subscriber.messagingClient.subscribe(testTopic)).expect(
      "Failed to subscribe"
    )
    check subscriber.waku.node.getRelayShard(testTopic) == shard

    # The first dial fails, because the filter node is not up yet.
    await sleepAsync(NegativeTestTimeout)
    await lateNode.start()
    lateNode.serveShard(shard)

    let edgePeerId = subscriber.waku.node.peerInfo.peerId
    checkUntilTimeout:
      edgePeerId in
        lateNode.wakuFilter.subscriptions.findSubscribedPeers(shard, testTopic)

type SendSubscriptionNet = ref object
  servers: seq[WakuNode] ## relay and filter service nodes on `shard`
  edge: LogosDelivery
  shard: PubsubTopic
  requests: seq[seq[ContentTopic]] ## the topics of each filter subscribe of `edge`
  requestListener: OnFilterSubscribeEventListener

proc setupSendSubscriptionNet(
    level: AnonymityLevel
): Future[SendSubscriptionNet] {.async.} =
  ## Two service nodes, and an Edge node at `level` that connects to them.
  let net =
    SendSubscriptionNet(shard: PubsubTopic("/waku/2/rs/" & $TestClusterId & "/0"))

  proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    discard

  for i in 0 ..< 2:
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
    (await net.edge.start()).expect("start the edge node")

  net.requestListener = OnFilterSubscribeEvent
    .listen(
      net.edge.waku.brokerCtx,
      proc(event: OnFilterSubscribeEvent) {.async: (raises: []).} =
        net.requests.add(event.contentTopics),
    )
    .expect("listen to filter subscribes")

  await net.edge.waku.node.connectToNodes(
    net.servers.mapIt(it.peerInfo.toRemotePeerInfo())
  )
  return net

proc teardown(net: SendSubscriptionNet) {.async.} =
  await OnFilterSubscribeEvent.dropListener(
    net.edge.waku.brokerCtx, net.requestListener
  )
  (await net.edge.stop()).expect("stop the edge node")
  for server in net.servers:
    await server.stop()

proc holds(net: SendSubscriptionNet, server: WakuNode, topic: ContentTopic): bool =
  ## True when `server` has a filter subscription of the edge node to `topic`.
  let edgePeerId = net.edge.waku.node.peerInfo.peerId
  return
    (net.shard, topic) in
    server.wakuFilter.subscriptions.getPeerSubscriptions(edgePeerId)

proc holders(net: SendSubscriptionNet): seq[WakuNode] =
  ## The service nodes that the edge node tracks for the shard.
  var tracked: seq[WakuNode]
  net.edge.waku.node.subscriptionManager.edgeFilterSubStates.withValue(net.shard, state):
    for server in net.servers:
      if state.peers.anyIt(it.peerId == server.peerInfo.peerId):
        tracked.add(server)
  return tracked

proc subscribed(net: SendSubscriptionNet, topic: ContentTopic): bool =
  return net.edge.waku.isSubscribed(topic).valueOr(false)

proc holdsAll(
    net: SendSubscriptionNet, server: WakuNode, topics: seq[ContentTopic]
): bool =
  return topics.allIt(net.holds(server, it))

proc requestCount(net: SendSubscriptionNet, topic: ContentTopic): int =
  return net.requests.countIt(topic in it)

proc waitForHolders(net: SendSubscriptionNet, topics: seq[ContentTopic]) {.async.} =
  ## Waits until two service nodes hold each topic, and the events of their
  ## requests came.
  checkUntilTimeout:
    net.holders().len == 2
    net.holders().allIt(net.holdsAll(it, topics))
    topics.allIt(net.requestCount(it) >= 2)
  require net.holders().len == 2

suite "Subscription API - the subscription of a send":
  const App = ContentTopic("/waku/2/send-subscription-app/proto")
  const Sent = ContentTopic("/waku/2/send-subscription-sent/proto")

  asyncTest "an Edge node at the Required level makes no subscription for a send":
    let net = await setupSendSubscriptionNet(AnonymityLevel.Required)
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
    # Mix is not mounted, so the queued send fails. The API send made no
    # subscription.
    checkUntilTimeout:
      requestId in failed
    check not net.subscribed(Sent)

    # A subscribe to a new filter peer carries the full interest set.
    (await net.edge.messagingClient.subscribe(App)).expect("subscribe")
    await net.waitForHolders(@[App])
    check:
      net.servers.allIt(not net.holds(it, Sent))
      net.requests.allIt(Sent notin it)

  asyncTest "an Edge node at the None level subscribes for a send":
    let net = await setupSendSubscriptionNet(AnonymityLevel.None)
    defer:
      await net.teardown()

    # No lightpush peer, so the send does not go out.
    discard (await net.edge.messagingClient.send(MessageEnvelope.init(Sent, "plain"))).expect(
      "send"
    )
    check net.subscribed(Sent)
    await net.waitForHolders(@[Sent])

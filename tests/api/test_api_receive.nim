{.used.}

import std/[options, sequtils, net, sets]
import chronos, testutils/unittests, stew/byteutils
import libp2p/[peerid, peerinfo, crypto/crypto]
import brokers/broker_context
import ../testlib/[common, wakucore, wakunode, testasync]
import ../waku_archive/archive_utils
import logos_delivery/messaging/messaging_client
import logos_delivery/messaging/delivery_service/recv_service

import
  logos_delivery,
  logos_delivery/waku/[
    waku_node,
    waku_core,
    api/events/health_events,
    waku_relay/protocol,
    waku_archive,
    waku_archive/common as archive_common,
  ]
import logos_delivery/waku/factory/waku_conf
import tools/confutils/cli_args

const TestTimeout = chronos.seconds(60)

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

proc teardown(manager: ReceiveEventListenerManager) {.async.} =
  await MessageReceivedEvent.dropListener(manager.brokerCtx, manager.receivedListener)

proc waitForEvents(
    manager: ReceiveEventListenerManager, timeout: Duration
): Future[bool] {.async.} =
  return await manager.receivedEvent.wait().withTimeout(timeout)

proc waitForConnectionStatus(
    brokerCtx: BrokerContext, expected: ConnectionStatus
) {.async.} =
  ## Completes when the node reports `expected`.
  var future = newFuture[void]("waitForConnectionStatus")

  let handler: EventConnectionStatusChangeListenerProc = proc(
      e: EventConnectionStatusChange
  ) {.async: (raises: []), gcsafe.} =
    if not future.finished and e.connectionStatus == expected:
      future.complete()

  let handle = EventConnectionStatusChange.listen(brokerCtx, handler).valueOr:
    raiseAssert error

  try:
    if not await future.withTimeout(TestTimeout):
      raiseAssert "Timeout waiting for status: " & $expected
  finally:
    await EventConnectionStatusChange.dropListener(brokerCtx, handle)

proc createApiNodeConf(numShards: uint16 = 1): WakuNodeConf =
  var conf = defaultWakuNodeConf().valueOr:
    raiseAssert error
  conf.mode = cli_args.WakuMode.Core
  conf.listenAddress = parseIpAddress("0.0.0.0")
  conf.tcpPort = Port(0)
  conf.discv5UdpPort = Port(0)
  conf.clusterId = some(3'u16)
  conf.numShardsInNetwork = numShards
  conf.reliabilityEnabled = some(true)
  conf.rest = false
  result = conf

type TestNetwork = ref object
  storeNode: WakuNode
  publisher: WakuNode
  subscriber: LogosDelivery
  storeNodePeerInfo: RemotePeerInfo
  missedPayload: seq[byte]

proc setupNetwork(testTopic: ContentTopic): Future[TestNetwork] {.async.} =
  ## Returns a started subscriber subscribed to `testTopic` but not yet connected
  ## to the store, with a message sitting in the store it never saw live.
  const numShards: uint16 = 1
  let shard = PubsubTopic("/waku/2/rs/3/0")

  proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    discard

  # store node: archive + store + relay, subscribed to the shard
  var storeNode: WakuNode
  lockNewGlobalBrokerContext:
    storeNode =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
    storeNode.mountMetadata(3, toSeq(0'u16 ..< numShards)).expect(
      "Failed to mount metadata on storeNode"
    )
    (await storeNode.mountRelay()).expect("Failed to mount relay on storeNode")
    storeNode.mountArchive(newSqliteArchiveDriver()).expect("Failed to mount archive")
    await storeNode.mountStore()
    await storeNode.mountLibp2pPing()
    await storeNode.start()
  storeNode.subscribe((kind: PubsubSub, topic: shard), dummyHandler).expect(
    "Failed to sub storeNode"
  )

  let storeNodePeerInfo = storeNode.peerInfo.toRemotePeerInfo()

  # publisher: relay, connected to the store so its messages get archived
  var publisher: WakuNode
  lockNewGlobalBrokerContext:
    publisher =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
    publisher.mountMetadata(3, toSeq(0'u16 ..< numShards)).expect(
      "Failed to mount metadata on publisher"
    )
    (await publisher.mountRelay()).expect("Failed to mount relay on publisher")
    await publisher.mountLibp2pPing()
    await publisher.start()
  publisher.subscribe((kind: PubsubSub, topic: shard), dummyHandler).expect(
    "Failed to sub publisher"
  )

  await publisher.connectToNodes(@[storeNodePeerInfo])

  var meshFormed = false
  for _ in 0 ..< 50:
    if publisher.wakuRelay.getNumPeersInMesh(shard).valueOr(0) > 0:
      meshFormed = true
      break
    await sleepAsync(100.milliseconds)
  if not meshFormed:
    raiseAssert "publisher<->store relay mesh did not form in time"

  # subscriber: created before the publish so the message timestamp lands after
  # its RecvService startTimeToCheck watermark
  var subscriber: LogosDelivery
  lockNewGlobalBrokerContext:
    subscriber = (await LogosDelivery.new(createApiNodeConf(numShards))).expect(
      "Failed to create subscriber"
    )
    (await subscriber.start()).expect("Failed to start subscriber")

  # publish while the subscriber is offline: the message reaches the archive but
  # the subscriber never sees it via live relay
  let missedPayload = "This message was missed".toBytes()
  let missedMsg = WakuMessage(
    payload: missedPayload, contentTopic: testTopic, version: 0, timestamp: now()
  )
  discard (await publisher.publish(some(shard), missedMsg)).expect(
    "Publish missed msg failed"
  )

  block waitArchive:
    for _ in 0 ..< 50:
      let query = archive_common.ArchiveQuery(
        includeData: false, contentTopics: @[testTopic], pubsubTopic: some(shard)
      )
      let res = await storeNode.wakuArchive.findMessages(query)
      if res.isOk() and res.get().hashes.len > 0:
        break waitArchive
      await sleepAsync(100.milliseconds)
    raiseAssert "Message was not archived in time"

  # subscribe to the content topic; with no peers yet the subscriber stays offline
  (await subscriber.messagingClient.subscribe(testTopic)).expect("Failed to subscribe")

  return TestNetwork(
    storeNode: storeNode,
    publisher: publisher,
    subscriber: subscriber,
    storeNodePeerInfo: storeNodePeerInfo,
    missedPayload: missedPayload,
  )

proc teardown(net: TestNetwork) {.async.} =
  if not isNil(net.subscriber):
    (await net.subscriber.stop()).expect("Failed to stop subscriber")
    net.subscriber = nil
  if not isNil(net.publisher):
    await net.publisher.stop()
    net.publisher = nil
  if not isNil(net.storeNode):
    await net.storeNode.stop()
    net.storeNode = nil

suite "Messaging API, Receive Service (store recovery)":
  asyncTest "recv_service delivers store-recovered messages via MessageReceivedEvent":
    ## Regression: a message archived before the subscriber connects is recovered
    ## by an explicit checkStore() and delivered via MessageReceivedEvent.
    let net = await setupNetwork(ContentTopic("/waku/2/recv-test/proto"))
    defer:
      await net.teardown()

    let eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
    defer:
      await eventManager.teardown()

    await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
    await net.subscriber.messagingClient.recvService.checkStore()

    check await eventManager.waitForEvents(TestTimeout)
    check eventManager.receivedMessages.len == 1
    if eventManager.receivedMessages.len > 0:
      check eventManager.receivedMessages[0].payload == net.missedPayload

  asyncTest "recv_service backfills missed messages when it comes back online":
    ## Connecting a peer brings the subscriber online, firing the backfill that
    ## recovers a message archived while it was offline.
    let net = await setupNetwork(ContentTopic("/waku/2/recv-reconnect-test/proto"))
    defer:
      await net.teardown()

    let eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
    defer:
      await eventManager.teardown()

    # sync on coming online (the transition that fires the backfill) before asserting
    let onlineFut = waitForConnectionStatus(
      net.subscriber.waku.brokerCtx, ConnectionStatus.PartiallyConnected
    )
    await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
    await onlineFut

    check await eventManager.waitForEvents(TestTimeout)
    check eventManager.receivedMessages.len == 1
    if eventManager.receivedMessages.len > 0:
      check eventManager.receivedMessages[0].payload == net.missedPayload

{.used.}

import std/[options, sequtils, net, sets]
import chronos, testutils/unittests, stew/byteutils
import libp2p/[peerid, peerinfo, crypto/crypto]
import ../testlib/[common, wakucore, wakunode, testasync]
import ../waku_archive/archive_utils

import
  waku,
  waku/[
    waku_node,
    waku_core,
    common/broker/broker_context,
    events/message_events,
    waku_relay/protocol,
    waku_archive,
    waku_archive/common as archive_common,
    node/delivery_service/delivery_service,
    node/delivery_service/recv_service,
  ]
import waku/factory/waku_conf
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

proc teardown(manager: ReceiveEventListenerManager) =
  MessageReceivedEvent.dropListener(manager.brokerCtx, manager.receivedListener)

proc waitForEvents(
    manager: ReceiveEventListenerManager, timeout: Duration
): Future[bool] {.async.} =
  return await manager.receivedEvent.wait().withTimeout(timeout)

proc createApiNodeConf(numShards: uint16 = 1): WakuNodeConf =
  var conf = defaultWakuNodeConf().valueOr:
    raiseAssert error
  conf.mode = cli_args.WakuMode.Core
  conf.listenAddress = parseIpAddress("0.0.0.0")
  conf.tcpPort = Port(0)
  conf.discv5UdpPort = Port(0)
  conf.clusterId = 3'u16
  conf.numShardsInNetwork = numShards
  conf.reliabilityEnabled = true
  conf.rest = false
  result = conf

suite "Messaging API, Receive Service (store recovery)":
  asyncTest "recv_service delivers store-recovered messages via MessageReceivedEvent":
    ## Message gets archived before subscriber exists, checkStore() recovers it.
    ## This is a regression test: it proves that messages recovered via store by
    ## the RecvService (instead of receiving via a live relay sub) are actually
    ## delivered via the MessageReceivedEvent API.

    let numShards: uint16 = 1
    let shards = @[PubsubTopic("/waku/2/rs/3/0")]
    let shard = shards[0]
    let testTopic = ContentTopic("/waku/2/recv-test/proto")

    proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      discard

    # store node has archive, store, relay
    # it archives messages from relay and serves them to the
    # subscriber's store client when it comes up (later)
    var storeNode: WakuNode
    lockNewGlobalBrokerContext:
      storeNode =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      storeNode.mountMetadata(3, toSeq(0'u16 ..< numShards)).expect(
        "Failed to mount metadata on storeNode"
      )
      (await storeNode.mountRelay()).expect("Failed to mount relay on storeNode")
      let archiveDriver = newSqliteArchiveDriver()
      storeNode.mountArchive(archiveDriver).expect("Failed to mount archive")
      await storeNode.mountStore()
      await storeNode.mountLibp2pPing()
      await storeNode.start()

    for s in shards:
      storeNode.subscribe((kind: PubsubSub, topic: s), dummyHandler).expect(
        "Failed to sub storeNode"
      )

    let storeNodePeerInfo = storeNode.peerInfo.toRemotePeerInfo()

    # publisher node (relay)
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

    for s in shards:
      publisher.subscribe((kind: PubsubSub, topic: s), dummyHandler).expect(
        "Failed to sub publisher"
      )

    # connect publisher to store so messages get archived
    await publisher.connectToNodes(@[storeNodePeerInfo])

    # wait for relay mesh
    for _ in 0 ..< 50:
      if publisher.wakuRelay.getNumPeersInMesh(shard).valueOr(0) > 0:
        break
      await sleepAsync(100.milliseconds)

    # publish before subscriber exists, gets archived
    let missedPayload = "This message was missed".toBytes()
    let missedMsg = WakuMessage(
      payload: missedPayload, contentTopic: testTopic, version: 0, timestamp: now()
    )
    discard (await publisher.publish(some(shard), missedMsg)).expect(
      "Publish missed msg failed"
    )

    # wait for archive
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

    # create subscriber
    var subscriber: Waku
    lockNewGlobalBrokerContext:
      subscriber = (await createNode(createApiNodeConf(numShards))).expect(
        "Failed to create subscriber"
      )
      (await startWaku(addr subscriber)).expect("Failed to start subscriber")

    # connect subscriber to store (not publisher, so msg won't come via relay to it)
    await subscriber.node.connectToNodes(@[storeNodePeerInfo])

    # subscribe to content topic
    (await subscriber.subscribe(testTopic)).expect("Failed to subscribe")

    # listen before triggering store check
    let eventManager = newReceiveEventListenerManager(subscriber.brokerCtx, 1)
    defer:
      eventManager.teardown()

    # trigger store check, should recover and deliver via MessageReceivedEvent
    await subscriber.deliveryService.recvService.checkStore()

    let received = await eventManager.waitForEvents(TestTimeout)
    check received
    check eventManager.receivedMessages.len == 1
    if eventManager.receivedMessages.len > 0:
      check eventManager.receivedMessages[0].payload == missedPayload

    # cleanup
    (await subscriber.stop()).expect("Failed to stop subscriber")
    await publisher.stop()
    await storeNode.stop()

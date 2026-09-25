{.used.}

import
  std/[options, net, sequtils, strutils],
  chronos,
  metrics,
  testutils/unittests,
  presto,
  presto/client as presto_client,
  libp2p/crypto/crypto
import brokers/broker_context
import logos_delivery
import
  logos_delivery/api/conf/logos_delivery_conf,
  logos_delivery/messaging/rest_api/client as messaging_rest_client,
  logos_delivery/messaging/rest_api/event_cache,
  logos_delivery/waku/rest_api/endpoint/client,
  logos_delivery/waku/common/base64
import tools/confutils/cli_args
import ../testlib/[wakucore, testasync, wakunodeconf]

## Integration test for the messaging REST endpoints and their event cache.
##
## A full `LogosDelivery` node is started with REST enabled (so `start` mounts
## the messaging handlers + event listeners), then driven through the generated
## `client.nim` stubs. Event observability is exercised deterministically by
## emitting the MessagingClient events directly on the node's broker context —
## the same context the send/recv services emit on — so we do not depend on real
## network delivery.

proc restNodeConf(): WakuNodeConf =
  defaultTestWakuNodeConf(entryLayer = EntryLayer.messaging, rest = true)

proc restClientFor(node: LogosDelivery): RestClientRef =
  let boundPort = node.waku.restServer.httpServer.address.port
  newRestHttpClient(initTAddress(parseIpAddress("127.0.0.1"), boundPort))

const settleDelay = 200.milliseconds
  ## Event emit + listener run are asyncSpawned; give them a turn before polling.

suite "Messaging REST API":
  asyncTest "subscribe / unsubscribe / send endpoints respond":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(restNodeConf())).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "Failed to start node: " & error
    let client = restClientFor(node)

    let contentTopic = "/test/1/messaging-rest/proto"

    let subResp = await client.messagingPostSubscriptionsV1(@[contentTopic])
    check subResp.status == 200

    # A malformed content topic or a generation other than 0 answers 400.
    let badSubResp = await client.messagingPostSubscriptionsV1(@["not-a-content-topic"])
    check badSubResp.status == 400
    let badUnsubResp =
      await client.messagingDeleteSubscriptionsV1(@["not-a-content-topic"])
    check badUnsubResp.status == 400
    let badGenResp = await client.messagingPostSubscriptionsV1(@["/1/test/1/gen/proto"])
    check badGenResp.status == 400
    let badSendResp = await client.messagingPostMessagesRawV1(
      MessagingJsonEnvelope(
        payload: base64.encode("x"),
        contentTopic: "not-a-content-topic",
        ephemeral: Opt.none(bool),
        meta: Opt.none(Base64String),
      )
    )
    check badSendResp.status == 400

    let msg = MessagingJsonEnvelope(
      payload: base64.encode("hello rest"),
      contentTopic: contentTopic,
      ephemeral: Opt.none(bool),
      meta: Opt.none(Base64String),
    )
    let sendResp = await client.messagingPostMessagesV1(msg)
    check:
      sendResp.status == 200
      sendResp.data.requestId.len > 0

    let unsubResp = await client.messagingDeleteSubscriptionsV1(@[contentTopic])
    check unsubResp.status == 200

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "send events are grouped by requestId and evict after poll":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(restNodeConf())).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "Failed to start node: " & error
    let client = restClientFor(node)
    let brokerCtx = node.waku.brokerCtx

    let reqA = RequestId("req-A")
    let reqB = RequestId("req-B")

    # reqA sees the full lifecycle; reqB only an error.
    MessagePropagatedEvent.emit(
      brokerCtx, MessagePropagatedEvent(requestId: reqA, messageHash: "0xaa")
    )
    MessageSentEvent.emit(
      brokerCtx, MessageSentEvent(requestId: reqA, messageHash: "0xaa")
    )
    MessageErrorEvent.emit(
      brokerCtx, MessageErrorEvent(requestId: reqB, messageHash: "0xbb", error: "boom")
    )
    await sleepAsync(settleDelay)

    # GET by id returns only reqA and removes it.
    let byIdResp = await client.messagingGetSendEventsByIdV1($reqA)
    check:
      byIdResp.status == 200
      byIdResp.data.requestId == $reqA
      byIdResp.data.events.len == 2
      byIdResp.data.events.anyIt(it.kind == SendEventKind.Sent)
      byIdResp.data.events.anyIt(it.kind == SendEventKind.Propagated)

    # Unknown / already-polled id → 404 (raw string client so the text error
    # body decodes; the typed client would raise on a non-2xx body).
    let missingResp = await client.messagingGetSendEventsByIdRawV1($reqA)
    check missingResp.status == 404

    # GET all now returns only reqB (with its error), then clears.
    let allResp = await client.messagingGetSendEventsV1()
    check:
      allResp.status == 200
      allResp.data.len == 1
      allResp.data[0].requestId == $reqB
      allResp.data[0].events.len == 1
      allResp.data[0].events[0].kind == SendEventKind.Error
      allResp.data[0].events[0].error == "boom"

    let emptyResp = await client.messagingGetSendEventsV1()
    check:
      emptyResp.status == 200
      emptyResp.data.len == 0

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "received messages are observable, capped, and evict after poll":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(restNodeConf())).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "Failed to start node: " & error
    let client = restClientFor(node)
    let brokerCtx = node.waku.brokerCtx

    # Emit more than the cache capacity (50); oldest must be dropped. Odd
    # messages come from Store, so the source travels with each record.
    const total = 55
    for i in 0 ..< total:
      let wm =
        fakeWakuMessage(payload = "msg-" & $i, contentTopic = "/test/1/recv/proto")
      let source = if i mod 2 == 0: MessageSource.Live else: MessageSource.History
      MessageReceivedEvent.emit(
        brokerCtx,
        MessageReceivedEvent(messageHash: "0x" & $i, message: wm, source: source),
      )
    await sleepAsync(settleDelay)

    let resp = await client.messagingGetReceivedMessagesV1()
    check:
      resp.status == 200
      resp.data.len == 50 # capped at DefaultMaxReceived
      # oldest (0..4) evicted, newest retained, oldest-first ordering
      resp.data[0].messageHash == "0x5"
      resp.data[0].source == MessageSource.History
      resp.data[^1].messageHash == "0x" & $(total - 1)
      resp.data[^1].source == MessageSource.Live
      # 1..5 were evicted
      resp.data[0].seq == 6'u64
      resp.data[^1].seq == uint64(total)

    let emptyResp = await client.messagingGetReceivedMessagesV1()
    check:
      emptyResp.status == 200
      emptyResp.data.len == 0

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "without autosharding, subscribe, unsubscribe and send answer 503":
    ## Without a preset or a shard count, content topics resolve to no shard.
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
          defaultTestWakuNodeConf(
            entryLayer = EntryLayer.messaging, rest = true, numShards = 0
          )
        )
      ).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "Failed to start node: " & error
    let client = restClientFor(node)

    let contentTopic = "/test/1/no-autosharding/proto"
    let subResp = await client.messagingPostSubscriptionsV1(@[contentTopic])
    let unsubResp = await client.messagingDeleteSubscriptionsV1(@[contentTopic])
    let sendResp = await client.messagingPostMessagesRawV1(
      MessagingJsonEnvelope(
        payload: base64.encode("hello"),
        contentTopic: contentTopic,
        ephemeral: Opt.none(bool),
        meta: Opt.none(Base64String),
      )
    )
    check:
      subResp.status == 503
      subResp.data.contains("--num-shards-in-network")
      unsubResp.status == 503
      sendResp.status == 503
      sendResp.data.contains("--num-shards-in-network")

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  test "a send status eviction is reported by the next poll only":
    let cache = MessagingEventCache.new(maxSendRequests = 2)
    for i in 0 ..< 3:
      cache.recordSend("req-" & $i, "0x" & $i, SendEventKind.Propagated)
    let (statuses, dropped) = cache.pollAllSend()
    check:
      statuses.len == 2
      dropped == 1
      cache.pollAllSend().dropped == 0

  asyncTest "received cache capacity follows --rest-messaging-cache-capacity":
    var conf = restNodeConf()
    conf.restMessagingCacheCapacity = 5
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "Failed to start node: " & error
    let client = restClientFor(node)
    let brokerCtx = node.waku.brokerCtx

    const total = 8
    let droppedBefore = logos_delivery_rest_received_dropped.value()
    for i in 0 ..< total:
      let wm =
        fakeWakuMessage(payload = "msg-" & $i, contentTopic = "/test/1/recv/proto")
      MessageReceivedEvent.emit(
        brokerCtx,
        MessageReceivedEvent(
          messageHash: "0x" & $i, message: wm, source: MessageSource.Live
        ),
      )

    let resp = await client.messagingGetReceivedMessagesV1()
    check:
      resp.status == 200
      resp.data.len == 5 # the configured capacity
      resp.data[0].messageHash == "0x3" # 0..2 evicted
      resp.data[^1].messageHash == "0x" & $(total - 1)
      resp.data[0].seq == 4'u64
      logos_delivery_rest_received_dropped.value() == droppedBefore + 3

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

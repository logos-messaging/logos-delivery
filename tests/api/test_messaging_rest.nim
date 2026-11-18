{.used.}

import
  std/[net, sequtils, strutils],
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
  rest/messaging_api/client as messaging_rest_client,
  rest/messaging_api/event_cache,
  rest/messaging_api/handlers {.all.},
  rest/client,
  logos_delivery/messaging/delivery_service/send_service/send_service,
  logos_delivery/waku/common/base64
import tools/confutils/cli_args
import tests/testlib/[wakucore, wakunodeconf, rest_requests, rest_service]

## Integration test for the messaging REST endpoints and their event cache.
##
## A full `LogosDelivery` node is started with REST enabled (so `start` mounts
## the messaging handlers + event listeners), then driven through the generated
## `client.nim` stubs. Event observability is exercised deterministically by
## emitting the MessagingClient events directly on the node's broker context —
## the same context the send/recv services emit on — so we do not depend on real
## network delivery.

proc restNodeConf(): LogosDeliveryNodeConf =
  defaultTestNodeConf(entryLayer = EntryLayer.messaging, rest = true)

proc restClientFor(rest: RestService): RestClientRef =
  let boundPort = rest.server.httpServer.address.port
  newRestHttpClient(initTAddress(parseIpAddress("127.0.0.1"), boundPort))

const settleDelay = 200.milliseconds
  ## Event emit + listener run are asyncSpawned; give them a turn before polling.

suite "Messaging REST API":
  asyncTest "subscribe / unsubscribe / send endpoints respond":
    var node: LogosDelivery
    var rest: RestService
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(restNodeConf())).valueOr:
        raiseAssert error
      rest = (await node.startWithRest()).valueOr:
        raiseAssert "Failed to start node: " & error
    let client = restClientFor(rest)

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
      sendResp.data.messageHash.len > 0

    let unsubResp = await client.messagingDeleteSubscriptionsV1(@[contentTopic])
    check unsubResp.status == 200

    await rest.stop(node)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "GET subscriptions lists the subscribed content topics, sorted":
    var node: LogosDelivery
    var rest: RestService
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(restNodeConf())).valueOr:
        raiseAssert error
      rest = (await node.startWithRest()).valueOr:
        raiseAssert "Failed to start node: " & error
    let client = restClientFor(rest)

    let topicA = "/test/1/list-a/proto"
    let topicB = "/test/1/list-b/proto"
    check (await client.messagingPostSubscriptionsV1(@[topicB, topicA])).status == 200
    let listResp = await client.messagingGetSubscriptionsV1()
    check:
      listResp.status == 200
      listResp.data == @[topicA, topicB]

    check (await client.messagingDeleteSubscriptionsV1(@[topicA])).status == 200
    let afterResp = await client.messagingGetSubscriptionsV1()
    check:
      afterResp.status == 200
      afterResp.data == @[topicB]

    await rest.stop(node)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "send events are grouped by message hash and evict after poll":
    var node: LogosDelivery
    var rest: RestService
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(restNodeConf())).valueOr:
        raiseAssert error
      rest = (await node.startWithRest()).valueOr:
        raiseAssert "Failed to start node: " & error
    let client = restClientFor(rest)
    let brokerCtx = node.waku.brokerCtx

    let hashA = fakeMessageHash("a").to0xHex()
    let hashB = fakeMessageHash("b").to0xHex()

    # hashA sees the full lifecycle; hashB only an error.
    MessagePropagatedEvent.emit(brokerCtx, MessagePropagatedEvent(messageHash: hashA))
    MessageSentEvent.emit(brokerCtx, MessageSentEvent(messageHash: hashA))
    MessageErrorEvent.emit(
      brokerCtx, MessageErrorEvent(messageHash: hashB, error: "boom")
    )
    await sleepAsync(settleDelay)

    # A text that is not a hash of 32 bytes gets 400, so a client does not poll it.
    for malformed in ["0xaa", "not-a-hash"]:
      let malformedResp = await client.messagingGetSendEventsByHashRawV1(malformed)
      check malformedResp.status == 400

    # GET by hash returns only hashA and removes it. The lookup takes the hash
    # in upper case and without `0x`.
    let byHashResp =
      await client.messagingGetSendEventsByHashV1(hashA[2 ..^ 1].toUpperAscii())
    check:
      byHashResp.status == 200
      byHashResp.data.messageHash == hashA
      byHashResp.data.events.len == 2
      byHashResp.data.events.anyIt(it.kind == SendEventKind.Sent)
      byHashResp.data.events.anyIt(it.kind == SendEventKind.Propagated)

    # Unknown / already-polled hash → 404 (raw string client so the text error
    # body decodes; the typed client would raise on a non-2xx body).
    let missingResp = await client.messagingGetSendEventsByHashRawV1(hashA)
    check missingResp.status == 404

    # GET all now returns only hashB (with its error), then clears.
    let allResp = await client.messagingGetSendEventsV1()
    check:
      allResp.status == 200
      allResp.data.len == 1
      allResp.data[0].messageHash == hashB
      allResp.data[0].events.len == 1
      allResp.data[0].events[0].kind == SendEventKind.Error
      allResp.data[0].events[0].error == "boom"

    let emptyResp = await client.messagingGetSendEventsV1()
    check:
      emptyResp.status == 200
      emptyResp.data.len == 0

    await rest.stop(node)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "a send answers 429 with Retry-After when the node has MaxSendsInFlight sends":
    var node: LogosDelivery
    var rest: RestService
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(restNodeConf())).valueOr:
        raiseAssert error
      rest = (await node.startWithRest()).valueOr:
        raiseAssert "Failed to start node: " & error
    let client = restClientFor(rest)

    # The node has no peer, so each send stays with no last event.
    let contentTopic = "/test/1/messaging-rest-queue-full/proto"
    for i in 0 ..< MaxSendsInFlight:
      let resp = await client.messagingPostMessagesV1(
        MessagingJsonEnvelope(
          payload: base64.encode("send-" & $i),
          contentTopic: contentTopic,
          ephemeral: Opt.none(bool),
          meta: Opt.none(Base64String),
        )
      )
      check resp.status == 200

    # A raw request, because the typed stub does not return the response headers.
    let fullResp = await issueRequest(
      rest.server.getAddress("/messaging/v1/messages"),
      meth = MethodPost,
      headers = @[("Content-Type", "application/json")],
      body =
        "{\"payload\":\"" & $base64.encode("one-more") & "\",\"contentTopic\":\"" &
        contentTopic & "\"}",
    )
    check:
      fullResp.status == 429
      fullResp.headers.getString("Retry-After") == "1"
      fullResp.data.endsWith(" (QueueFull)")

    await rest.stop(node)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "a send over the rate-limit budget answers 429 with the time to the refill":
    let conf = LogosDeliveryConf.init(
      KernelConf(restNodeConf().kernel),
      MessagingClientConf(
        rateLimitEnabled: Opt.some(true),
        rateLimitEpochPeriodSec: Opt.some(600'u64),
        rateLimitMessagesPerEpoch: Opt.some(1'u64),
      ),
      Opt.none(ReliableChannelManagerConf),
    ).valueOr:
      raiseAssert error
    var node: LogosDelivery
    var rest: RestService
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      rest = (await node.startWithRest()).valueOr:
        raiseAssert "Failed to start node: " & error
    let client = restClientFor(rest)

    let contentTopic = "/test/1/messaging-rest-rate-limit/proto"
    let firstResp = await client.messagingPostMessagesV1(
      MessagingJsonEnvelope(
        payload: base64.encode("first"),
        contentTopic: contentTopic,
        ephemeral: Opt.none(bool),
        meta: Opt.none(Base64String),
      )
    )
    check firstResp.status == 200

    # A raw request, because the typed stub does not return the response headers.
    let limitedResp = await issueRequest(
      rest.server.getAddress("/messaging/v1/messages"),
      meth = MethodPost,
      headers = @[("Content-Type", "application/json")],
      body =
        "{\"payload\":\"" & $base64.encode("second") & "\",\"contentTopic\":\"" &
        contentTopic & "\"}",
    )
    check:
      limitedResp.status == 429
      limitedResp.data.endsWith(" (RateLimited)")
    let retryAfter = limitedResp.headers.getString("Retry-After").parseInt()
    check retryAfter in 1 .. 600

    await rest.stop(node)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "a send whose body does not decode answers 400 with the decode reason":
    var node: LogosDelivery
    var rest: RestService
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(restNodeConf())).valueOr:
        raiseAssert error
      rest = (await node.startWithRest()).valueOr:
        raiseAssert "Failed to start node: " & error
    defer:
      await rest.stop(node)
      (await node.stop()).expect("Failed to stop node")

    let resp = await issueRequest(
      rest.server.getAddress("/messaging/v1/messages"),
      meth = MethodPost,
      headers = @[("Content-Type", "application/json")],
      body = "{}",
    )
    check:
      resp.status == 400
      resp.data.startsWith(
        "Invalid content body, could not decode: Unable to deserialize data: body("
      )
      resp.data.contains("Field `payload` is missing or empty")

  asyncTest "a send whose meta exceeds the limit is accepted with a message hash":
    var node: LogosDelivery
    var rest: RestService
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(restNodeConf())).valueOr:
        raiseAssert error
      rest = (await node.startWithRest()).valueOr:
        raiseAssert "Failed to start node: " & error
    defer:
      await rest.stop(node)
      (await node.stop()).expect("Failed to stop node")

    let resp = await issueRequest(
      rest.server.getAddress("/messaging/v1/messages"),
      meth = MethodPost,
      headers = @[("Content-Type", "application/json")],
      body =
        "{\"payload\":\"" & $base64.encode("hello rest") & "\",\"contentTopic\":\"" &
        "/test/1/messaging-rest-meta/proto\",\"meta\":\"" &
        $base64.encode(newSeq[byte](MaxMetaAttrLength + 1)) & "\"}",
    )
    check:
      resp.status == 200
      resp.data.startsWith("{\"messageHash\":\"0x")

  test "a refused send answers the HTTP status of its kind":
    check:
      sendRefused(SendError.init(SendErrorKind.QueueFull, "full")).status == Http429
      sendRefused(SendError.init(SendErrorKind.Duplicate, "queued")).status == Http409
      sendRefused(SendError.init(SendErrorKind.Other, "fault")).status == Http500
    # A rate-limited send tells the client when to send again, in whole seconds.
    let limited = sendRefused(
      SendError.init(SendErrorKind.RateLimited, "spent", chronos.milliseconds(1500))
    )
    check:
      limited.status == Http429
      limited.headers.getString("Retry-After") == "2"

  test "an evicted send status counts in logos_delivery_rest_send_dropped":
    let cache = MessagingEventCache.new(maxSendRequests = 2)
    let before = logos_delivery_rest_send_dropped.value()
    for hash in ["0xa", "0xb", "0xc"]:
      cache.recordSend(hash, SendEventKind.Propagated)
    check:
      logos_delivery_rest_send_dropped.value() == before + 1
      cache.pollAllSend().mapIt(it.messageHash) == @["0xb", "0xc"]

  asyncTest "received messages are observable, capped, and evict after poll":
    var node: LogosDelivery
    var rest: RestService
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(restNodeConf())).valueOr:
        raiseAssert error
      rest = (await node.startWithRest()).valueOr:
        raiseAssert "Failed to start node: " & error
    let client = restClientFor(rest)
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

    await rest.stop(node)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "without autosharding, subscribe, unsubscribe and send answer 503":
    ## Without a preset or a shard count, content topics resolve to no shard.
    var node: LogosDelivery
    var rest: RestService
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
          defaultTestNodeConf(
            entryLayer = EntryLayer.messaging, rest = true, numShards = 0
          )
        )
      ).valueOr:
        raiseAssert error
      rest = (await node.startWithRest()).valueOr:
        raiseAssert "Failed to start node: " & error
    let client = restClientFor(rest)

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

    await rest.stop(node)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "received cache capacity follows --rest-messaging-cache-capacity":
    var conf = restNodeConf()
    conf.kernel.restMessagingCacheCapacity = 5
    var node: LogosDelivery
    var rest: RestService
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      rest = (await node.startWithRest()).valueOr:
        raiseAssert "Failed to start node: " & error
    let client = restClientFor(rest)
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

    await rest.stop(node)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  test "clear drops the buffered send statuses and received messages":
    let cache = MessagingEventCache.new()
    cache.recordSend("0x1", SendEventKind.Sent)
    cache.recordReceived(
      "0x2",
      toRelayWakuMessage(fakeWakuMessage(contentTopic = "/test/1/recv/proto")),
      MessageSource.Live,
    )

    cache.clear()

    check:
      cache.pollAllSend().len == 0
      cache.pollReceived().len == 0

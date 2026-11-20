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
import logos_delivery/waku/[waku_node, waku_core, node/peer_manager]
import
  logos_delivery/api/conf/logos_delivery_conf,
  rest/messaging_api/client as messaging_rest_client,
  rest/messaging_api/event_cache,
  rest/client,
  logos_delivery/waku/common/base64
import tools/confutils/cli_args
import tests/testlib/[wakucore, wakunode, wakunodeconf, rest_requests, rest_service]

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

const
  HashA = "0x" & repeat('a', 64)
  HashB = "0x" & repeat('b', 64)
  HashC = "0x" & repeat('c', 64)

proc startBystander(): Future[WakuNode] {.async.} =
  ## A started peer with no relay, lightpush, filter or store, so it cannot carry
  ## a message. A node connected only to it is not refused as NotConnected.
  var bystander: WakuNode
  lockNewGlobalBrokerContext:
    bystander = newTestWakuNode(generateSecp256k1Key())
    bystander.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
      raiseAssert "Failed to mount metadata: " & error
    await bystander.start()
  return bystander

proc startConnectedWithRest(
    conf: LogosDeliveryNodeConf | LogosDeliveryConf
): Future[(LogosDelivery, RestService, WakuNode)] {.async.} =
  ## A node with REST connected only to a bystander, and that bystander, so that a
  ## send is accepted and stays in the send queue.
  var node: LogosDelivery
  var rest: RestService
  lockNewGlobalBrokerContext:
    node = (await LogosDelivery.new(conf)).valueOr:
      raiseAssert error
    rest = (await node.startWithRest()).valueOr:
      raiseAssert "Failed to start node: " & error
  let bystander = await startBystander()
  await node.waku.node.connectToNodes(@[bystander.peerInfo.toRemotePeerInfo()])
  for _ in 0 ..< 100:
    let (inPeers, outPeers) = node.waku.node.peerManager.connectedPeers()
    if inPeers.len + outPeers.len > 0:
      return (node, rest, bystander)
    await sleepAsync(100.milliseconds)
  raiseAssert "the bystander never connected"

proc postMessage(
    rest: RestService, payload: string, contentTopic: string
): Future[TestResponseTuple] {.async.} =
  ## A raw send, because the typed stub does not return the response headers.
  return await issueRequest(
    rest.server.getAddress("/messaging/v1/messages"),
    meth = MethodPost,
    headers = @[("Content-Type", "application/json")],
    body =
      "{\"payload\":\"" & $base64.encode(payload) & "\",\"contentTopic\":\"" &
      contentTopic & "\"}",
  )

suite "Messaging REST API":
  asyncTest "subscribe / unsubscribe / send endpoints respond":
    let (node, rest, bystander) = await startConnectedWithRest(restNodeConf())
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
      sendResp.data.messageHash.len == 66
      sendResp.data.messageHash.startsWith("0x")

    let unsubResp = await client.messagingDeleteSubscriptionsV1(@[contentTopic])
    check unsubResp.status == 200

    await rest.stop(node)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error
    await bystander.stop()

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

  asyncTest "send events are grouped by messageHash and evict after poll":
    var node: LogosDelivery
    var rest: RestService
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(restNodeConf())).valueOr:
        raiseAssert error
      rest = (await node.startWithRest()).valueOr:
        raiseAssert "Failed to start node: " & error
    let client = restClientFor(rest)
    let brokerCtx = node.waku.brokerCtx

    # HashA sees the full lifecycle; HashB only an error.
    MessagePropagatedEvent.emit(brokerCtx, MessagePropagatedEvent(messageHash: HashA))
    MessageSentEvent.emit(brokerCtx, MessageSentEvent(messageHash: HashA))
    MessageErrorEvent.emit(
      brokerCtx,
      MessageErrorEvent(
        messageHash: HashB, kind: MessageErrorKind.NotStored, error: "boom"
      ),
    )
    MessagePropagatedEvent.emit(brokerCtx, MessagePropagatedEvent(messageHash: HashC))
    await sleepAsync(settleDelay)

    # GET by hash returns only HashA and removes it; the hash matches in any case.
    let byHashResp = await client.messagingGetSendEventsByHashV1("0x" & repeat('A', 64))
    check:
      byHashResp.status == 200
      byHashResp.data.messageHash == HashA
      byHashResp.data.events.len == 2
      byHashResp.data.events.anyIt(it.kind == SendEventKind.Sent)
      byHashResp.data.events.anyIt(it.kind == SendEventKind.Propagated)
      byHashResp.data.events.allIt(it.errorKind == "")

    # Unknown / already-polled hash → 404 (raw string client so the text error
    # body decodes; the typed client would raise on a non-2xx body).
    let missingResp = await client.messagingGetSendEventsByHashRawV1(HashA)
    check missingResp.status == 404

    # A text that is not a hex hash of 32 bytes → 400.
    for badHash in ["0x1234", "0x" & repeat('z', 64), repeat('a', 66)]:
      let badResp = await client.messagingGetSendEventsByHashRawV1(badHash)
      check:
        badResp.status == 400
        badResp.data.startsWith("messageHash is not a hex hash of 32 bytes: ")

    # A hash with no `0x` is a hash too, so it gets the events of `HashC`.
    let noPrefixResp = await client.messagingGetSendEventsByHashV1(HashC[2 ..^ 1])
    check:
      noPrefixResp.status == 200
      noPrefixResp.data.messageHash == HashC

    # GET all now returns only HashB (with its error), then clears.
    let allResp = await client.messagingGetSendEventsV1()
    check:
      allResp.status == 200
      allResp.data.len == 1
      allResp.data[0].messageHash == HashB
      allResp.data[0].events.len == 1
      allResp.data[0].events[0].kind == SendEventKind.Error
      allResp.data[0].events[0].errorKind == "NotStored"
      allResp.data[0].events[0].error == "boom"

    let emptyResp = await client.messagingGetSendEventsV1()
    check:
      emptyResp.status == 200
      emptyResp.data.len == 0

    await rest.stop(node)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "a send answers 429 with Retry-After when the node has its maximum of sends in flight":
    let conf = LogosDeliveryConf.init(
      KernelConf(restNodeConf().kernel),
      MessagingClientConf(),
      Opt.none(ReliableChannelManagerConf),
    ).valueOr:
      raiseAssert error
    let (node, rest, bystander) = await startConnectedWithRest(conf)
    defer:
      await rest.stop(node)
      (await node.stop()).expect("Failed to stop node")
      await bystander.stop()
    node.messagingClient.sendService.maxSendsInFlight = 1

    # The node has no peer that can carry it, so the first send stays in the queue.
    let contentTopic = "/test/1/messaging-rest-queue-full/proto"
    let firstResp = await rest.postMessage("first", contentTopic)
    check firstResp.status == 200

    let fullResp = await rest.postMessage("second", contentTopic)
    check:
      fullResp.status == 429
      fullResp.headers.getString("Retry-After") == "1"
      fullResp.data ==
        "Send refused: failed to enqueue the message: send queue full, retry later (QueueFull)"

  asyncTest "a send with no rate-limit budget answers 429 with Retry-After to the next epoch":
    const epochSec = 600'u64
    let conf = LogosDeliveryConf.init(
      KernelConf(restNodeConf().kernel),
      MessagingClientConf(
        rateLimitEnabled: Opt.some(true),
        rateLimitEpochPeriodSec: Opt.some(epochSec),
        rateLimitMessagesPerEpoch: Opt.some(0'u64),
      ),
      Opt.none(ReliableChannelManagerConf),
    ).valueOr:
      raiseAssert error
    let (node, rest, bystander) = await startConnectedWithRest(conf)
    defer:
      await rest.stop(node)
      (await node.stop()).expect("Failed to stop node")
      await bystander.stop()

    let resp = await rest.postMessage("over budget", "/test/1/messaging-rest-rln/proto")
    let retryAfter =
      try:
        parseInt(resp.headers.getString("Retry-After"))
      except ValueError:
        -1
    check:
      resp.status == 429
      retryAfter in 1 .. int(epochSec)
      resp.data.startsWith("Send refused: ")
      # The body gives the same seconds as the header.
      resp.data.endsWith(", retry after: " & $retryAfter & " s (RateLimited)")

  asyncTest "a send over the maximum message size answers 413":
    var conf = restNodeConf()
    conf.kernel.maxMessageSize = "1KiB"
    let (node, rest, bystander) = await startConnectedWithRest(conf)
    defer:
      await rest.stop(node)
      (await node.stop()).expect("Failed to stop node")
      await bystander.stop()

    let resp =
      await rest.postMessage(repeat('x', 2048), "/test/1/messaging-rest-big/proto")
    check:
      resp.status == 413
      resp.data.startsWith(
        "Send refused: failed to enqueue the message: message exceeds the maximum message size: "
      )
      resp.data.endsWith("(TooLarge)")

  asyncTest "a send on a node with no connection answers 503":
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

    let resp =
      await rest.postMessage("isolated", "/test/1/messaging-rest-isolated/proto")
    check:
      resp.status == 503
      resp.data == "Send refused: node has no connected peer (NotConnected)"

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

  asyncTest "a send whose meta exceeds the limit is accepted with a messageHash":
    let (node, rest, bystander) = await startConnectedWithRest(restNodeConf())
    defer:
      await rest.stop(node)
      (await node.stop()).expect("Failed to stop node")
      await bystander.stop()

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

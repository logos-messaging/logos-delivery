{.used.}

import std/[net]
import chronos, testutils/unittests, stew/byteutils
import brokers/broker_context

import ../testlib/[common, wakucore, wakunode, testasync]

import waku
import waku/[waku_node, waku_core]
import waku/factory/waku_conf
import waku/events/message_events as waku_message_events
import tools/confutils/cli_args

import channels/reliable_channel_manager
import channels/encryption/noop_encryption

const TestTimeout = chronos.seconds(15)

proc createApiNodeConf(): WakuNodeConf =
  var conf = defaultWakuNodeConf().valueOr:
    raiseAssert error
  conf.mode = cli_args.WakuMode.Core
  conf.listenAddress = parseIpAddress("0.0.0.0")
  conf.tcpPort = Port(0)
  conf.discv5UdpPort = Port(0)
  conf.clusterId = 3'u16
  conf.numShardsInNetwork = 1
  conf.reliabilityEnabled = true
  conf.rest = false
  return conf

suite "Reliable Channel - ingress":
  asyncTest "manager dispatches marked WakuMessage to the right channel":
    ## Unit test for the receive side of the API: instead of standing
    ## up two libp2p nodes and a relay mesh, we drive the manager
    ## directly by emitting a `MessageReceivedEvent` (the exact event
    ## the DeliveryService emits when a `WakuMessage` arrives off the
    ## wire). The manager must:
    ##   - drop traffic missing the Reliable Channel spec marker
    ##   - dispatch the matching channel's `onMessageReceived`
    ##   - emit `ChannelMessageReceivedEvent` with the payload
    const
      channelId = ChannelId("test-channel")
      contentTopic = ContentTopic("/reliable-channel/test/proto")
    let appPayload = "hello reliable channel".toBytes()

    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      manager = (await ReliableChannelManager.new(createApiNodeConf())).expect(
        "Failed to create manager"
      )

    ## Noop encryption providers so the Encrypt/Decrypt brokers have
    ## something to dispatch to; without this the channel falls back to
    ## plaintext anyway, but installing them is the documented setup.
    setNoopEncryption()

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    let received = newFuture[seq[byte]]("channel-message-received")
    discard ChannelMessageReceivedEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageReceivedEvent) {.async: (raises: []).} =
          if not received.finished() and evt.channelId == channelId:
            received.complete(evt.payload)
        ,
      )
      .expect("listen ChannelMessageReceivedEvent")

    ## Build a `WakuMessage` that looks like one that came in off the
    ## wire from a peer: the spec marker on `meta` plus the right content
    ## topic. The manager's ingress listener should pick it up,
    ## decrypt (noop), unwrap SDS (pass-through), reassemble (one
    ## segment), and finally emit `ChannelMessageReceivedEvent`.
    let inboundMsg = WakuMessage(
      payload: appPayload,
      contentTopic: contentTopic,
      version: 0,
      meta: LipWireReliableChannelVersion.toBytes(),
    )

    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(messageHash: "", message: inboundMsg),
    )

    let arrived = await received.withTimeout(TestTimeout)
    check arrived
    if arrived:
      check received.read() == appPayload

    await manager.stop()

  asyncTest "manager drops unmarked WakuMessage":
    ## Mirror of the above: same content topic, but `meta` is empty
    ## (i.e. foreign traffic). The channel-level event must NOT fire.
    const
      channelId = ChannelId("test-channel-2")
      contentTopic = ContentTopic("/reliable-channel/test/proto")
    let appPayload = "foreign payload".toBytes()

    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      manager = (await ReliableChannelManager.new(createApiNodeConf())).expect(
        "Failed to create manager"
      )

    setNoopEncryption()

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    var fired = false
    discard ChannelMessageReceivedEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageReceivedEvent) {.async: (raises: []).} =
          if evt.channelId == channelId:
            fired = true
        ,
      )
      .expect("listen ChannelMessageReceivedEvent")

    let inboundMsg = WakuMessage(
      payload: appPayload,
      contentTopic: contentTopic,
      version: 0,
      meta: @[], ## no Reliable Channel spec marker
    )

    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(messageHash: "", message: inboundMsg),
    )

    ## Give the event broker a chance to fan out.
    await sleepAsync(100.milliseconds)
    check not fired

    await manager.stop()

suite "Reliable Channel - send state machine":
  asyncTest "MessageSentEvent flips InFlight -> Confirmed and prunes":
    ## Drives the real send pipeline (`send` -> segmentation -> SDS ->
    ## rate_limit -> encrypt -> dispatch) via a fake `SendHandler` that
    ## returns canned `RequestId`s instead of hitting the network. Once
    ## the segment reaches `InFlight`, the delivery-layer
    ## `MessageSentEvent` is emitted and the entry must transition to
    ## `Confirmed` and be pruned (it's the only segment for that
    ## `channelReqId`).
    const
      channelId = ChannelId("sm-success-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sm-success")
      fakeMsgReqId = RequestId("fake-msg-req-1")

    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      manager = (await ReliableChannelManager.new(createApiNodeConf())).expect(
        "Failed to create manager"
      )

    setNoopEncryption()

    var sendCalls = 0
    let fakeSend: SendHandler = proc(
        env: MessageEnvelope
    ): Future[Result[RequestId, string]] {.
        async: (raises: [CatchableError]), gcsafe
    .} =
      sendCalls.inc
      return ok(fakeMsgReqId)

    discard manager
      .createReliableChannel(
        channelId, contentTopic, SdsParticipantID("local"), sendHandler = fakeSend
      )
      .expect("createReliableChannel")

    let chn = manager.getChannelForTest(channelId)
    doAssert not chn.isNil()
    check chn.pendingMessagingRequestsLenForTest == 0

    ## Small payload -> one segment -> exactly one `SendHandler` call.
    discard chn.send("hello".toBytes()).expect("send")

    let dispatchDeadline = Moment.now() + 1.seconds
    while Moment.now() < dispatchDeadline and sendCalls == 0:
      await sleepAsync(5.milliseconds)
    check sendCalls == 1
    check chn.pendingMessagingRequestsLenForTest == 1

    waku_message_events.MessageSentEvent.emit(
      brokerCtx,
      waku_message_events.MessageSentEvent(requestId: fakeMsgReqId, messageHash: ""),
    )

    let pruneDeadline = Moment.now() + 1.seconds
    while Moment.now() < pruneDeadline and chn.pendingMessagingRequestsLenForTest > 0:
      await sleepAsync(5.milliseconds)
    check chn.pendingMessagingRequestsLenForTest == 0

    await manager.stop()

  asyncTest "two independent channelReqIds are pruned independently":
    ## Two `send()` calls -> two independent `channelReqId`s, each with
    ## one segment under the current segmentation skeleton
    ## (`performSegmentation` always emits exactly one segment). The
    ## fake `SendHandler` returns distinct `messagingReqId`s; finalising
    ## the first must prune only its entry, leaving the second tracked,
    ## then finalising the second prunes the remainder.
    const
      channelId = ChannelId("sm-multi-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sm-multi")

    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      manager = (await ReliableChannelManager.new(createApiNodeConf())).expect(
        "Failed to create manager"
      )

    setNoopEncryption()

    var msgReqIds: seq[RequestId]
    let fakeSend: SendHandler = proc(
        env: MessageEnvelope
    ): Future[Result[RequestId, string]] {.
        async: (raises: [CatchableError]), gcsafe
    .} =
      let id = RequestId("fake-msg-req-" & $(msgReqIds.len + 1))
      msgReqIds.add(id)
      return ok(id)

    discard manager
      .createReliableChannel(
        channelId, contentTopic, SdsParticipantID("local"), sendHandler = fakeSend
      )
      .expect("createReliableChannel")

    let chn = manager.getChannelForTest(channelId)
    doAssert not chn.isNil()

    discard chn.send("first".toBytes()).expect("send 1")
    discard chn.send("second".toBytes()).expect("send 2")

    let dispatchDeadline = Moment.now() + 1.seconds
    while Moment.now() < dispatchDeadline and msgReqIds.len < 2:
      await sleepAsync(5.milliseconds)
    check msgReqIds.len == 2
    check chn.pendingMessagingRequestsLenForTest == 2

    waku_message_events.MessageSentEvent.emit(
      brokerCtx,
      waku_message_events.MessageSentEvent(requestId: msgReqIds[0], messageHash: ""),
    )
    let firstPruneDeadline = Moment.now() + 1.seconds
    while Moment.now() < firstPruneDeadline and chn.pendingMessagingRequestsLenForTest > 1:
      await sleepAsync(5.milliseconds)
    ## Only the first `channelReqId` is fully accounted for; the second
    ## one's segment is still `InFlight`, so exactly one entry remains.
    check chn.pendingMessagingRequestsLenForTest == 1

    waku_message_events.MessageErrorEvent.emit(
      brokerCtx,
      waku_message_events.MessageErrorEvent(
        requestId: msgReqIds[1], messageHash: "", error: "synthetic"
      ),
    )
    let pruneDeadline = Moment.now() + 1.seconds
    while Moment.now() < pruneDeadline and chn.pendingMessagingRequestsLenForTest > 0:
      await sleepAsync(5.milliseconds)
    check chn.pendingMessagingRequestsLenForTest == 0

    await manager.stop()

  asyncTest "TODO: channelReqId not pruned until ALL its segments are final":
    ## Placeholder for the multi-sibling prune rule. Today's
    ## `performSegmentation` (segmentation skeleton) always emits
    ## exactly one segment per `send()`, so multiple siblings under one
    ## `channelReqId` cannot be produced through the real pipeline.
    ## Implement once segmentation does real chunking: send a payload
    ## larger than `DefaultSegmentSizeBytes`, capture the N
    ## `messagingReqId`s from a fake `SendHandler`, finalise some, and
    ## assert prune only fires once every sibling is final.
    skip()

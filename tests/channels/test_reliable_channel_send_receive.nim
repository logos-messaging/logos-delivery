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
  asyncTest "MessageSentEvent finalises the channelReqId as Sent":
    ## Drives the real send pipeline (`send` -> segmentation -> SDS ->
    ## rate_limit -> encrypt -> dispatch) via a fake `SendHandler` that
    ## returns a canned `RequestId` instead of hitting the network.
    ## Emitting the delivery-layer `MessageSentEvent` must drive the
    ## channel-level state machine through `Confirmed` and produce a
    ## `ChannelMessageSentEvent` (channel-level terminal event) for the
    ## `channelReqId` returned by `send()`.
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
    ): Future[Result[RequestId, string]] {.async: (raises: [CatchableError]), gcsafe.} =
      sendCalls.inc
      return ok(fakeMsgReqId)

    discard manager
      .createReliableChannel(
        channelId, contentTopic, SdsParticipantID("local"), sendHandler = fakeSend
      )
      .expect("createReliableChannel")

    let sentFut = newFuture[RequestId]("channel-sent")
    discard ChannelMessageSentEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageSentEvent) {.async: (raises: []).} =
          if not sentFut.finished() and evt.channelId == channelId:
            sentFut.complete(evt.requestId)
        ,
      )
      .expect("listen ChannelMessageSentEvent")

    let channelReqId = manager.send(channelId, "hello".toBytes()).expect("send")

    let dispatchDeadline = Moment.now() + 1.seconds
    while Moment.now() < dispatchDeadline and sendCalls == 0:
      await sleepAsync(5.milliseconds)
    check sendCalls == 1

    waku_message_events.MessageSentEvent.emit(
      brokerCtx,
      waku_message_events.MessageSentEvent(requestId: fakeMsgReqId, messageHash: ""),
    )

    let finalised = await sentFut.withTimeout(1.seconds)
    check finalised
    if finalised:
      check sentFut.read() == channelReqId

    await manager.stop()

  asyncTest "two independent channelReqIds are finalised independently":
    ## Two `send()` calls -> two independent `channelReqId`s, each with
    ## one segment under the current segmentation skeleton
    ## (`performSegmentation` always emits exactly one segment). The
    ## fake `SendHandler` returns distinct `messagingReqId`s; finalising
    ## the first emits `ChannelMessageSentEvent` for its `channelReqId`,
    ## finalising the second as a failure emits `ChannelMessageErrorEvent`
    ## for the other.
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
    ): Future[Result[RequestId, string]] {.async: (raises: [CatchableError]), gcsafe.} =
      let id = RequestId("fake-msg-req-" & $(msgReqIds.len + 1))
      msgReqIds.add(id)
      return ok(id)

    discard manager
      .createReliableChannel(
        channelId, contentTopic, SdsParticipantID("local"), sendHandler = fakeSend
      )
      .expect("createReliableChannel")

    let sentFut = newFuture[RequestId]("channel-sent")
    let erroredFut = newFuture[RequestId]("channel-errored")
    discard ChannelMessageSentEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageSentEvent) {.async: (raises: []).} =
          if not sentFut.finished() and evt.channelId == channelId:
            sentFut.complete(evt.requestId)
        ,
      )
      .expect("listen ChannelMessageSentEvent")
    discard ChannelMessageErrorEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageErrorEvent) {.async: (raises: []).} =
          if not erroredFut.finished() and evt.channelId == channelId:
            erroredFut.complete(evt.requestId)
        ,
      )
      .expect("listen ChannelMessageErrorEvent")

    let channelReqId1 = manager.send(channelId, "first".toBytes()).expect("send 1")
    let channelReqId2 = manager.send(channelId, "second".toBytes()).expect("send 2")

    let dispatchDeadline = Moment.now() + 1.seconds
    while Moment.now() < dispatchDeadline and msgReqIds.len < 2:
      await sleepAsync(5.milliseconds)
    check msgReqIds.len == 2

    waku_message_events.MessageSentEvent.emit(
      brokerCtx,
      waku_message_events.MessageSentEvent(requestId: msgReqIds[0], messageHash: ""),
    )
    let sentArrived = await sentFut.withTimeout(1.seconds)
    check sentArrived
    if sentArrived:
      check sentFut.read() == channelReqId1
    ## The second `channelReqId` must NOT have finalised yet — its
    ## segment is still `InFlight`.
    check not erroredFut.finished()

    waku_message_events.MessageErrorEvent.emit(
      brokerCtx,
      waku_message_events.MessageErrorEvent(
        requestId: msgReqIds[1], messageHash: "", error: "synthetic"
      ),
    )
    let erroredArrived = await erroredFut.withTimeout(1.seconds)
    check erroredArrived
    if erroredArrived:
      check erroredFut.read() == channelReqId2

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

  asyncTest "sibling MessageSentEvent during sendHandler await does not corrupt state":
    ## Regression test for the prune-during-await race
    ## (PR #3914 review comment r3324891059). The historical model
    ## tracked segments in a flat `seq[PendingMessagingRequest]`,
    ## so a sibling `MessageSentEvent` arriving while `onReadyToSend`
    ## was paused at `await self.sendHandler(...)` would call
    ## `keepItIf` on that seq, shift the entries under the live `idx`
    ## walk, and either misassign the in-flight `messagingReqId` to
    ## the wrong row or crash on out-of-bounds. The current model
    ## keys per-request state by `channelReqId` in an `OrderedTable`,
    ## so every lookup is by key (not position) and stays valid
    ## across awaits. This test locks in the contract: both
    ## `channelReqId`s must still produce exactly one terminal
    ## `ChannelMessageSentEvent`.
    const
      channelId = ChannelId("sm-race-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sm-race")

    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      manager = (await ReliableChannelManager.new(createApiNodeConf())).expect(
        "Failed to create manager"
      )

    setNoopEncryption()

    var msgReqIds: seq[RequestId]
    var sendsReturned = 0
    let fakeSend: SendHandler = proc(
        env: MessageEnvelope
    ): Future[Result[RequestId, string]] {.async: (raises: [CatchableError]), gcsafe.} =
      ## Call 1: return immediately so the first segment's
      ## `messagingReqId` lands in `inflightMessagingIds`. Call 2:
      ## emit the final `MessageSentEvent` for the first segment,
      ## then yield via `sleepAsync` so the listener task runs while
      ## the second segment is still mid-`await` in `onReadyToSend`.
      ## Under the old positional-index model this is exactly the
      ## window that corrupted state; under the table-keyed model
      ## the listener mutates a different key and leaves our entry
      ## untouched.
      let id = RequestId("race-msg-req-" & $(msgReqIds.len + 1))
      msgReqIds.add(id)
      if msgReqIds.len == 2:
        waku_message_events.MessageSentEvent.emit(
          brokerCtx,
          waku_message_events.MessageSentEvent(requestId: msgReqIds[0], messageHash: ""),
        )
        await sleepAsync(50.milliseconds)
      sendsReturned.inc()
      return ok(id)

    discard manager
      .createReliableChannel(
        channelId, contentTopic, SdsParticipantID("local"), sendHandler = fakeSend
      )
      .expect("createReliableChannel")

    var finalisedReqIds: seq[RequestId]
    let bothFinalised = newFuture[void]("both-finalised")
    discard ChannelMessageSentEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageSentEvent) {.async: (raises: []).} =
          if evt.channelId == channelId:
            finalisedReqIds.add(evt.requestId)
            if finalisedReqIds.len == 2 and not bothFinalised.finished():
              bothFinalised.complete()
        ,
      )
      .expect("listen ChannelMessageSentEvent")

    let channelReqId1 = manager.send(channelId, "first".toBytes()).expect("send 1")

    ## Let the first segment fully traverse the pipeline so entry[0]
    ## is firmly `InFlight` with its `messagingReqId` set before send2
    ## queues entry[1]. Without this, listener2 could see entry[0]
    ## still `AwaitingRateLimit` and bind m2 to the wrong row — that
    ## is a different, pre-existing concurrency assumption (rate-limit
    ## FIFO between sibling sends) and not the bug we are testing.
    let firstDispatched = Moment.now() + 1.seconds
    while Moment.now() < firstDispatched and msgReqIds.len < 1:
      await sleepAsync(5.milliseconds)
    check msgReqIds.len == 1

    let channelReqId2 = manager.send(channelId, "second".toBytes()).expect("send 2")

    ## Wait until the second `fakeSend` has fully returned (not just
    ## entered). `sendsReturned` ticks after the sleep inside the if
    ## branch, so once it reaches 2 we know `fakeSend(m2)` has handed
    ## control back to `onReadyToSend`. The extra `sleepAsync` below
    ## then yields one more time so the chronos scheduler can run
    ## `onReadyToSend`'s post-await continuation — which is where
    ## `entry[1].messagingReqId = some(id2)` / state = `InFlight`
    ## actually get written. Without that final yield, the emit below
    ## would race the continuation and `MessageSentEvent(id2)` would
    ## find no `InFlight` entry to match.
    let dispatchDeadline = Moment.now() + 1.seconds
    while Moment.now() < dispatchDeadline and sendsReturned < 2:
      await sleepAsync(5.milliseconds)
    check sendsReturned == 2
    await sleepAsync(50.milliseconds)

    ## Now finalise the second segment from the outside; its final
    ## event must drive `channelReqId2` to `ChannelMessageSentEvent`.
    ## If the race corrupted state during the await, the second
    ## `messagingReqId` would never have been written to the right
    ## entry and this event would silently never fire.
    waku_message_events.MessageSentEvent.emit(
      brokerCtx,
      waku_message_events.MessageSentEvent(requestId: msgReqIds[1], messageHash: ""),
    )

    ## Under the table-keyed model both events fire because no fiber
    ## ever holds a positional reference: `onMessageSent(id1)` looks
    ## up `channelReq1` by key, decrements its counters, and finalizes
    ## (deleting that table key); meanwhile `onReadyToSend` is still
    ## processing `channelReq2` — a different key — so its post-await
    ## write to `inflightMessagingIds` lands on the correct, untouched
    ## entry. The external `MessageSentEvent(id2)` below then resolves
    ## `channelReq2`. Under the old `seq[PendingMessagingRequest]`
    ## model the sibling listener's `keepItIf` would have shifted the
    ## seq under the live `idx` walk and either crashed with
    ## `IndexDefect` or silently lost `channelReqId2`'s terminal event.
    let arrived = await bothFinalised.withTimeout(2.seconds)
    check arrived
    if arrived:
      check finalisedReqIds.len == 2
      check channelReqId1 in finalisedReqIds
      check channelReqId2 in finalisedReqIds

    await manager.stop()

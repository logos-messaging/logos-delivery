{.used.}

import results, std/[importutils, net, os, tables]
from std/times import epochTime
import chronos, testutils/unittests, stew/byteutils
import brokers/broker_context

import ../testlib/[wakucore, wakunodeconf, messaging_send]

import logos_delivery
import logos_delivery/waku/waku_core
import logos_delivery/api/events/messaging_client_events as waku_message_events
import logos_delivery/api/messaging_client_api
import tools/confutils/cli_args
import logos_delivery/api/conf/messaging_conf
import logos_delivery/api/conf/modes

import logos_delivery/channels/reliable_channel_manager
import logos_delivery/waku/persistency/keys
import logos_delivery/waku/persistency/sds_persistency

## Full nim-sds API: ingress tests act as the remote peer producing real
## SDS envelopes; protocol-semantics tests decode wires and meta snapshots.
import sds
import snapshot_codec

const TestTimeout = chronos.seconds(15)

proc createApiNodeConf(): LogosDeliveryNodeConf =
  defaultTestNodeConf()

proc oneSegment(payload: seq[byte]): seq[byte] =
  ## The wire unit a peer actually sends: one encoded `SegmentMessage`. Every
  ## payload wrapped here fits a single chunk, so this is the whole message.
  let handler = SegmentationHandler
    .new(
      ChannelSegmentationConfig.init(ReliableChannelManagerConf()),
      ChannelId("test"),
      globalBrokerContext(),
    )
    .expect("SegmentationHandler.new")
  return handler.performSegmentation(payload).expect("performSegmentation")[0]

suite "Reliable Channel - ingress":
  asyncTest "manager dispatches marked WakuMessage to the right channel":
    ## Unit test for the receive side of the API: instead of standing
    ## up two libp2p nodes and a relay mesh, we drive the manager
    ## directly by emitting a `MessageReceivedEvent` (the exact event
    ## the MessagingClient emits when a `WakuMessage` arrives off the
    ## wire). The manager must:
    ##   - drop traffic missing the Reliable Channel spec marker
    ##   - dispatch the matching channel's `onMessageReceived`
    ##   - emit `ChannelMessageReceivedEvent` with the payload
    const
      channelId = ChannelId("test-channel")
      contentTopic = ContentTopic("/reliable-channel/test/proto")
    let appPayload = "hello reliable channel".toBytes()

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    let received = newFuture[ChannelMessageReceivedEvent]("channel-message-received")
    discard ChannelMessageReceivedEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageReceivedEvent) {.async: (raises: []).} =
          if not received.finished() and evt.channelId == channelId:
            received.complete(evt)
        ,
      )
      .expect("listen ChannelMessageReceivedEvent")

    ## Build a `WakuMessage` as it would arrive off the wire: spec marker
    ## on `meta`, right content topic, payload wrapped in a real SDS
    ## envelope by a stand-in remote peer.
    let remotePeer =
      ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
    let sdsWire = (
      await remotePeer.wrapOutgoingMessage(
        oneSegment(appPayload), "ingress-test-msg-1", SdsChannelID(channelId)
      )
    ).expect("wrapOutgoingMessage")

    let inboundMsg = WakuMessage(
      payload: sdsWire,
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
      let evt = received.read()
      check evt.payload == appPayload
      ## wire sender's id, not the local participant id
      check evt.senderId == SdsParticipantID("remote")

    (await waku.stop()).expect("stop")

  asyncTest "manager drops unmarked WakuMessage":
    ## Mirror of the above: same content topic, but `meta` is empty
    ## (i.e. foreign traffic). The channel-level event must NOT fire.
    const
      channelId = ChannelId("test-channel-2")
      contentTopic = ContentTopic("/reliable-channel/test/proto")
    let appPayload = "foreign payload".toBytes()

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

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

    (await waku.stop()).expect("stop")

  asyncTest "closed channel emits no channel event":
    ## Issue #4065: no ChannelMessageReceivedEvent after closeChannel.
    const
      channelId = ChannelId("test-channel-3")
      contentTopic = ContentTopic("/reliable-channel/test/proto")
    let appPayload = "after close".toBytes()

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    (await manager.closeChannel(channelId)).expect("closeChannel")

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

    let remotePeer =
      ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
    let sdsWire = (
      await remotePeer.wrapOutgoingMessage(
        oneSegment(appPayload), "close-test-msg-1", SdsChannelID(channelId)
      )
    ).expect("wrapOutgoingMessage")

    let inboundMsg = WakuMessage(
      payload: sdsWire,
      contentTopic: contentTopic,
      version: 0,
      meta: LipWireReliableChannelVersion.toBytes(),
    )

    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(messageHash: "", message: inboundMsg),
    )

    await sleepAsync(100.milliseconds)
    check not fired

    (await waku.stop()).expect("stop")

  asyncTest "in-flight receive does not emit after close":
    ## A message already inside the ingress pipeline when closeChannel
    ## runs must not emit after close returns.
    const
      channelId = ChannelId("test-channel-4")
      contentTopic = ContentTopic("/reliable-channel/test/proto")
    let appPayload = "in flight".toBytes()

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    ## Gate decryption so the receive handler parks mid-pipeline.
    let decryptGate = newFuture[void]("decrypt-gate")
    let gatedCrypto = ChannelCrypto
      .init(
        encrypt = proc(
            payload: seq[byte]
        ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
          return ok(payload),
        decrypt = proc(
            payload: seq[byte]
        ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
          try:
            await decryptGate
          except CatchableError as e:
            return err(e.msg)
          return ok(payload),
      )
      .expect("ChannelCrypto.init")

    discard manager
      .createReliableChannel(
        channelId, contentTopic, SdsParticipantID("local"), Opt.some(gatedCrypto)
      )
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

    let remotePeer =
      ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
    let sdsWire = (
      await remotePeer.wrapOutgoingMessage(
        oneSegment(appPayload), "inflight-test-msg-1", SdsChannelID(channelId)
      )
    ).expect("wrapOutgoingMessage")

    let inboundMsg = WakuMessage(
      payload: sdsWire,
      contentTopic: contentTopic,
      version: 0,
      meta: LipWireReliableChannelVersion.toBytes(),
    )

    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(messageHash: "", message: inboundMsg),
    )

    ## Let the handler reach the decrypt await, then close mid-flight.
    await sleepAsync(50.milliseconds)
    (await manager.closeChannel(channelId)).expect("closeChannel")

    decryptGate.complete()
    await sleepAsync(100.milliseconds)
    check not fired

    (await waku.stop()).expect("stop")

suite "Reliable Channel - send state machine":
  asyncTest "MessageSentEvent finalises the channelReqId as Sent":
    ## Drives the real send pipeline (`send` -> segmentation -> SDS ->
    ## rate_limit -> encrypt -> dispatch) via a fake `MessagingSend` provider that
    ## returns a canned message hash instead of hitting the network.
    ## Emitting the delivery-layer `MessageSentEvent` must drive the
    ## channel-level state machine through `Confirmed` and produce a
    ## `ChannelMessageSentEvent` (channel-level terminal event) for the
    ## `channelReqId` returned by `send()`.
    const
      channelId = ChannelId("sm-success-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sm-success")
      FakeMsgId = "fake-msg-req-1"

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    var sendCalls = 0
    MessagingSend.replaceProvider(
      brokerCtx,
      proc(envelope: MessageEnvelope): Future[Result[SendResult, string]] {.async.} =
        sendCalls.inc
        return ok(SendResult.ok(fakeHash(FakeMsgId))),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
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

    let channelReqId = (await manager.send(channelId, "hello".toBytes())).expect("send")

    let dispatchDeadline = Moment.now() + 1.seconds
    while Moment.now() < dispatchDeadline and sendCalls == 0:
      await sleepAsync(5.milliseconds)
    check sendCalls == 1

    waku_message_events.MessageSentEvent.emit(
      brokerCtx,
      waku_message_events.MessageSentEvent(messageHash: fakeHash(FakeMsgId).to0xHex()),
    )

    let finalised = await sentFut.withTimeout(1.seconds)
    check finalised
    if finalised:
      check sentFut.read() == channelReqId

    (await waku.stop()).expect("stop")

  proc refusingChannel(
      channelId: ChannelId, contentTopic: ContentTopic, refusals: ref seq[SendError]
  ): Future[(LogosDelivery, ReliableChannelManager, BrokerContext)] {.async.} =
    ## A node with one channel and a fake `MessagingSend` provider.
    ## The provider refuses a send with the first error of `refusals` and removes it.
    ## It accepts each send after the last error.
    var waku: LogosDelivery
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
    let manager = waku.reliableChannelManager

    MessagingSend.replaceProvider(
      brokerCtx,
      proc(envelope: MessageEnvelope): Future[Result[SendResult, string]] {.async.} =
        if refusals[].len > 0:
          let refusal = refusals[][0]
          refusals[].delete(0)
          return ok(SendResult.err(refusal))
        return ok(SendResult.ok(fakeHash("accepted-segment"))),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")
    return (waku, manager, brokerCtx)

  proc channelError(
      brokerCtx: BrokerContext, channelId: ChannelId
  ): Future[ChannelMessageErrorEvent] =
    ## Completes with the first error event of the channel.
    let errored = newFuture[ChannelMessageErrorEvent]("channel-errored")
    discard ChannelMessageErrorEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageErrorEvent) {.async: (raises: []).} =
          if not errored.finished() and evt.channelId == channelId:
            errored.complete(evt)
        ,
      )
      .expect("listen ChannelMessageErrorEvent")
    return errored

  asyncTest "a refusal that a later send cannot clear fails the channel request":
    ## The app of the channel needs the reason of the refusal.
    const
      channelId = ChannelId("sm-refused-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sm-refused")
    let refusals = new seq[SendError]
    refusals[] = @[SendError.init(SendErrorKind.TooLarge, "too many bytes")]
    let (waku, manager, brokerCtx) =
      await refusingChannel(channelId, contentTopic, refusals)
    let errored = channelError(brokerCtx, channelId)

    let channelReqId = (await manager.send(channelId, "hello".toBytes())).expect("send")

    check await errored.withTimeout(1.seconds)
    if errored.finished():
      check:
        errored.read().requestId == channelReqId
        errored.read().error ==
          "one or more segments failed: messaging send failed: TooLarge: too many bytes"

    (await waku.stop()).expect("stop")

  asyncTest "a segment refused for the rate limit or for a full send service is sent again":
    ## The messaging `send` keeps no message that it refused.
    ## So the channel must send the segment again, or the message is lost.
    privateAccess(ReliableChannel)
    const
      channelId = ChannelId("sm-retry-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sm-retry")
    let refusals = new seq[SendError]
    refusals[] = @[
      SendError.init(SendErrorKind.RateLimited, "budget spent", 10.milliseconds),
      SendError.init(SendErrorKind.QueueFull, "full"),
    ]
    let (waku, manager, brokerCtx) =
      await refusingChannel(channelId, contentTopic, refusals)
    manager.channels[channelId].segmentRetryInterval = 10.milliseconds
    let errored = channelError(brokerCtx, channelId)

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

    let channelReqId = (await manager.send(channelId, "hello".toBytes())).expect("send")

    # The provider accepts the third send of the segment.
    let retryDeadline = Moment.now() + 1.seconds
    while Moment.now() < retryDeadline and refusals[].len > 0:
      await sleepAsync(5.milliseconds)
    check refusals[].len == 0

    # The channel takes the event only after it has the hash of the accepted send.
    let sentDeadline = Moment.now() + 1.seconds
    while Moment.now() < sentDeadline and not sentFut.finished():
      waku_message_events.MessageSentEvent.emit(
        brokerCtx,
        waku_message_events.MessageSentEvent(
          messageHash: fakeHash("accepted-segment").to0xHex()
        ),
      )
      await sleepAsync(5.milliseconds)

    check sentFut.finished()
    if sentFut.finished():
      check sentFut.read() == channelReqId
    check not errored.finished()

    (await waku.stop()).expect("stop")

  asyncTest "a segment refused for longer than its retry window fails the channel request":
    privateAccess(ReliableChannel)
    const
      channelId = ChannelId("sm-retry-window-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sm-retry-window")
    let refusals = new seq[SendError]
    for _ in 0 ..< 1000:
      refusals[].add(SendError.init(SendErrorKind.QueueFull, "full"))
    let (waku, manager, brokerCtx) =
      await refusingChannel(channelId, contentTopic, refusals)
    manager.channels[channelId].segmentRetryInterval = 10.milliseconds
    manager.channels[channelId].queueFullRetryWindow = 50.milliseconds
    let errored = channelError(brokerCtx, channelId)

    let channelReqId = (await manager.send(channelId, "hello".toBytes())).expect("send")

    check await errored.withTimeout(1.seconds)
    if errored.finished():
      check:
        errored.read().requestId == channelReqId
        errored.read().error ==
          "one or more segments failed: messaging send failed: QueueFull: full"
    check refusals[].len < 1000 - 1 # the channel sent the segment again

    (await waku.stop()).expect("stop")

  asyncTest "a segment whose refusal changes its kind gets the retry window of the new kind":
    ## The rate limit asks for a wait that is longer than the window for a full send service.
    privateAccess(ReliableChannel)
    const
      channelId = ChannelId("sm-retry-kind-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sm-retry-kind")
    let refusals = new seq[SendError]
    refusals[] = @[
      SendError.init(SendErrorKind.QueueFull, "full"),
      SendError.init(SendErrorKind.RateLimited, "budget spent", 100.milliseconds),
    ]
    let (waku, manager, brokerCtx) =
      await refusingChannel(channelId, contentTopic, refusals)
    manager.channels[channelId].segmentRetryInterval = 10.milliseconds
    manager.channels[channelId].queueFullRetryWindow = 50.milliseconds
    let errored = channelError(brokerCtx, channelId)

    discard (await manager.send(channelId, "hello".toBytes())).expect("send")

    # The provider accepts the third send of the segment.
    let retryDeadline = Moment.now() + 2.seconds
    while Moment.now() < retryDeadline and refusals[].len > 0:
      await sleepAsync(5.milliseconds)
    await sleepAsync(150.milliseconds)
    check:
      refusals[].len == 0
      not errored.finished()

    (await waku.stop()).expect("stop")

  asyncTest "two independent channelReqIds are finalised independently":
    ## Two `send()` calls -> two independent `channelReqId`s, each a
    ## single segment because both payloads fit one chunk (the
    ## multi-segment case is covered by the prune tests below). The fake
    ## `MessagingSend` provider returns distinct message hashes;
    ## finalising the first emits `ChannelMessageSentEvent` for its
    ## `channelReqId`, finalising the second as a failure emits
    ## `ChannelMessageErrorEvent` for the other.
    const
      channelId = ChannelId("sm-multi-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sm-multi")

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    var msgHashes: seq[WakuMessageHash]
    MessagingSend.replaceProvider(
      brokerCtx,
      proc(envelope: MessageEnvelope): Future[Result[SendResult, string]] {.async.} =
        let id = fakeHash("fake-msg-req-" & $(msgHashes.len + 1))
        msgHashes.add(id)
        return ok(SendResult.ok(id)),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
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

    let channelReqId1 =
      (await manager.send(channelId, "first".toBytes())).expect("send 1")
    let channelReqId2 =
      (await manager.send(channelId, "second".toBytes())).expect("send 2")

    let dispatchDeadline = Moment.now() + 1.seconds
    while Moment.now() < dispatchDeadline and msgHashes.len < 2:
      await sleepAsync(5.milliseconds)
    check msgHashes.len == 2

    waku_message_events.MessageSentEvent.emit(
      brokerCtx,
      waku_message_events.MessageSentEvent(messageHash: msgHashes[0].to0xHex()),
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
        messageHash: msgHashes[1].to0xHex(),
        kind: MessageErrorKind.NotPropagated,
        error: "synthetic",
      ),
    )
    let erroredArrived = await erroredFut.withTimeout(1.seconds)
    check erroredArrived
    if erroredArrived:
      check erroredFut.read() == channelReqId2

    (await waku.stop()).expect("stop")

  asyncTest "channelReqId not pruned until ALL its segments are final":
    ## Multi-sibling prune rule: one `send()` of a payload spanning four
    ## segments yields four message hashes under a single
    ## `channelReqId`. Finalising three of them must NOT emit the
    ## channel-level terminal event; only the fourth may, and exactly once.
    const
      channelId = ChannelId("sm-prune-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sm-prune")

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    var msgHashes: seq[WakuMessageHash]
    MessagingSend.replaceProvider(
      brokerCtx,
      proc(envelope: MessageEnvelope): Future[Result[SendResult, string]] {.async.} =
        let id = fakeHash("prune-msg-req-" & $(msgHashes.len + 1))
        msgHashes.add(id)
        return ok(SendResult.ok(id)),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    var sentCount = 0
    let sentFut = newFuture[RequestId]("channel-sent")
    discard ChannelMessageSentEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageSentEvent) {.async: (raises: []).} =
          if evt.channelId == channelId:
            sentCount.inc()
            if not sentFut.finished():
              sentFut.complete(evt.requestId)
        ,
      )
      .expect("listen ChannelMessageSentEvent")

    ## The channel is built from the same defaults, so this handler reports
    ## the chunk size its segmentation actually uses.
    let segHandler = SegmentationHandler
      .new(
        ChannelSegmentationConfig.init(ReliableChannelManagerConf()),
        channelId,
        brokerCtx,
      )
      .expect("SegmentationHandler.new")

    ## Just over three chunks -> four data segments (parity is off by default).
    let payload = newSeq[byte](3 * segHandler.chunkSize() + 1)
    let channelReqId = (await manager.send(channelId, payload)).expect("send")

    let dispatchDeadline = Moment.now() + 5.seconds
    while Moment.now() < dispatchDeadline and msgHashes.len < 4:
      await sleepAsync(5.milliseconds)
    check msgHashes.len == 4

    for i in 0 .. 2:
      waku_message_events.MessageSentEvent.emit(
        brokerCtx,
        waku_message_events.MessageSentEvent(messageHash: msgHashes[i].to0xHex()),
      )
    await sleepAsync(100.milliseconds)
    check not sentFut.finished()

    waku_message_events.MessageSentEvent.emit(
      brokerCtx,
      waku_message_events.MessageSentEvent(messageHash: msgHashes[3].to0xHex()),
    )
    let finalised = await sentFut.withTimeout(1.seconds)
    check finalised
    if finalised:
      check sentFut.read() == channelReqId
    ## One parent request, one terminal event — not one per segment.
    await sleepAsync(50.milliseconds)
    check sentCount == 1

    (await waku.stop()).expect("stop")

  asyncTest "a single failed segment fails the whole channelReqId":
    ## Same four-segment send, but the last sibling fails: the parent must
    ## finalise as `ChannelMessageErrorEvent` rather than as sent.
    const
      channelId = ChannelId("sm-prune-fail-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sm-prune-fail")

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    var msgHashes: seq[WakuMessageHash]
    MessagingSend.replaceProvider(
      brokerCtx,
      proc(envelope: MessageEnvelope): Future[Result[SendResult, string]] {.async.} =
        let id = fakeHash("prune-fail-msg-req-" & $(msgHashes.len + 1))
        msgHashes.add(id)
        return ok(SendResult.ok(id)),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    var sentFired = false
    let erroredFut = newFuture[RequestId]("channel-errored")
    discard ChannelMessageSentEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageSentEvent) {.async: (raises: []).} =
          if evt.channelId == channelId:
            sentFired = true
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

    let segHandler = SegmentationHandler
      .new(
        ChannelSegmentationConfig.init(ReliableChannelManagerConf()),
        channelId,
        brokerCtx,
      )
      .expect("SegmentationHandler.new")
    let payload = newSeq[byte](3 * segHandler.chunkSize() + 1)
    let channelReqId = (await manager.send(channelId, payload)).expect("send")

    let dispatchDeadline = Moment.now() + 5.seconds
    while Moment.now() < dispatchDeadline and msgHashes.len < 4:
      await sleepAsync(5.milliseconds)
    check msgHashes.len == 4

    for i in 0 .. 2:
      waku_message_events.MessageSentEvent.emit(
        brokerCtx,
        waku_message_events.MessageSentEvent(messageHash: msgHashes[i].to0xHex()),
      )
    await sleepAsync(100.milliseconds)
    check not erroredFut.finished()

    waku_message_events.MessageErrorEvent.emit(
      brokerCtx,
      waku_message_events.MessageErrorEvent(
        messageHash: msgHashes[3].to0xHex(),
        kind: MessageErrorKind.NotPropagated,
        error: "synthetic",
      ),
    )
    let errored = await erroredFut.withTimeout(1.seconds)
    check errored
    if errored:
      check erroredFut.read() == channelReqId
    check not sentFired

    (await waku.stop()).expect("stop")

  asyncTest "sibling MessageSentEvent during sendHandler await does not corrupt state":
    ## Regression test for the prune-during-await race
    ## (PR #3914 review comment r3324891059). Locks in that a sibling
    ## `MessageSentEvent` firing while `send` is paused at a
    ## `MessagingSend.request` await does not lose the second
    ## `channelReqId`'s terminal event.
    const
      channelId = ChannelId("sm-race-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sm-race")

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    var msgHashes: seq[WakuMessageHash]
    var sendsReturned = 0
    MessagingSend.replaceProvider(
      brokerCtx,
      proc(envelope: MessageEnvelope): Future[Result[SendResult, string]] {.async.} =
        ## Call 2 fires the first segment's terminal event and then
        ## yields, so the listener task runs while the second segment
        ## is still mid-`await` inside `send` — the exact race window
        ## the regression test targets.
        let id = fakeHash("race-msg-req-" & $(msgHashes.len + 1))
        msgHashes.add(id)
        if msgHashes.len == 2:
          MessageSentEvent.emit(
            brokerCtx, MessageSentEvent(messageHash: msgHashes[0].to0xHex())
          )
          await sleepAsync(50.milliseconds)
        sendsReturned.inc()
        return ok(SendResult.ok(id)),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
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

    let channelReqId1 =
      (await manager.send(channelId, "first".toBytes())).expect("send 1")

    ## Drain the first segment fully before queueing the second, so
    ## inter-send ordering isn't itself under test here.
    let firstDispatched = Moment.now() + 1.seconds
    while Moment.now() < firstDispatched and msgHashes.len < 1:
      await sleepAsync(5.milliseconds)
    check msgHashes.len == 1

    let channelReqId2 =
      (await manager.send(channelId, "second".toBytes())).expect("send 2")

    ## Wait until `fakeSend(m2)` has fully returned and yield once
    ## more so `send`'s post-await continuation gets a chance to
    ## register `id2` in `inflightMessagingIds` before we emit its
    ## terminal event.
    let dispatchDeadline = Moment.now() + 1.seconds
    while Moment.now() < dispatchDeadline and sendsReturned < 2:
      await sleepAsync(5.milliseconds)
    check sendsReturned == 2
    await sleepAsync(50.milliseconds)

    ## Finalise the second segment from the outside. If the race
    ## corrupted state, `channelReqId2`'s entry would never reach
    ## `inflightMessagingIds` and this event would silently miss.
    waku_message_events.MessageSentEvent.emit(
      brokerCtx,
      waku_message_events.MessageSentEvent(messageHash: msgHashes[1].to0xHex()),
    )

    let arrived = await bothFinalised.withTimeout(2.seconds)
    check arrived
    if arrived:
      check finalisedReqIds.len == 2
      check channelReqId1 in finalisedReqIds
      check channelReqId2 in finalisedReqIds

    (await waku.stop()).expect("stop")

suite "Reliable Channel - SDS persistence":
  asyncTest "send persists SDS channel state through the persistency job":
    ## A send must flush `sds.meta` + `sds.log` through the shared "sds"
    ## job. Writes resolve on enqueue, so reads poll.
    const
      channelId = ChannelId("sds-persist-channel")
      contentTopic = ContentTopic("/reliable-channel/test/persist")

    let root = getTempDir() / ("reliable_channel_sds_" & $epochTime().int)
    removeDir(root)
    let persistency = Persistency.new(root).expect("persistency init")
    defer:
      persistency.close()
      removeDir(root)

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    lockNewGlobalBrokerContext:
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    discard GetPersistency.reprovideIt(manager.brokerCtx):
      ok(persistency)

    MessagingSend.replaceProvider(
      globalBrokerContext(),
      proc(envelope: MessageEnvelope): Future[Result[SendResult, string]] {.async.} =
        return ok(SendResult.ok(fakeHash("persist-msg-req-1"))),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    discard (await manager.send(channelId, "persist me".toBytes())).expect("send")

    ## Same handle the channel layer writes through (`openJob` is idempotent).
    let job = persistency.openJob("sds").expect("openJob sds")
    let chanKey = toKey(SdsChannelID(channelId))

    proc pollMetaExists(): Future[bool] {.async.} =
      let deadline = Moment.now() + 2.seconds
      while Moment.now() < deadline:
        let r = await job.exists(CatMeta, chanKey)
        if r.isOk() and r.get():
          return true
        await sleepAsync(5.milliseconds)
      return false

    proc pollLogRow(): Future[bool] {.async.} =
      ## `sds.log` keys rows by (channelId, messageId) — scan the prefix.
      let deadline = Moment.now() + 2.seconds
      while Moment.now() < deadline:
        let r = await job.scanPrefix(CatLog, chanKey)
        if r.isOk() and r.get().len > 0:
          return true
        await sleepAsync(5.milliseconds)
      return false

    check await pollMetaExists()
    check await pollLogRow()

    (await waku.stop()).expect("stop")

## A marked WakuMessage carrying an SDS envelope, as it arrives off the wire.
proc sdsWakuMessage(contentTopic: ContentTopic, sdsWire: seq[byte]): WakuMessage =
  WakuMessage(
    payload: sdsWire,
    contentTopic: contentTopic,
    version: 0,
    meta: LipWireReliableChannelVersion.toBytes(),
  )

suite "Reliable Channel - SDS lifecycle":
  asyncTest "out-of-order segments are parked and delivered in causal order":
    ## m2 depends on m1: m2 alone delivers nothing; m1 then delivers both,
    ## in causal order.
    const
      channelId = ChannelId("sds-causal-channel")
      contentTopic = ContentTopic("/reliable-channel/test/causal")
    let payload1 = "first message".toBytes()
    let payload2 = "second message".toBytes()

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    var deliveries: seq[seq[byte]]
    discard ChannelMessageReceivedEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageReceivedEvent) {.async: (raises: []).} =
          if evt.channelId == channelId:
            deliveries.add(evt.payload)
        ,
      )
      .expect("listen ChannelMessageReceivedEvent")

    let remotePeer =
      ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
    let wire1 = (
      await remotePeer.wrapOutgoingMessage(
        oneSegment(payload1), "causal-m1", SdsChannelID(channelId)
      )
    ).expect("wrap m1")
    let wire2 = (
      await remotePeer.wrapOutgoingMessage(
        oneSegment(payload2), "causal-m2", SdsChannelID(channelId)
      )
    ).expect("wrap m2")

    ## m2 first: missing dependency m1 -> parked, nothing delivered.
    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(
        messageHash: "hash-m2", message: sdsWakuMessage(contentTopic, wire2)
      ),
    )
    await sleepAsync(100.milliseconds)
    check deliveries.len == 0

    ## m1 arrives: m1 delivered, then the parked m2 released after it.
    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(
        messageHash: "hash-m1", message: sdsWakuMessage(contentTopic, wire1)
      ),
    )
    let deadline = Moment.now() + 2.seconds
    while Moment.now() < deadline and deliveries.len < 2:
      await sleepAsync(5.milliseconds)
    check deliveries.len == 2
    if deliveries.len == 2:
      check deliveries[0] == payload1
      check deliveries[1] == payload2

    (await waku.stop()).expect("stop")

  asyncTest "duplicate SDS envelope is delivered to the app only once":
    const
      channelId = ChannelId("sds-dup-channel")
      contentTopic = ContentTopic("/reliable-channel/test/dup")
    let appPayload = "deliver once".toBytes()

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    var deliveryCount = 0
    discard ChannelMessageReceivedEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageReceivedEvent) {.async: (raises: []).} =
          if evt.channelId == channelId:
            deliveryCount.inc()
        ,
      )
      .expect("listen ChannelMessageReceivedEvent")

    let remotePeer =
      ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
    let wire = (
      await remotePeer.wrapOutgoingMessage(
        oneSegment(appPayload), "dup-m1", SdsChannelID(channelId)
      )
    ).expect("wrap")

    ## Same envelope twice (different hashes) — the second must be suppressed.
    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(
        messageHash: "dup-hash-1", message: sdsWakuMessage(contentTopic, wire)
      ),
    )
    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(
        messageHash: "dup-hash-2", message: sdsWakuMessage(contentTopic, wire)
      ),
    )
    await sleepAsync(200.milliseconds)
    check deliveryCount == 1

    (await waku.stop()).expect("stop")

  asyncTest "SDS envelope for a foreign channel is dropped":
    ## Same content topic, different SDS channel id — dropped before unwrap.
    const
      channelId = ChannelId("sds-foreign-channel")
      contentTopic = ContentTopic("/reliable-channel/test/foreign")

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

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

    let remotePeer =
      ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
    let wire = (
      await remotePeer.wrapOutgoingMessage(
        oneSegment("not for you".toBytes()),
        "foreign-m1",
        SdsChannelID("some-other-channel"),
      )
    ).expect("wrap")

    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(
        messageHash: "foreign-hash", message: sdsWakuMessage(contentTopic, wire)
      ),
    )
    await sleepAsync(200.milliseconds)
    check not fired

    (await waku.stop()).expect("stop")

  asyncTest "received history survives channel close and re-create":
    ## Receive m1, close, re-create, replay m1: the duplicate is only
    ## suppressed if the history was actually restored from SQLite.
    const
      channelId = ChannelId("sds-restore-channel")
      contentTopic = ContentTopic("/reliable-channel/test/restore")
    let appPayload = "survive restart".toBytes()

    let root = getTempDir() / ("reliable_channel_sds_restore_" & $epochTime().int)
    removeDir(root)
    let persistency = Persistency.new(root).expect("persistency init")
    defer:
      persistency.close()
      removeDir(root)

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    discard GetPersistency.reprovideIt(manager.brokerCtx):
      ok(persistency)

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    var deliveryCount = 0
    discard ChannelMessageReceivedEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageReceivedEvent) {.async: (raises: []).} =
          if evt.channelId == channelId:
            deliveryCount.inc()
        ,
      )
      .expect("listen ChannelMessageReceivedEvent")

    let remotePeer =
      ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
    let wire = (
      await remotePeer.wrapOutgoingMessage(
        oneSegment(appPayload), "restore-m1", SdsChannelID(channelId)
      )
    ).expect("wrap")

    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(
        messageHash: "restore-hash-1", message: sdsWakuMessage(contentTopic, wire)
      ),
    )
    var deadline = Moment.now() + 2.seconds
    while Moment.now() < deadline and deliveryCount < 1:
      await sleepAsync(5.milliseconds)
    check deliveryCount == 1

    ## Writes resolve on enqueue — wait until the row is applied before closing.
    let job = persistency.openJob("sds").expect("openJob sds")
    let chanKey = toKey(SdsChannelID(channelId))
    deadline = Moment.now() + 2.seconds
    var logVisible = false
    while Moment.now() < deadline and not logVisible:
      let r = await job.scanPrefix(CatLog, chanKey)
      logVisible = r.isOk() and r.get().len > 0
      if not logVisible:
        await sleepAsync(5.milliseconds)
    check logVisible

    (await manager.closeChannel(channelId)).expect("closeChannel")

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("re-createReliableChannel")

    ## Replay the same envelope. Only a restored history suppresses it.
    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(
        messageHash: "restore-hash-2", message: sdsWakuMessage(contentTopic, wire)
      ),
    )
    await sleepAsync(300.milliseconds)
    check deliveryCount == 1

    (await waku.stop()).expect("stop")

suite "Reliable Channel - SDS protocol semantics":
  asyncTest "a reply references the received message and advances the lamport clock":
    ## After receiving m1, our outgoing wire must reference m1 in its causal
    ## history (that reference IS the ack) with a higher lamport.
    const
      channelId = ChannelId("sds-semantics-channel")
      contentTopic = ContentTopic("/reliable-channel/test/semantics")

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    var capturedWires: seq[seq[byte]]
    MessagingSend.replaceProvider(
      brokerCtx,
      proc(envelope: MessageEnvelope): Future[Result[SendResult, string]] {.async.} =
        ## Noop encryption is identity, so the envelope payload IS the SDS wire.
        capturedWires.add(envelope.payload)
        return ok(SendResult.ok(fakeHash("semantics-req-" & $capturedWires.len))),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    let remotePeer =
      ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
    let wire1 = (
      await remotePeer.wrapOutgoingMessage(
        oneSegment("from remote".toBytes()), "semantics-m1", SdsChannelID(channelId)
      )
    ).expect("wrap m1")
    let m1 = deserializeMessage(wire1).expect("deserialize m1")

    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(
        messageHash: "semantics-hash-1", message: sdsWakuMessage(contentTopic, wire1)
      ),
    )
    await sleepAsync(100.milliseconds)

    discard (await manager.send(channelId, "reply".toBytes())).expect("send")
    var deadline = Moment.now() + 2.seconds
    while Moment.now() < deadline and capturedWires.len < 1:
      await sleepAsync(5.milliseconds)
    check capturedWires.len == 1

    let reply = deserializeMessage(capturedWires[0]).expect("deserialize reply")
    check SdsMessageID("semantics-m1") in reply.causalHistory.getMessageIds()
    check reply.lamportTimestamp > m1.lamportTimestamp

    (await waku.stop()).expect("stop")

  asyncTest "an unacknowledged send is acked by a later remote message":
    ## Our send sits in the outgoing buffer (visible in the persisted meta)
    ## until any later remote message references it — then the buffer drains.
    const
      channelId = ChannelId("sds-ack-channel")
      contentTopic = ContentTopic("/reliable-channel/test/ack")

    let root = getTempDir() / ("reliable_channel_sds_ack_" & $epochTime().int)
    removeDir(root)
    let persistency = Persistency.new(root).expect("persistency init")
    defer:
      persistency.close()
      removeDir(root)

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    discard GetPersistency.reprovideIt(manager.brokerCtx):
      ok(persistency)

    var capturedWires: seq[seq[byte]]
    MessagingSend.replaceProvider(
      brokerCtx,
      proc(envelope: MessageEnvelope): Future[Result[SendResult, string]] {.async.} =
        ## Noop encryption is identity, so the envelope payload IS the SDS wire.
        capturedWires.add(envelope.payload)
        return ok(SendResult.ok(fakeHash("ack-req-" & $capturedWires.len))),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    discard (await manager.send(channelId, "needs ack".toBytes())).expect("send")
    var deadline = Moment.now() + 2.seconds
    while Moment.now() < deadline and capturedWires.len < 1:
      await sleepAsync(5.milliseconds)
    check capturedWires.len == 1

    let job = persistency.openJob("sds").expect("openJob sds")
    let chanKey = toKey(SdsChannelID(channelId))

    proc outgoingBufferLen(): Future[int] {.async.} =
      ## Decode the persisted meta snapshot; -1 while not yet readable.
      let r = await job.get(CatMeta, chanKey)
      if r.isErr() or r.get().isNone():
        return -1
      let meta = ChannelMeta.decode(r.get().get()).valueOr:
        return -1
      return meta.outgoingBuffer.len

    ## After the send the message must sit unacknowledged in the buffer.
    deadline = Moment.now() + 2.seconds
    var bufLen = -1
    while Moment.now() < deadline and bufLen != 1:
      bufLen = await outgoingBufferLen()
      if bufLen != 1:
        await sleepAsync(5.milliseconds)
    check bufLen == 1

    ## The remote received our wire; its next message references it.
    let remotePeer =
      ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
    discard
      (await remotePeer.unwrapReceivedMessage(capturedWires[0])).expect("remote unwrap")
    let ackCarrier = (
      await remotePeer.wrapOutgoingMessage(
        oneSegment("any later message".toBytes()),
        "ack-carrier-1",
        SdsChannelID(channelId),
      )
    ).expect("wrap ack carrier")

    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(
        messageHash: "ack-hash-1", message: sdsWakuMessage(contentTopic, ackCarrier)
      ),
    )

    ## Receiving it must drain the outgoing buffer (op-end meta flush).
    deadline = Moment.now() + 2.seconds
    bufLen = -1
    while Moment.now() < deadline and bufLen != 0:
      bufLen = await outgoingBufferLen()
      if bufLen != 0:
        await sleepAsync(5.milliseconds)
    check bufLen == 0

    (await waku.stop()).expect("stop")

  asyncTest "three-deep dependency chain is released in causal order":
    ## m1 <- m2 <- m3 arriving as m3, m2, m1: all held until m1 lands,
    ## then released as m1, m2, m3.
    const
      channelId = ChannelId("sds-chain-channel")
      contentTopic = ContentTopic("/reliable-channel/test/chain")
    let payloads =
      @["chain first".toBytes(), "chain second".toBytes(), "chain third".toBytes()]

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    var deliveries: seq[seq[byte]]
    discard ChannelMessageReceivedEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageReceivedEvent) {.async: (raises: []).} =
          if evt.channelId == channelId:
            deliveries.add(evt.payload)
        ,
      )
      .expect("listen ChannelMessageReceivedEvent")

    let remotePeer =
      ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
    var wires: seq[seq[byte]]
    for i in 0 .. 2:
      wires.add(
        (
          await remotePeer.wrapOutgoingMessage(
            oneSegment(payloads[i]), "chain-m" & $(i + 1), SdsChannelID(channelId)
          )
        ).expect("wrap chain-m" & $(i + 1))
      )

    ## Deepest first: m3, then m2 — both must be parked.
    for i in [2, 1]:
      waku_message_events.MessageReceivedEvent.emit(
        brokerCtx,
        waku_message_events.MessageReceivedEvent(
          messageHash: "chain-hash-" & $(i + 1),
          message: sdsWakuMessage(contentTopic, wires[i]),
        ),
      )
    await sleepAsync(150.milliseconds)
    check deliveries.len == 0

    ## The root arrives: everything drains in causal order.
    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(
        messageHash: "chain-hash-1", message: sdsWakuMessage(contentTopic, wires[0])
      ),
    )
    let deadline = Moment.now() + 2.seconds
    while Moment.now() < deadline and deliveries.len < 3:
      await sleepAsync(5.milliseconds)
    check deliveries.len == 3
    if deliveries.len == 3:
      check deliveries[0] == payloads[0]
      check deliveries[1] == payloads[1]
      check deliveries[2] == payloads[2]

    (await waku.stop()).expect("stop")

  asyncTest "sync envelope without app payload is consumed silently":
    ## Sync traffic has no app payload: no event, and normal traffic
    ## keeps flowing afterwards.
    const
      channelId = ChannelId("sds-sync-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sync")
    let appPayload = "real message".toBytes()

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    var deliveryCount = 0
    discard ChannelMessageReceivedEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageReceivedEvent) {.async: (raises: []).} =
          if evt.channelId == channelId:
            deliveryCount.inc()
        ,
      )
      .expect("listen ChannelMessageReceivedEvent")

    ## Hand-built sync envelope: valid SDS message, empty content.
    let syncMsg = SdsMessage.init(
      messageId = SdsMessageID("sync-1"),
      lamportTimestamp = 42,
      causalHistory = @[],
      channelId = SdsChannelID(channelId),
      content = @[],
      bloomFilter = @[],
    )
    let syncWire = serializeMessage(syncMsg).expect("serialize sync")

    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(
        messageHash: "sync-hash-1", message: sdsWakuMessage(contentTopic, syncWire)
      ),
    )
    await sleepAsync(150.milliseconds)
    check deliveryCount == 0

    let remotePeer =
      ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
    let wire = (
      await remotePeer.wrapOutgoingMessage(
        oneSegment(appPayload), "sync-m1", SdsChannelID(channelId)
      )
    ).expect("wrap")
    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(
        messageHash: "sync-hash-2", message: sdsWakuMessage(contentTopic, wire)
      ),
    )
    let deadline = Moment.now() + 2.seconds
    while Moment.now() < deadline and deliveryCount < 1:
      await sleepAsync(5.milliseconds)
    check deliveryCount == 1

    (await waku.stop()).expect("stop")

  asyncTest "identical payloads get distinct message ids and both deliver":
    ## Identical content sent twice must get distinct message ids and
    ## reach the app twice — not collapse via the SDS duplicate check.
    const
      channelId = ChannelId("sds-unique-id-channel")
      contentTopic = ContentTopic("/reliable-channel/test/unique-id")
    let appPayload = "ok".toBytes()

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    var capturedWires: seq[seq[byte]]
    MessagingSend.replaceProvider(
      brokerCtx,
      proc(envelope: MessageEnvelope): Future[Result[SendResult, string]] {.async.} =
        ## Noop encryption is identity, so the envelope payload IS the SDS wire.
        capturedWires.add(envelope.payload)
        return ok(SendResult.ok(fakeHash("unique-req-" & $capturedWires.len))),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    var deliveries: seq[seq[byte]]
    discard ChannelMessageReceivedEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageReceivedEvent) {.async: (raises: []).} =
          if evt.channelId == channelId:
            deliveries.add(evt.payload)
        ,
      )
      .expect("listen ChannelMessageReceivedEvent")

    ## Send side: the same payload twice must produce two distinct ids.
    discard (await manager.send(channelId, appPayload)).expect("send 1")
    discard (await manager.send(channelId, appPayload)).expect("send 2")
    var deadline = Moment.now() + 2.seconds
    while Moment.now() < deadline and capturedWires.len < 2:
      await sleepAsync(5.milliseconds)
    check capturedWires.len == 2
    let id1 = deserializeMessage(capturedWires[0]).expect("wire 1").messageId
    let id2 = deserializeMessage(capturedWires[1]).expect("wire 2").messageId
    check id1 != id2

    ## Receive side: identical content under distinct ids delivers twice.
    let remotePeer =
      ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
    for i in 1 .. 2:
      let wire = (
        await remotePeer.wrapOutgoingMessage(
          oneSegment(appPayload), "unique-m" & $i, SdsChannelID(channelId)
        )
      ).expect("wrap " & $i)
      waku_message_events.MessageReceivedEvent.emit(
        brokerCtx,
        waku_message_events.MessageReceivedEvent(
          messageHash: "unique-hash-" & $i, message: sdsWakuMessage(contentTopic, wire)
        ),
      )
    deadline = Moment.now() + 2.seconds
    while Moment.now() < deadline and deliveries.len < 2:
      await sleepAsync(5.milliseconds)
    check deliveries.len == 2

    (await waku.stop()).expect("stop")

  asyncTest "manager rejects operations on unknown channels":
    var waku: LogosDelivery
    var manager: ReliableChannelManager
    lockNewGlobalBrokerContext:
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    check (await manager.send(ChannelId("no-such-channel"), "x".toBytes())).isErr()
    check (await manager.closeChannel(ChannelId("no-such-channel"))).isErr()

    (await waku.stop()).expect("stop")

suite "Reliable Channel - content topic subscription":
  asyncTest "channels subscribe on create/start and unsubscribe on close":
    ## Without a subscription `RecvService` drops the channel's inbound traffic.
    const
      preStartChannelId = ChannelId("sub-pre-start-channel")
      preStartTopic = ContentTopic("/reliable-channel/1/sub-pre-start/proto")
      postStartChannelId = ChannelId("sub-post-start-channel")
      postStartTopic = ContentTopic("/reliable-channel/1/sub-post-start/proto")

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    lockNewGlobalBrokerContext:
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

      ## Created before start: subscribed by `ReliableChannelManager.start`.
      discard manager
        .createReliableChannel(
          preStartChannelId, preStartTopic, SdsParticipantID("local")
        )
        .expect("createReliableChannel pre-start")
      check not waku.waku.isSubscribed(preStartTopic).expect("isSubscribed")

      (await waku.start()).expect("start")
      check waku.waku.isSubscribed(preStartTopic).expect("isSubscribed")

      ## Created after start: subscribed immediately.
      discard manager
        .createReliableChannel(
          postStartChannelId, postStartTopic, SdsParticipantID("local")
        )
        .expect("createReliableChannel post-start")
      check waku.waku.isSubscribed(postStartTopic).expect("isSubscribed")

      (await manager.closeChannel(postStartChannelId)).expect("closeChannel post-start")
      check not waku.waku.isSubscribed(postStartTopic).expect("isSubscribed")

      (await manager.closeChannel(preStartChannelId)).expect("closeChannel pre-start")
      check not waku.waku.isSubscribed(preStartTopic).expect("isSubscribed")

    (await waku.stop()).expect("stop")

suite "Reliable Channel - a mix fail-fast reaches the sender":
  asyncTest "a Required send that mix cannot attempt finalises the channel request":
    ## The send service fails a `Required` send that mix cannot attempt with no
    ## network round trip, and `onMessageFinal` ignores an id not yet registered.
    ## This case drives the real `MessagingSend` provider: the order is the subject.
    const
      channelId = ChannelId("mix-failfast-channel")
      contentTopic = ContentTopic("/reliable-channel/1/mix-failfast/proto")

    var waku: LogosDelivery
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (
        await LogosDelivery.new(
          KernelConf(createApiNodeConf().kernel),
          MessagingClientConf(anonymityLevel: Opt.some(AnonymityLevel.Required)),
          ReliableChannelManagerConf(),
        )
      ).expect("LogosDelivery.new")
      (await waku.start()).expect("start")

    discard waku.reliableChannelManager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    let errFut = newFuture[RequestId]("channel-error")
    discard ChannelMessageErrorEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageErrorEvent) {.async: (raises: []).} =
          if not errFut.finished() and evt.channelId == channelId:
            errFut.complete(evt.requestId)
        ,
      )
      .expect("listen ChannelMessageErrorEvent")

    let channelReqId =
      (await waku.reliableChannelManager.send(channelId, "hi".toBytes())).expect("send")

    check await errFut.withTimeout(TestTimeout)
    if errFut.finished():
      check errFut.read() == channelReqId

    (await waku.stop()).expect("stop")

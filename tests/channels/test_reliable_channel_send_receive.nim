{.used.}

import std/[net, os]
from std/times import epochTime
import chronos, testutils/unittests, stew/byteutils
import brokers/broker_context

import ../testlib/[common, wakucore, wakunode, testasync]

import logos_delivery
import logos_delivery/waku/[waku_node, waku_core]
import logos_delivery/waku/factory/waku_conf
import logos_delivery/waku/events/message_events as waku_message_events
import tools/confutils/cli_args

import logos_delivery/channels/reliable_channel_manager
import logos_delivery/channels/encryption/noop_encryption
import logos_delivery/waku/persistency/keys
import logos_delivery/waku/persistency/sds_persistency

## Full nim-sds API: ingress tests act as the remote peer and need
## `wrapOutgoingMessage` to produce real SDS envelopes for the wire.
import sds

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
    ## the MessagingClient emits when a `WakuMessage` arrives off the
    ## wire). The manager must:
    ##   - drop traffic missing the Reliable Channel spec marker
    ##   - dispatch the matching channel's `onMessageReceived`
    ##   - emit `ChannelMessageReceivedEvent` with the payload
    const
      channelId = ChannelId("test-channel")
      contentTopic = ContentTopic("/reliable-channel/test/proto")
    let appPayload = "hello reliable channel".toBytes()

    var waku: Waku
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await createNode(createApiNodeConf())).expect("createNode")
      waku.mountMessagingClient().expect("mountMessagingClient")
      waku.mountReliableChannelManager().expect("mountReliableChannelManager")
      manager = waku.reliableChannelManager

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
    ## wire from a peer: the spec marker on `meta`, the right content
    ## topic, and the payload wrapped in a real SDS envelope by a
    ## stand-in remote peer. The manager's ingress listener should pick
    ## it up, decrypt (noop), unwrap SDS (first message, no missing
    ## dependencies), reassemble (one segment), and finally emit
    ## `ChannelMessageReceivedEvent`.
    let remotePeer =
      ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
    let sdsWire = (
      await remotePeer.wrapOutgoingMessage(
        appPayload, "ingress-test-msg-1", SdsChannelID(channelId)
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
      check received.read() == appPayload

    (await waku.stop()).expect("stop")

  asyncTest "manager drops unmarked WakuMessage":
    ## Mirror of the above: same content topic, but `meta` is empty
    ## (i.e. foreign traffic). The channel-level event must NOT fire.
    const
      channelId = ChannelId("test-channel-2")
      contentTopic = ContentTopic("/reliable-channel/test/proto")
    let appPayload = "foreign payload".toBytes()

    var waku: Waku
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await createNode(createApiNodeConf())).expect("createNode")
      waku.mountMessagingClient().expect("mountMessagingClient")
      waku.mountReliableChannelManager().expect("mountReliableChannelManager")
      manager = waku.reliableChannelManager

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

    (await waku.stop()).expect("stop")

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

    var waku: Waku
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await createNode(createApiNodeConf())).expect("createNode")
      waku.mountMessagingClient().expect("mountMessagingClient")
      waku.mountReliableChannelManager().expect("mountReliableChannelManager")
      manager = waku.reliableChannelManager

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

    let channelReqId = (await manager.send(channelId, "hello".toBytes())).expect("send")

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

    (await waku.stop()).expect("stop")

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

    var waku: Waku
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await createNode(createApiNodeConf())).expect("createNode")
      waku.mountMessagingClient().expect("mountMessagingClient")
      waku.mountReliableChannelManager().expect("mountReliableChannelManager")
      manager = waku.reliableChannelManager

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

    let channelReqId1 =
      (await manager.send(channelId, "first".toBytes())).expect("send 1")
    let channelReqId2 =
      (await manager.send(channelId, "second".toBytes())).expect("send 2")

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

    (await waku.stop()).expect("stop")

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
    ## (PR #3914 review comment r3324891059). Locks in that a sibling
    ## `MessageSentEvent` firing while `onReadyToSend` is paused at an
    ## `await` does not lose the second `channelReqId`'s terminal
    ## event.
    const
      channelId = ChannelId("sm-race-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sm-race")

    var waku: Waku
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await createNode(createApiNodeConf())).expect("createNode")
      waku.mountMessagingClient().expect("mountMessagingClient")
      waku.mountReliableChannelManager().expect("mountReliableChannelManager")
      manager = waku.reliableChannelManager

    setNoopEncryption()

    var msgReqIds: seq[RequestId]
    var sendsReturned = 0
    let fakeSend: SendHandler = proc(
        env: MessageEnvelope
    ): Future[Result[RequestId, string]] {.async: (raises: [CatchableError]), gcsafe.} =
      ## Call 2 fires the first segment's terminal event and then
      ## yields, so the listener task runs while the second segment
      ## is still mid-`await` in `onReadyToSend` — the exact race
      ## window the regression test targets.
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

    let channelReqId1 =
      (await manager.send(channelId, "first".toBytes())).expect("send 1")

    ## Drain the first segment fully before queueing the second, so
    ## the rate-limit FIFO between sibling sends isn't itself under
    ## test here.
    let firstDispatched = Moment.now() + 1.seconds
    while Moment.now() < firstDispatched and msgReqIds.len < 1:
      await sleepAsync(5.milliseconds)
    check msgReqIds.len == 1

    let channelReqId2 =
      (await manager.send(channelId, "second".toBytes())).expect("send 2")

    ## Wait until `fakeSend(m2)` has fully returned and yield once
    ## more so `onReadyToSend`'s post-await continuation gets a chance
    ## to register `id2` in `inflightMessagingIds` before we emit its
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
      waku_message_events.MessageSentEvent(requestId: msgReqIds[1], messageHash: ""),
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
    ## End-to-end durability check for the SDS wiring: with the
    ## process-wide Persistency singleton initialised (as `Waku.start`
    ## does in production), a channel `send` must flush the SDS channel
    ## snapshot (`sds.meta`) and the message-history append (`sds.log`)
    ## through the shared "sds" job. Writes are fire-and-forget (the
    ## Future resolves on enqueue, not apply), so reads poll.
    const
      channelId = ChannelId("sds-persist-channel")
      contentTopic = ContentTopic("/reliable-channel/test/persist")

    Persistency.reset()
    let root = getTempDir() / ("reliable_channel_sds_" & $epochTime().int)
    removeDir(root)
    let persistency = Persistency.instance(root).expect("persistency init")
    defer:
      Persistency.reset()
      removeDir(root)

    var waku: Waku
    var manager: ReliableChannelManager
    lockNewGlobalBrokerContext:
      waku = (await createNode(createApiNodeConf())).expect("createNode")
      waku.mountMessagingClient().expect("mountMessagingClient")
      waku.mountReliableChannelManager().expect("mountReliableChannelManager")
      manager = waku.reliableChannelManager

    setNoopEncryption()

    let fakeSend: SendHandler = proc(
        env: MessageEnvelope
    ): Future[Result[RequestId, string]] {.async: (raises: [CatchableError]), gcsafe.} =
      return ok(RequestId("persist-msg-req-1"))

    discard manager
      .createReliableChannel(
        channelId, contentTopic, SdsParticipantID("local"), sendHandler = fakeSend
      )
      .expect("createReliableChannel")

    discard (await manager.send(channelId, "persist me".toBytes())).expect("send")

    ## Same handle the channel layer writes through (`openJob` is
    ## idempotent per job id).
    let job = persistency.openJob("sds").expect("openJob sds")
    let chanKey = toKey(SdsChannelID(channelId))

    proc pollMetaExists(): Future[bool] {.async.} =
      ## `sds.meta` keeps one blob per channel under the exact channel key.
      let deadline = Moment.now() + 2.seconds
      while Moment.now() < deadline:
        let r = await job.exists(CatMeta, chanKey)
        if r.isOk() and r.get():
          return true
        await sleepAsync(5.milliseconds)
      return false

    proc pollLogRow(): Future[bool] {.async.} =
      ## `sds.log` keys rows by (channelId, messageId) — scan the channel
      ## prefix for the history append of the message just sent.
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

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
    ## Exercises the channel-side state machine in isolation. We
    ## inject a pending entry already in `InFlight` (so we don't have
    ## to drive — and race with — the real send pipeline), then emit
    ## the delivery-layer `MessageSentEvent` for its `messagingReqId`.
    ## The channel's own listener flips the entry to `Confirmed` and,
    ## since it's the only segment for that `channelReqId`, prunes it.
    const
      channelId = ChannelId("sm-success-channel")
      contentTopic = ContentTopic("/reliable-channel/test/sm-success")

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

    let chn = manager.getChannelForTest(channelId)
    doAssert not chn.isNil()
    check chn.pendingMessagingRequestsLenForTest == 0

    let channelReqId = RequestId("test-channel-req")
    let messagingReqId = RequestId("test-msg-req")
    chn.forceInjectInFlightForTest(channelReqId, messagingReqId)
    check chn.pendingMessagingRequestsLenForTest == 1

    waku_message_events.MessageSentEvent.emit(
      brokerCtx,
      waku_message_events.MessageSentEvent(requestId: messagingReqId, messageHash: ""),
    )

    let deadline = Moment.now() + 1.seconds
    while Moment.now() < deadline and chn.pendingMessagingRequestsLenForTest > 0:
      await sleepAsync(5.milliseconds)
    check chn.pendingMessagingRequestsLenForTest == 0

    await manager.stop()

  asyncTest "channelReqId not pruned until ALL its segments are final":
    ## Validates `pruneCompletedChannelReqs`'s "wait for siblings" rule:
    ## a channel request with multiple segments is only dropped once
    ## every segment is `Confirmed` or `Failed`. Confirm the first
    ## segment and assert both entries are still tracked; fail the
    ## second and assert both are pruned.
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
    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    let chn = manager.getChannelForTest(channelId)
    doAssert not chn.isNil()

    let channelReqId = RequestId("multi-channel-req")
    let msgReqId1 = RequestId("multi-msg-req-1")
    let msgReqId2 = RequestId("multi-msg-req-2")
    chn.forceInjectInFlightForTest(channelReqId, msgReqId1)
    chn.forceInjectInFlightForTest(channelReqId, msgReqId2)
    check chn.pendingMessagingRequestsLenForTest == 2

    waku_message_events.MessageSentEvent.emit(
      brokerCtx,
      waku_message_events.MessageSentEvent(requestId: msgReqId1, messageHash: ""),
    )
    await sleepAsync(50.milliseconds)
    ## Sibling msgReqId2 is still `InFlight`, so prune must NOT fire
    ## yet — both entries remain tracked.
    check chn.pendingMessagingRequestsLenForTest == 2

    waku_message_events.MessageErrorEvent.emit(
      brokerCtx,
      waku_message_events.MessageErrorEvent(
        requestId: msgReqId2, messageHash: "", error: "synthetic"
      ),
    )
    let deadline = Moment.now() + 1.seconds
    while Moment.now() < deadline and chn.pendingMessagingRequestsLenForTest > 0:
      await sleepAsync(5.milliseconds)
    check chn.pendingMessagingRequestsLenForTest == 0

    await manager.stop()

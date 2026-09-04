{.used.}

import std/[algorithm, strutils]
import results, chronos, testutils/unittests, stew/byteutils
import brokers/broker_context

import logos_delivery/api/conf/channels_conf
import logos_delivery/api/events/messaging_client_events
import logos_delivery/api/events/reliable_channel_manager_events
import logos_delivery/channels/types
import logos_delivery/channels/segmentation/channel_segmentation
import logos_delivery/channels/reliable_channel_manager
import logos_delivery/channels/api/channel_lifecycle
import logos_delivery/channels/encryption/noop_encryption
import logos_delivery/waku/waku_core

## Stand-in remote peer producing real SDS envelopes.
import sds

proc testPayload(n: int): seq[byte] =
  ## Non-repeating pattern: a payload of identical bytes would reassemble
  ## "correctly" even with its segments in the wrong order.
  var payload = newSeq[byte](n)
  for i in 0 ..< n:
    payload[i] = byte((i * 31 + (i div 251) * 7) and 0xFF)
  return payload

proc testConf(
    parityRate = 0.0,
    segmentSizeBytes = DefaultSegmentSizeBytes,
    maxTotalSegments = DefaultMaxTotalSegments,
    cleanupIntervalSeconds = DefaultSegmentCleanupIntervalSeconds,
    reconstructionTimeoutSeconds = DefaultReconstructionTimeoutSeconds,
    maxSegmentSets = DefaultMaxSegmentSets,
    maxBufferedBytes = DefaultMaxBufferedBytes,
): ReliableChannelManagerConf =
  return ReliableChannelManagerConf(
    segmentationSegmentSizeBytes: Opt.some(segmentSizeBytes),
    segmentationParityRate: Opt.some(parityRate),
    segmentationMaxTotalSegments: Opt.some(maxTotalSegments),
    segmentationCleanupIntervalSeconds: Opt.some(cleanupIntervalSeconds),
    segmentationReconstructionTimeoutSeconds: Opt.some(reconstructionTimeoutSeconds),
    segmentationMaxSegmentSets: Opt.some(maxSegmentSets),
    segmentationMaxBufferedBytes: Opt.some(maxBufferedBytes),
  )

proc newHandler(
    conf: ReliableChannelManagerConf, brokerCtx: BrokerContext
): Result[SegmentationHandler, string] =
  return SegmentationHandler.new(
    ChannelSegmentationConfig.init(conf), ChannelId("seg-test"), brokerCtx
  )

suite "Reliable Channel - segmentation facade":
  asyncTest "a single-chunk payload is wrapped as one segment, not passed through":
    lockNewGlobalBrokerContext:
      let brokerCtx = globalBrokerContext()
      let sender = newHandler(testConf(), brokerCtx).expect("SegmentationHandler.new")
      let receiver = newHandler(testConf(), brokerCtx).expect("SegmentationHandler.new")

      let payload = testPayload(64)
      let segments = sender.performSegmentation(payload).expect("performSegmentation")

      check segments.len == 1
      ## The skeleton's identity codec is gone: the wire unit now carries a
      ## protobuf header around the chunk.
      check segments[0] != payload

      let reassembled =
        receiver.handleIncomingSegment(segments[0]).expect("handleIncomingSegment")
      check reassembled.isSome()
      check reassembled.get().payload == payload
      check reassembled.get().originalPayloadHash.len == 32

  asyncTest "a multi-chunk payload round-trips through a fresh handler":
    lockNewGlobalBrokerContext:
      let brokerCtx = globalBrokerContext()
      let sender = newHandler(testConf(), brokerCtx).expect("SegmentationHandler.new")
      let receiver = newHandler(testConf(), brokerCtx).expect("SegmentationHandler.new")

      let payload = testPayload(3 * sender.chunkSize() + 17)
      let segments = sender.performSegmentation(payload).expect("performSegmentation")
      check segments.len == 4

      for i in 0 ..< segments.len - 1:
        let partial =
          receiver.handleIncomingSegment(segments[i]).expect("handleIncomingSegment")
        check partial.isNone()
        check receiver.pendingSets() == 1

      let reassembled =
        receiver.handleIncomingSegment(segments[^1]).expect("handleIncomingSegment")
      check reassembled.isSome()
      check reassembled.get().payload == payload
      check receiver.pendingSets() == 0

  asyncTest "segments arriving out of order still reassemble":
    lockNewGlobalBrokerContext:
      let brokerCtx = globalBrokerContext()
      let sender = newHandler(testConf(), brokerCtx).expect("SegmentationHandler.new")
      let receiver = newHandler(testConf(), brokerCtx).expect("SegmentationHandler.new")

      let payload = testPayload(4 * sender.chunkSize())
      var segments = sender.performSegmentation(payload).expect("performSegmentation")
      segments.reverse()

      var delivered: seq[byte]
      for segment in segments:
        let res =
          receiver.handleIncomingSegment(segment).expect("handleIncomingSegment")
        if res.isSome():
          delivered = res.get().payload

      check delivered == payload

  asyncTest "a zero parity rate produces no parity segments":
    lockNewGlobalBrokerContext:
      let sender = newHandler(testConf(parityRate = 0.0), globalBrokerContext()).expect(
          "SegmentationHandler.new"
        )
      let payload = testPayload(8 * sender.chunkSize())
      check sender.performSegmentation(payload).expect("performSegmentation").len == 8

  asyncTest "a parity rate adds ceil(rate * dataCount) parity segments":
    lockNewGlobalBrokerContext:
      let sender = newHandler(testConf(parityRate = 0.125), globalBrokerContext())
        .expect("SegmentationHandler.new")
      let payload = testPayload(8 * sender.chunkSize())
      ## 8 data + ceil(0.125 * 8) = 1 parity.
      check sender.performSegmentation(payload).expect("performSegmentation").len == 9

  asyncTest "Reed-Solomon recovers a payload from a lost data segment":
    ## The one test that exercises nim-leopard's decoder end to end.
    lockNewGlobalBrokerContext:
      let brokerCtx = globalBrokerContext()
      let conf = testConf(parityRate = 0.125)
      let sender = newHandler(conf, brokerCtx).expect("SegmentationHandler.new")

      let payload = testPayload(8 * sender.chunkSize())
      let segments = sender.performSegmentation(payload).expect("performSegmentation")
      check segments.len == 9

      ## Drop one data segment; the parity one has to stand in for it.
      let surviving = segments[0 ..< 7] & @[segments[8]]

      let receiver = newHandler(conf, brokerCtx).expect("SegmentationHandler.new")
      var delivered: seq[byte]
      for segment in surviving:
        let res =
          receiver.handleIncomingSegment(segment).expect("handleIncomingSegment")
        if res.isSome():
          delivered = res.get().payload
      check delivered == payload

      ## Negative control: without the parity segment the same seven data
      ## segments must never reassemble, so this cannot pass if parity is a
      ## silent no-op.
      let control = newHandler(conf, brokerCtx).expect("SegmentationHandler.new")
      for segment in segments[0 ..< 7]:
        check control
          .handleIncomingSegment(segment)
          .expect("handleIncomingSegment")
          .isNone()
      check control.pendingSets() == 1

  asyncTest "an oversized payload is rejected with maxTotalSegments in the error":
    lockNewGlobalBrokerContext:
      let conf = testConf(maxTotalSegments = 4)
      let sender =
        newHandler(conf, globalBrokerContext()).expect("SegmentationHandler.new")
      let res = sender.performSegmentation(testPayload(5 * sender.chunkSize()))
      check res.isErr()
      check "maxTotalSegments" in res.error

  asyncTest "undecodable bytes are discarded, not an internal error":
    lockNewGlobalBrokerContext:
      let receiver =
        newHandler(testConf(), globalBrokerContext()).expect("SegmentationHandler.new")
      let res = receiver.handleIncomingSegment(@[0xFF'u8, 0xFF, 0xFF, 0xFF])
      check res.isOk()
      check res.get().isNone()
      check receiver.pendingSets() == 0

  asyncTest "a duplicate segment does not advance the set":
    lockNewGlobalBrokerContext:
      let brokerCtx = globalBrokerContext()
      let sender = newHandler(testConf(), brokerCtx).expect("SegmentationHandler.new")
      let receiver = newHandler(testConf(), brokerCtx).expect("SegmentationHandler.new")

      let segments = sender
        .performSegmentation(testPayload(2 * sender.chunkSize()))
        .expect("performSegmentation")

      check receiver.handleIncomingSegment(segments[0]).expect("first").isNone()
      let buffered = receiver.bufferedBytes()
      check receiver.handleIncomingSegment(segments[0]).expect("duplicate").isNone()
      check receiver.bufferedBytes() == buffered

  asyncTest "config knobs reach the package":
    lockNewGlobalBrokerContext:
      let brokerCtx = globalBrokerContext()
      let default = newHandler(testConf(), brokerCtx).expect("SegmentationHandler.new")
      let smaller = newHandler(testConf(segmentSizeBytes = 1024), brokerCtx).expect(
          "SegmentationHandler.new"
        )
      check smaller.chunkSize() < default.chunkSize()

      ## `maxTotalSegments` bounds what `performSegmentation` will accept.
      let bounded = newHandler(
          testConf(segmentSizeBytes = 1024, maxTotalSegments = 2), brokerCtx
        )
        .expect("SegmentationHandler.new")
      check bounded.performSegmentation(testPayload(2 * bounded.chunkSize())).isOk()
      check bounded.performSegmentation(testPayload(3 * bounded.chunkSize())).isErr()

  asyncTest "maxSegmentSets bounds the concurrent partial sets":
    ## Also the only coverage of a drop reason other than `Expired`.
    lockNewGlobalBrokerContext:
      let brokerCtx = globalBrokerContext()
      let conf = testConf(maxSegmentSets = 1)
      let sender = newHandler(conf, brokerCtx).expect("SegmentationHandler.new")
      let receiver = newHandler(conf, brokerCtx).expect("SegmentationHandler.new")

      let first = sender.performSegmentation(testPayload(2 * sender.chunkSize())).expect(
          "performSegmentation first"
        )
      let second = sender
        .performSegmentation(testPayload(2 * sender.chunkSize() + 1))
        .expect("performSegmentation second")

      check receiver.handleIncomingSegment(first[0]).expect("first").isNone()
      check receiver.pendingSets() == 1

      ## The second payload's set evicts the first, rather than adding to it.
      check receiver.handleIncomingSegment(second[0]).expect("second").isNone()
      check receiver.pendingSets() == 1

      ## The evicted set is gone for good: its remaining segment cannot
      ## complete it.
      check receiver.handleIncomingSegment(first[1]).expect("first rest").isNone()

  asyncTest "maxBufferedBytes caps the reassembly memory held":
    lockNewGlobalBrokerContext:
      let brokerCtx = globalBrokerContext()
      ## The package requires `maxBufferedBytes >= segmentSizeBytes`, so a
      ## budget this tight needs a small segment size to go with it.
      const budget = 1024
      let conf = testConf(segmentSizeBytes = budget, maxBufferedBytes = budget)
      let sender = newHandler(conf, brokerCtx).expect("SegmentationHandler.new")
      let receiver = newHandler(conf, brokerCtx).expect("SegmentationHandler.new")

      let segments = sender
        .performSegmentation(testPayload(4 * sender.chunkSize()))
        .expect("performSegmentation")
      check segments.len == 4

      ## Room for one segment only: the set can never complete, and the bound
      ## holds however many arrive.
      for segment in segments:
        check receiver.handleIncomingSegment(segment).expect("segment").isNone()
        check receiver.bufferedBytes() <= budget

  asyncTest "an invalid config is rejected at construction":
    lockNewGlobalBrokerContext:
      let brokerCtx = globalBrokerContext()

      ## Parity is a fraction, so anything above 1 is meaningless.
      check newHandler(testConf(parityRate = 1.5), brokerCtx).isErr()

      ## Below the package's minimum the chunk size would round down to zero.
      check newHandler(testConf(segmentSizeBytes = 64), brokerCtx).isErr()

      ## A sweep slower than the reconstruction timeout never runs in time.
      check newHandler(
        testConf(reconstructionTimeoutSeconds = 10, cleanupIntervalSeconds = 30),
        brokerCtx,
      )
        .isErr()
      check newHandler(testConf(cleanupIntervalSeconds = 0), brokerCtx).isErr()

  asyncTest "cleanupSegments drops a set that stopped receiving":
    lockNewGlobalBrokerContext:
      let brokerCtx = globalBrokerContext()
      let conf = testConf(reconstructionTimeoutSeconds = 1, cleanupIntervalSeconds = 1)
      let sender = newHandler(conf, brokerCtx).expect("SegmentationHandler.new")
      let receiver = newHandler(conf, brokerCtx).expect("SegmentationHandler.new")

      let segments = sender
        .performSegmentation(testPayload(3 * sender.chunkSize()))
        .expect("performSegmentation")
      check receiver.handleIncomingSegment(segments[0]).expect("first").isNone()
      check receiver.pendingSets() == 1

      await sleepAsync(1500.milliseconds)
      receiver.cleanupSegments()
      check receiver.pendingSets() == 0
      check receiver.bufferedBytes() == 0

suite "Reliable Channel - segmentation over a channel":
  ## Drives the ingress tail (`SDS -> reassemble -> emit`) by emitting the
  ## `MessageReceivedEvent` the MessagingClient raises for a wire message.
  ## A stand-in remote `ReliabilityManager` produces the SDS envelopes.

  proc inbound(sdsWire: seq[byte], contentTopic: ContentTopic): WakuMessage =
    return WakuMessage(
      payload: sdsWire,
      contentTopic: contentTopic,
      version: 0,
      meta: LipWireReliableChannelVersion.toBytes(),
    )

  asyncTest "a multi-segment payload arrives as one ChannelMessageReceivedEvent":
    const
      channelId = ChannelId("seg-multi-channel")
      contentTopic = ContentTopic("/reliable-channel/test/seg-multi/proto")

    var brokerCtx: BrokerContext
    var manager: ReliableChannelManager
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      manager =
        ReliableChannelManager.new(testConf()).expect("ReliableChannelManager.new")
      setNoopEncryption()
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

      let sender = newHandler(testConf(), brokerCtx).expect("SegmentationHandler.new")
      let payload = testPayload(3 * sender.chunkSize() + 5)
      let segments = sender.performSegmentation(payload).expect("performSegmentation")
      check segments.len == 4

      let remotePeer =
        ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
      for i, segment in segments:
        let sdsWire = (
          await remotePeer.wrapOutgoingMessage(
            segment, "seg-multi-" & $i, SdsChannelID(channelId)
          )
        ).expect("wrapOutgoingMessage")
        MessageReceivedEvent.emit(
          brokerCtx,
          MessageReceivedEvent(messageHash: "", message: inbound(sdsWire, contentTopic)),
        )
        ## Yield so the broker dispatches this segment before the next is
        ## emitted; SDS delivers in causal order.
        await sleepAsync(20.milliseconds)

      ## One payload in, one event out -- not one per segment.
      let deadline = Moment.now() + 5.seconds
      while deliveries.len == 0 and Moment.now() < deadline:
        await sleepAsync(20.milliseconds)
      check deliveries == @[payload]
      (await manager.closeChannel(channelId)).expect("closeChannel")

  asyncTest "the cleanup task expires a stale partial set and reports it lost":
    ## The only path that reclaims a partial set once traffic stops, so it
    ## also covers the periodic task started by `ReliableChannel.new`.
    const
      channelId = ChannelId("seg-expiry-channel")
      contentTopic = ContentTopic("/reliable-channel/test/seg-expiry/proto")

    let conf = testConf(reconstructionTimeoutSeconds = 1, cleanupIntervalSeconds = 1)

    var brokerCtx: BrokerContext
    var manager: ReliableChannelManager
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      manager = ReliableChannelManager.new(conf).expect("ReliableChannelManager.new")
      setNoopEncryption()
      discard manager
        .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
        .expect("createReliableChannel")

      let lost = newFuture[ChannelMessageLostEvent]("channel-message-lost")
      discard ChannelMessageLostEvent
        .listen(
          brokerCtx,
          proc(evt: ChannelMessageLostEvent) {.async: (raises: []).} =
            if not lost.finished() and evt.channelId == channelId:
              lost.complete(evt)
          ,
        )
        .expect("listen ChannelMessageLostEvent")

      let sender = newHandler(conf, brokerCtx).expect("SegmentationHandler.new")
      let segments = sender
        .performSegmentation(testPayload(3 * sender.chunkSize()))
        .expect("performSegmentation")

      ## Deliver one segment of four, then go quiet.
      let remotePeer =
        ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
      let sdsWire = (
        await remotePeer.wrapOutgoingMessage(
          segments[0], "seg-expiry-0", SdsChannelID(channelId)
        )
      ).expect("wrapOutgoingMessage")
      MessageReceivedEvent.emit(
        brokerCtx,
        MessageReceivedEvent(messageHash: "", message: inbound(sdsWire, contentTopic)),
      )

      let arrived = await lost.withTimeout(10.seconds)
      check arrived
      if arrived:
        check lost.read().reason == $SegmentSetDropReason.Expired
        check lost.read().payloadHash.len == 32

      (await manager.closeChannel(channelId)).expect("closeChannel")

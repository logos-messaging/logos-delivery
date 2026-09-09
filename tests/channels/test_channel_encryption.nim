{.used.}

import results, std/[net, sequtils, strutils, tables]
import chronos, testutils/unittests, stew/byteutils
import brokers/broker_context

import ../testlib/wakucore

import logos_delivery
import logos_delivery/waku/waku_core
import logos_delivery/waku/factory/waku_conf
import logos_delivery/api/events/messaging_client_events as waku_message_events
import logos_delivery/api/messaging_client_api
import tools/confutils/cli_args
import logos_delivery/api/conf/messaging_conf

import logos_delivery/channels/reliable_channel_manager
import logos_delivery/channels/encryption/channel_encryption

import sds

const TestTimeout = chronos.seconds(15)

proc createApiNodeConf(): WakuNodeConf =
  var conf = MessagingClientConf()
    .toWakuNodeConf(messaging_conf.LogosDeliveryMode.Core).valueOr:
      raiseAssert error
  conf.listenAddress = parseIpAddress("0.0.0.0")
  conf.tcpPort = Port(0)
  conf.discv5UdpPort = Port(0)
  conf.clusterId = Opt.some(3'u16)
  conf.numShardsInNetwork = 1
  conf.rest = false
  return conf

proc oneSegment(payload: seq[byte]): seq[byte] =
  let handler = SegmentationHandler
    .new(
      ChannelSegmentationConfig.init(ReliableChannelManagerConf()),
      ChannelId("test"),
      globalBrokerContext(),
    )
    .expect("SegmentationHandler.new")
  return handler.performSegmentation(payload).expect("performSegmentation")[0]

## Two obviously different ciphers, so a test can tell which one ran and
## whether one channel's key leaked into another's. XOR is its own inverse,
## which keeps the fixtures short.
func xorWith(key: byte): ChannelCryptoFn =
  return proc(
      payload: seq[byte]
  ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
    return ok(payload.mapIt(it xor key))

func failingCrypto(msg: string): ChannelCryptoFn =
  return proc(
      payload: seq[byte]
  ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
    return err(msg)

func cipher(encrypt: ChannelCryptoFn, decrypt: ChannelCryptoFn): Opt[ChannelCrypto] =
  Opt.some(ChannelCrypto.init(encrypt, decrypt).expect("ChannelCrypto.init"))

func passthrough(): ChannelCryptoFn =
  return proc(
      payload: seq[byte]
  ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
    return ok(payload)

func containsRun(haystack, needle: seq[byte]): bool =
  ## Is `needle` present as a contiguous run in `haystack`?
  if needle.len == 0 or needle.len > haystack.len:
    return false
  for start in 0 .. haystack.len - needle.len:
    if haystack[start ..< start + needle.len] == needle:
      return true
  return false

proc encryptedInbound(
    appPayload: seq[byte],
    channelId: ChannelId,
    contentTopic: ContentTopic,
    key: byte,
    messageId: string,
): Future[WakuMessage] {.async.} =
  ## A message as a remote peer puts it on the wire: the segment is XORed
  ## first, then wrapped, so the SDS envelope itself is readable and only
  ## its `content` is ciphertext.
  let remotePeer =
    ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
  let sdsWire = (
    await remotePeer.wrapOutgoingMessage(
      oneSegment(appPayload).mapIt(it xor key), messageId, SdsChannelID(channelId)
    )
  ).expect("wrapOutgoingMessage")

  return WakuMessage(
    payload: sdsWire,
    contentTopic: contentTopic,
    version: 0,
    meta: LipWireReliableChannelVersion.toBytes(),
  )

template setupChannelNode() =
  ## Every test needs a node with the channels layer up, plus the broker
  ## context its channels are bound to.
  var waku {.inject.}: LogosDelivery
  var manager {.inject.}: ReliableChannelManager
  var brokerCtx {.inject.}: BrokerContext
  lockNewGlobalBrokerContext:
    brokerCtx = globalBrokerContext()
    waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
    manager = waku.reliableChannelManager

template captureWire(sink: untyped) =
  ## Stands in for the messaging layer, recording what reaches the wire.
  MessagingSend.replaceProvider(
    brokerCtx,
    proc(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.async.} =
      sink.add(envelope.payload)
      return ok(RequestId("fake-req")),
  ).isOkOr:
    raiseAssert "replaceProvider failed: " & error

suite "Channel encryption - construction":
  test "nil callbacks are rejected":
    let good = xorWith(0x01)
    check ChannelCrypto.init(nil, good).isErr()
    check ChannelCrypto.init(good, nil).isErr()
    check ChannelCrypto.init(nil, nil).isErr()

  test "a constructed pair encrypts with the callbacks it was given":
    let crypto = ChannelCrypto.init(xorWith(0x22), xorWith(0x22)).expect("init")
    let sealed = (waitFor crypto.encrypt(@[@[0x00'u8]])).expect("encrypt")
    check sealed == @[@[0x22'u8]]

suite "Channel encryption - egress":
  asyncTest "send encrypts the segment inside the SDS envelope":
    ## Encryption happens before the SDS wrap, so the ciphertext travels as
    ## the SDS `content` field: the envelope itself stays readable.
    const
      channelId = ChannelId("enc-send-channel")
      contentTopic = ContentTopic("/reliable-channel/test/enc-send")
    let appPayload = "encrypt me".toBytes()

    setupChannelNode()

    var wire: seq[seq[byte]]
    captureWire(wire)

    ## Record what the cipher was handed, so the wire can be checked against
    ## it rather than against a tautology.
    var seen: seq[seq[byte]]
    let recordingXor = proc(
        payload: seq[byte]
    ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
      seen.add(payload)
      return ok(payload.mapIt(it xor 0xFF'u8))

    discard manager
      .createReliableChannel(
        channelId,
        contentTopic,
        SdsParticipantID("local"),
        cipher(recordingXor, xorWith(0xFF)),
      )
      .expect("createReliableChannel")

    discard (await manager.send(channelId, appPayload)).expect("send")

    let deadline = Moment.now() + 1.seconds
    while Moment.now() < deadline and wire.len == 0:
      await sleepAsync(5.milliseconds)

    check wire.len == 1
    check seen.len == 1
    if wire.len == 1 and seen.len == 1:
      # The cipher saw the plaintext segment; the wire carries its output and
      # not the segment itself.
      check seen[0] == oneSegment(appPayload)
      check wire[0].containsRun(seen[0].mapIt(it xor 0xFF'u8))
      check not wire[0].containsRun(seen[0])

    (await waku.stop()).expect("stop")

  asyncTest "a failing encrypt aborts the send with nothing on the wire":
    ## Fail closed: this is the property the whole design exists to hold.
    ## Encryption runs before the wrap, so the failure aborts `send` itself.
    const
      channelId = ChannelId("enc-fail-channel")
      contentTopic = ContentTopic("/reliable-channel/test/enc-fail")

    setupChannelNode()

    var sendCalls = 0
    MessagingSend.replaceProvider(
      brokerCtx,
      proc(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.async.} =
        sendCalls.inc
        return ok(RequestId("fake-req")),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    discard manager
      .createReliableChannel(
        channelId,
        contentTopic,
        SdsParticipantID("local"),
        cipher(failingCrypto("no key today"), passthrough()),
      )
      .expect("createReliableChannel")

    let res = await manager.send(channelId, "secret".toBytes())
    check res.isErr()
    if res.isErr():
      check "no key today" in res.error
    check sendCalls == 0

    (await waku.stop()).expect("stop")

  asyncTest "an unregistered channel sends its payload unchanged":
    ## Back-compat with the removed noop providers.
    const
      channelId = ChannelId("enc-plain-channel")
      contentTopic = ContentTopic("/reliable-channel/test/enc-plain")

    setupChannelNode()

    var plainWire: seq[seq[byte]]
    captureWire(plainWire)

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")
    discard (await manager.send(channelId, "in the clear".toBytes())).expect("send")

    let deadline = Moment.now() + 1.seconds
    while Moment.now() < deadline and plainWire.len == 0:
      await sleepAsync(5.milliseconds)
    check plainWire.len == 1

    (await waku.stop()).expect("stop")
suite "Channel encryption - ingress":
  asyncTest "receive decrypts the SDS content field":
    const
      channelId = ChannelId("dec-channel")
      contentTopic = ContentTopic("/reliable-channel/test/dec")
    let appPayload = "decrypt me".toBytes()

    setupChannelNode()

    discard manager
      .createReliableChannel(
        channelId,
        contentTopic,
        SdsParticipantID("local"),
        cipher(xorWith(0x3C), xorWith(0x3C)),
      )
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

    ## The remote peer encrypts the segment and then wraps it, exactly as
    ## the egress pipeline does; the SDS envelope itself is in the clear.
    let inbound = await encryptedInbound(
      appPayload, channelId, contentTopic, 0x3C, "dec-test-msg-1"
    )
    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(messageHash: "", message: inbound),
    )

    check await received.withTimeout(TestTimeout)
    check received.read().payload == appPayload

    (await waku.stop()).expect("stop")

  asyncTest "the wrong key raises ChannelMessageLostEvent":
    ## SDS routes by the cleartext channelId before anything is decrypted,
    ## so a decrypt failure is unambiguously a bad key -- not another
    ## channel's traffic -- and is worth telling the application about.
    const
      channelId = ChannelId("dec-badkey-channel")
      contentTopic = ContentTopic("/reliable-channel/test/dec-badkey")

    setupChannelNode()

    ## Registered with a key the sender did not use.
    discard manager
      .createReliableChannel(
        channelId,
        contentTopic,
        SdsParticipantID("local"),
        cipher(xorWith(0x11), failingCrypto("bad key")),
      )
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

    let inbound = await encryptedInbound(
      "for another key".toBytes(), channelId, contentTopic, 0x99, "badkey-msg-1"
    )
    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(messageHash: "0xabc", message: inbound),
    )

    check await lost.withTimeout(TestTimeout)
    if lost.finished():
      check "decryption failed" in lost.read().reason
      check "bad key" in lost.read().reason

    (await waku.stop()).expect("stop")

  asyncTest "a channel ignores another channel's traffic before decrypting":
    ## Two channels on one content topic. SDS drops the foreign channelId,
    ## so the other channel never even reaches its cipher.
    const
      channelA = ChannelId("cross-channel-a")
      channelB = ChannelId("cross-channel-b")
      contentTopic = ContentTopic("/reliable-channel/test/cross")
    let appPayload = "for A only".toBytes()

    setupChannelNode()

    var bCipherCalls = 0
    let countingB = proc(
        payload: seq[byte]
    ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
      bCipherCalls.inc()
      return ok(payload.mapIt(it xor 0xBB'u8))

    discard manager
      .createReliableChannel(
        channelA,
        contentTopic,
        SdsParticipantID("local"),
        cipher(xorWith(0xAA), xorWith(0xAA)),
      )
      .expect("create A")
    discard manager
      .createReliableChannel(
        channelB, contentTopic, SdsParticipantID("local"), cipher(countingB, countingB)
      )
      .expect("create B")

    var deliveredTo: seq[ChannelId]
    discard ChannelMessageReceivedEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageReceivedEvent) {.async: (raises: []).} =
          deliveredTo.add(evt.channelId),
      )
      .expect("listen ChannelMessageReceivedEvent")

    let inbound = await encryptedInbound(
      appPayload, channelA, contentTopic, 0xAA, "cross-test-msg-1"
    )
    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(messageHash: "", message: inbound),
    )

    let deadline = Moment.now() + 2.seconds
    while Moment.now() < deadline and deliveredTo.len == 0:
      await sleepAsync(10.milliseconds)
    await sleepAsync(200.milliseconds)

    check deliveredTo == @[channelA]
    check bCipherCalls == 0 # B never got as far as its cipher

    (await waku.stop()).expect("stop")

  asyncTest "a suspending cipher cannot reorder concurrent arrivals":
    ## Decryption happens per deliverable, so the drain loop awaits -- and
    ## SDS releases its own lock before returning. Without the channel's
    ## ingress lock a fast second arrival would overtake a parked first one
    ## and the app would see them out of causal order.
    const
      channelId = ChannelId("order-channel")
      contentTopic = ContentTopic("/reliable-channel/test/order")
    let
      first = "first".toBytes()
      second = "second".toBytes()

    setupChannelNode()

    ## Parks the first decrypt; every later call returns at once, so the
    ## second message is the one that would win a race.
    let gate = newFuture[void]("first-decrypt-gate")
    var decryptCalls = 0
    let gatedDecrypt = proc(
        payload: seq[byte]
    ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
      decryptCalls.inc()
      if decryptCalls == 1:
        try:
          await gate
        except CatchableError:
          discard
      return ok(payload.mapIt(it xor 0x2F'u8))

    discard manager
      .createReliableChannel(
        channelId,
        contentTopic,
        SdsParticipantID("local"),
        cipher(xorWith(0x2F), gatedDecrypt),
      )
      .expect("createReliableChannel")

    var delivered: seq[seq[byte]]
    discard ChannelMessageReceivedEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageReceivedEvent) {.async: (raises: []).} =
          if evt.channelId == channelId:
            delivered.add(evt.payload)
        ,
      )
      .expect("listen ChannelMessageReceivedEvent")

    let inboundFirst =
      await encryptedInbound(first, channelId, contentTopic, 0x2F, "order-msg-1")
    let inboundSecond =
      await encryptedInbound(second, channelId, contentTopic, 0x2F, "order-msg-2")

    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(messageHash: "", message: inboundFirst),
    )
    ## Let the first handler reach the gate; it holds the ingress lock there.
    await sleepAsync(100.milliseconds)

    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(messageHash: "", message: inboundSecond),
    )
    await sleepAsync(200.milliseconds)

    ## The discriminating assertion: unserialised, the second message would
    ## already have decrypted and been reported by now.
    check delivered.len == 0

    gate.complete()
    await sleepAsync(300.milliseconds)
    check delivered == @[first, second]

    (await waku.stop()).expect("stop")

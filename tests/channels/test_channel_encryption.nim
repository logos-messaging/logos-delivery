{.used.}

import results, std/[sequtils, strutils, tables]
import chronos, testutils/unittests, stew/byteutils
import brokers/broker_context

import ../testlib/[wakucore, wakunodeconf]

import logos_delivery
import logos_delivery/waku/waku_core
import logos_delivery/api/events/messaging_client_events as waku_message_events
import logos_delivery/api/messaging_client_api

import logos_delivery/channels/reliable_channel_manager
import logos_delivery/channels/encryption/channel_encryption

import sds

const TestTimeout = chronos.seconds(15)

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

## An authenticated toy cipher: the key byte prefix is the "tag", so the
## wrong key fails to open instead of yielding garbage, as AEAD would.
func sealWith(key: byte): ChannelCryptoFn =
  return proc(
      payload: seq[byte]
  ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
    return ok(@[key] & payload.mapIt(it xor key))

func openWith(key: byte): ChannelCryptoFn =
  return proc(
      payload: seq[byte]
  ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
    if payload.len == 0 or payload[0] != key:
      return err("not sealed with this key")
    return ok(payload[1 ..^ 1].mapIt(it xor key))

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
    seal: ChannelCryptoFn,
    messageId: string,
): Future[WakuMessage] {.async.} =
  ## A message as a remote peer puts it on the wire: the segment is wrapped
  ## first, then the whole SDS message is sealed.
  let remotePeer =
    ReliabilityManager.new(SdsParticipantID("remote"), ReliabilityConfig.init())
  let sdsWire = (
    await remotePeer.wrapOutgoingMessage(
      oneSegment(appPayload), messageId, SdsChannelID(channelId)
    )
  ).expect("wrapOutgoingMessage")

  return WakuMessage(
    payload: (await seal(sdsWire)).expect("seal"),
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
    waku =
      (await LogosDelivery.new(defaultTestWakuNodeConf())).expect("LogosDelivery.new")
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
  asyncTest "send encrypts the whole SDS message":
    ## Encryption happens after the SDS wrap, so the envelope's routing
    ## metadata never reaches the wire in the clear.
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
      # The cipher saw the SDS message carrying the segment; the wire is
      # exactly its output, with neither the segment nor the channelId.
      check seen[0].containsRun(oneSegment(appPayload))
      check seen[0].containsRun(string(channelId).toBytes())
      check wire[0] == seen[0].mapIt(it xor 0xFF'u8)
      check not wire[0].containsRun(oneSegment(appPayload))
      check not wire[0].containsRun(string(channelId).toBytes())

    (await waku.stop()).expect("stop")

  asyncTest "a failing encrypt aborts the send with nothing on the wire":
    ## Fail closed: this is the property the whole design exists to hold.
    ## Every segment is encrypted before any is dispatched, so the failure
    ## aborts `send` itself.
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
  asyncTest "receive decrypts the whole SDS message":
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

    let inbound = await encryptedInbound(
      appPayload, channelId, contentTopic, xorWith(0x3C), "dec-test-msg-1"
    )
    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(messageHash: "", message: inbound),
    )

    check await received.withTimeout(TestTimeout)
    check received.read().payload == appPayload

    (await waku.stop()).expect("stop")

  asyncTest "a message that does not decrypt is dropped without an event":
    ## On a shared topic, failing to decrypt is how a channel recognises
    ## traffic that is not its own, so it is routine rather than an error.
    const
      channelId = ChannelId("dec-badkey-channel")
      contentTopic = ContentTopic("/reliable-channel/test/dec-badkey")

    setupChannelNode()

    discard manager
      .createReliableChannel(
        channelId,
        contentTopic,
        SdsParticipantID("local"),
        cipher(sealWith(0x11), openWith(0x11)),
      )
      .expect("createReliableChannel")

    var events: seq[string]
    discard ChannelMessageReceivedEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageReceivedEvent) {.async: (raises: []).} =
          events.add("received"),
      )
      .expect("listen ChannelMessageReceivedEvent")
    discard ChannelMessageLostEvent
      .listen(
        brokerCtx,
        proc(evt: ChannelMessageLostEvent) {.async: (raises: []).} =
          events.add("lost"),
      )
      .expect("listen ChannelMessageLostEvent")
    discard MessageErrorEvent
      .listen(
        brokerCtx,
        proc(evt: MessageErrorEvent) {.async: (raises: []).} =
          events.add("error"),
      )
      .expect("listen MessageErrorEvent")

    let inbound = await encryptedInbound(
      "for another key".toBytes(),
      channelId,
      contentTopic,
      sealWith(0x99),
      "badkey-msg-1",
    )
    waku_message_events.MessageReceivedEvent.emit(
      brokerCtx,
      waku_message_events.MessageReceivedEvent(messageHash: "0xabc", message: inbound),
    )
    await sleepAsync(300.milliseconds)

    check events.len == 0

    (await waku.stop()).expect("stop")

  asyncTest "channels sharing a topic tell their traffic apart by decrypting":
    ## The SDS channelId is sealed, so each channel trial-decrypts and only
    ## the one holding the key accepts the message.
    const
      channelA = ChannelId("cross-channel-a")
      channelB = ChannelId("cross-channel-b")
      contentTopic = ContentTopic("/reliable-channel/test/cross")
    let appPayload = "for A only".toBytes()

    setupChannelNode()

    var bRejected = 0
    let countingOpenB = proc(
        payload: seq[byte]
    ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
      let opened = await openWith(0xBB)(payload)
      if opened.isErr():
        bRejected.inc()
      return opened

    discard manager
      .createReliableChannel(
        channelA,
        contentTopic,
        SdsParticipantID("local"),
        cipher(sealWith(0xAA), openWith(0xAA)),
      )
      .expect("create A")
    discard manager
      .createReliableChannel(
        channelB,
        contentTopic,
        SdsParticipantID("local"),
        cipher(sealWith(0xBB), countingOpenB),
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
      appPayload, channelA, contentTopic, sealWith(0xAA), "cross-test-msg-1"
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
    check bRejected == 1

    (await waku.stop()).expect("stop")

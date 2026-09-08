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

suite "Channel encryption - registry":
  test "set, get and clear round-trip":
    let reg = ChannelEncryptionRegistry.new()
    const channelId = ChannelId("reg-channel")

    check reg.getChannelCrypto(channelId).isNone()

    reg.setChannelEncryption(channelId, xorWith(0x5A), xorWith(0x5A)).expect("set")
    check reg.getChannelCrypto(channelId).isSome()

    reg.clearChannelEncryption(channelId).expect("clear")
    check reg.getChannelCrypto(channelId).isNone()

  test "clearing an unregistered channel is an error":
    let reg = ChannelEncryptionRegistry.new()
    check reg.clearChannelEncryption(ChannelId("never-registered")).isErr()

  test "nil callbacks are rejected":
    let reg = ChannelEncryptionRegistry.new()
    const channelId = ChannelId("nil-channel")
    let good = xorWith(0x01)

    check reg.setChannelEncryption(channelId, nil, good).isErr()
    check reg.setChannelEncryption(channelId, good, nil).isErr()
    check reg.setChannelEncryption(channelId, nil, nil).isErr()

    ## A rejected registration must leave nothing behind, or the channel
    ## would look encrypted while holding a callback it cannot call.
    check reg.getChannelCrypto(channelId).isNone()

  test "re-registering replaces the previous pair":
    let reg = ChannelEncryptionRegistry.new()
    const channelId = ChannelId("replace-channel")

    reg.setChannelEncryption(channelId, xorWith(0x11), xorWith(0x11)).expect("set")
    reg.setChannelEncryption(channelId, xorWith(0x22), xorWith(0x22)).expect("replace")

    let crypto = reg.getChannelCrypto(channelId).expect("registered")
    let sealed = (waitFor crypto.encryptFn()(@[0x00'u8])).expect("encrypt")
    check sealed == @[0x22'u8]

suite "Channel encryption - egress":
  asyncTest "send encrypts the segment inside the SDS envelope":
    ## Encryption happens before the SDS wrap, so the ciphertext travels as
    ## the SDS `content` field: the envelope itself stays readable.
    const
      channelId = ChannelId("enc-send-channel")
      contentTopic = ContentTopic("/reliable-channel/test/enc-send")
    let appPayload = "encrypt me".toBytes()

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    var wire: seq[seq[byte]]
    MessagingSend.replaceProvider(
      brokerCtx,
      proc(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.async.} =
        wire.add(envelope.payload)
        return ok(RequestId("fake-req")),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    ## Record what the cipher was handed, so the wire can be checked against
    ## it rather than against a tautology.
    var seen: seq[seq[byte]]
    let recordingXor = proc(
        payload: seq[byte]
    ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
      seen.add(payload)
      return ok(payload.mapIt(it xor 0xFF'u8))

    manager.setChannelEncryption(channelId, recordingXor, xorWith(0xFF)).expect(
      "setChannelEncryption"
    )
    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
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
      proc(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.async.} =
        sendCalls.inc
        return ok(RequestId("fake-req")),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    manager
      .setChannelEncryption(channelId, failingCrypto("no key today"), passthrough())
      .expect("setChannelEncryption")
    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
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

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    var plainWire: seq[seq[byte]]
    MessagingSend.replaceProvider(
      brokerCtx,
      proc(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.async.} =
        plainWire.add(envelope.payload)
        return ok(RequestId("fake-req")),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")
    discard (await manager.send(channelId, "in the clear".toBytes())).expect("send")

    let deadline = Moment.now() + 1.seconds
    while Moment.now() < deadline and plainWire.len == 0:
      await sleepAsync(5.milliseconds)
    check plainWire.len == 1

    (await waku.stop()).expect("stop")
  asyncTest "clearing mid-send does not downgrade the remaining segments":
    ## The cipher is resolved once per `send`, so a concurrent clear cannot
    ## push the tail of a multi-segment message out in the clear.
    const
      channelId = ChannelId("enc-midsend-channel")
      contentTopic = ContentTopic("/reliable-channel/test/enc-midsend")

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    var wire: seq[seq[byte]]
    MessagingSend.replaceProvider(
      brokerCtx,
      proc(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.async.} =
        wire.add(envelope.payload)
        return ok(RequestId("fake-req")),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    ## Clears its own registration on the first segment, then keeps
    ## encrypting: every segment must still come out ciphered.
    var calls = 0
    let clearingXor = proc(
        payload: seq[byte]
    ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
      calls.inc()
      if calls == 1:
        discard manager.clearChannelEncryption(channelId)
      return ok(payload.mapIt(it xor 0x5A'u8))

    manager.setChannelEncryption(channelId, clearingXor, xorWith(0x5A)).expect(
      "setChannelEncryption"
    )
    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    ## Large enough to segment; the default chunk size is well under this.
    let bigPayload = newSeq[byte](200_000)
    discard (await manager.send(channelId, bigPayload)).expect("send")

    let deadline = Moment.now() + 2.seconds
    while Moment.now() < deadline and wire.len < calls:
      await sleepAsync(5.milliseconds)

    check calls > 1 # otherwise the test proves nothing
    check wire.len == calls

    (await waku.stop()).expect("stop")
  asyncTest "SDS repair rebroadcasts replay the wire verbatim":
    ## The SDS buffer already holds ciphertext in its `content` field, so a
    ## repair must not re-enter the cipher -- and cannot leak plaintext even
    ## after the cipher is cleared.
    const
      channelId = ChannelId("enc-repair-channel")
      contentTopic = ContentTopic("/reliable-channel/test/enc-repair")
    let repairWire = "an already-wrapped sds message".toBytes()

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    var wire: seq[seq[byte]]
    MessagingSend.replaceProvider(
      brokerCtx,
      proc(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.async.} =
        wire.add(envelope.payload)
        return ok(RequestId("fake-req")),
    ).isOkOr:
      raiseAssert "replaceProvider failed: " & error

    var cipherCalls = 0
    let countingXor = proc(
        payload: seq[byte]
    ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
      cipherCalls.inc()
      return ok(payload.mapIt(it xor 0x6B'u8))

    manager.setChannelEncryption(channelId, countingXor, countingXor).expect(
      "setChannelEncryption"
    )
    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    let chn = manager.channels.getOrDefault(channelId)
    check not chn.isNil()
    if not chn.isNil():
      ## Drive a repair rebroadcast the way SDS's own loop does.
      await chn.dispatchRepairForTest(repairWire)
      await sleepAsync(100.milliseconds)

      check wire.len == 1
      check cipherCalls == 0
      if wire.len == 1:
        check wire[0] == repairWire

    (await waku.stop()).expect("stop")

suite "Channel encryption - ingress":
  asyncTest "receive decrypts the SDS content field":
    const
      channelId = ChannelId("dec-channel")
      contentTopic = ContentTopic("/reliable-channel/test/dec")
    let appPayload = "decrypt me".toBytes()

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    manager.setChannelEncryption(channelId, xorWith(0x3C), xorWith(0x3C)).expect(
      "setChannelEncryption"
    )
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

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    ## Registered with a key the sender did not use.
    manager
      .setChannelEncryption(channelId, xorWith(0x11), failingCrypto("bad key"))
      .expect("setChannelEncryption")
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

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    var brokerCtx: BrokerContext
    lockNewGlobalBrokerContext:
      brokerCtx = globalBrokerContext()
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    var bCipherCalls = 0
    let countingB = proc(
        payload: seq[byte]
    ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
      bCipherCalls.inc()
      return ok(payload.mapIt(it xor 0xBB'u8))

    manager.setChannelEncryption(channelA, xorWith(0xAA), xorWith(0xAA)).expect("set A")
    manager.setChannelEncryption(channelB, countingB, countingB).expect("set B")
    discard manager
      .createReliableChannel(channelA, contentTopic, SdsParticipantID("local"))
      .expect("create A")
    discard manager
      .createReliableChannel(channelB, contentTopic, SdsParticipantID("local"))
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

suite "Channel encryption - lifetime":
  asyncTest "closeChannel keeps the registration, manager stop drops it":
    ## closeChannel is reversible, so a re-created channel must not come
    ## back up in the clear.
    const
      channelId = ChannelId("lifetime-channel")
      contentTopic = ContentTopic("/reliable-channel/test/lifetime")

    var waku: LogosDelivery
    var manager: ReliableChannelManager
    lockNewGlobalBrokerContext:
      waku = (await LogosDelivery.new(createApiNodeConf())).expect("LogosDelivery.new")
      manager = waku.reliableChannelManager

    manager.setChannelEncryption(channelId, xorWith(0x77), xorWith(0x77)).expect("set")
    discard manager
      .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
      .expect("createReliableChannel")

    (await manager.closeChannel(channelId)).expect("closeChannel")
    check manager.encryption.getChannelCrypto(channelId).isSome()

    await manager.stop()
    check manager.encryption.getChannelCrypto(channelId).isNone()

    (await waku.stop()).expect("stop")

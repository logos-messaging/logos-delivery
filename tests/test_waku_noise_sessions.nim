{.used.}

import std/tables, results, stew/byteutils, testutils/unittests
import
  logos_delivery/waku/[
    common/protobuf,
    utils/noise as waku_message_utils,
    waku_noise/noise_types,
    waku_noise/noise_utils,
    waku_noise/noise_handshake_processing,
    waku_core,
  ],
  ./testlib/common

procSuite "Waku Noise Sessions":
  randomize()

  # This test implements the Device pairing and Secure Transfers with Noise
  # detailed in the 43/WAKU2-DEVICE-PAIRING RFC https://rfc.vac.dev/spec/43/
  test "Noise Waku Pairing Handhshake and Secure transfer":
    #########################
    # Pairing Phase
    #########################

    let hsPattern = NoiseHandshakePatterns["WakuPairing"]

    # Alice static/ephemeral key initialization and commitment
    let aliceStaticKey = genKeyPair(rng[])
    let aliceEphemeralKey = genKeyPair(rng[])
    let s = randomSeqByte(rng[], 32)
    let aliceCommittedStaticKey = commitPublicKey(getPublicKey(aliceStaticKey), s)

    # Bob static/ephemeral key initialization and commitment
    let bobStaticKey = genKeyPair(rng[])
    let bobEphemeralKey = genKeyPair(rng[])
    let r = randomSeqByte(rng[], 32)
    let bobCommittedStaticKey = commitPublicKey(getPublicKey(bobStaticKey), r)

    # Content Topic information
    let applicationName = "waku-noise-sessions"
    let applicationVersion = "0.1"
    let shardId = "10"
    let qrMessageNametag = randomSeqByte(rng[], MessageNametagLength)

    # Out-of-band Communication

    # Bob prepares the QR and sends it out-of-band to Alice
    let qr = toQr(
      applicationName,
      applicationVersion,
      shardId,
      getPublicKey(bobEphemeralKey),
      bobCommittedStaticKey,
    )

    # Alice deserializes the QR code
    let (
      readApplicationName, readApplicationVersion, readShardId, readEphemeralKey,
      readCommittedStaticKey,
    ) = fromQr(qr)

    # We check if QR serialization/deserialization works
    check:
      applicationName == readApplicationName
      applicationVersion == readApplicationVersion
      shardId == readShardId
      getPublicKey(bobEphemeralKey) == readEphemeralKey
      bobCommittedStaticKey == readCommittedStaticKey

    # We set the contentTopic from the content topic parameters exchanged in the QR
    let contentTopic: ContentTopic =
      "/" & applicationName & "/" & applicationVersion & "/wakunoise/1/sessions_shard-" &
      shardId & "/proto"

    ###############
    # Pre-handshake message
    #
    # <- eB {H(sB||r), contentTopicParams, messageNametag}
    ###############
    let preMessagePKs: seq[NoisePublicKey] =
      @[toNoisePublicKey(getPublicKey(bobEphemeralKey))]

    # We initialize the Handshake states.
    # Note that we pass the whole qr serialization as prologue information
    var aliceHS = initialize(
      hsPattern = hsPattern,
      ephemeralKey = aliceEphemeralKey,
      staticKey = aliceStaticKey,
      prologue = qr.toBytes,
      preMessagePKs = preMessagePKs,
      initiator = true,
    )
    var bobHS = initialize(
      hsPattern = hsPattern,
      ephemeralKey = bobEphemeralKey,
      staticKey = bobStaticKey,
      prologue = qr.toBytes,
      preMessagePKs = preMessagePKs,
    )

    ###############
    # Pairing Handshake
    ###############

    var
      sentTransportMessage: seq[byte]
      aliceStep, bobStep: HandshakeStepResult
      msgFromPb: ProtobufResult[WakuMessage]
      wakuMsg: Result[WakuMessage, cstring]
      pb: ProtoBuffer
      readPayloadV2: PayloadV2
      aliceMessageNametag, bobMessageNametag: MessageNametag

    # Write and read calls alternate between Alice and Bob: the handhshake progresses by alternatively calling stepHandshake for each user

    ###############
    # 1st step
    #
    # -> eA, eAeB   {H(sA||s)}   [authcode]
    ###############

    # The messageNametag for the first handshake message is randomly generated and exchanged out-of-band
    # and corresponds to qrMessageNametag

    # We set the transport message to be H(sA||s)
    sentTransportMessage = digestToSeq(aliceCommittedStaticKey)

    # We ensure that digestToSeq and its inverse seqToDigest256 are correct
    check:
      seqToDigest256(sentTransportMessage) == aliceCommittedStaticKey

    # By being the handshake initiator, Alice writes a Waku2 payload v2 containing her handshake message
    # and the (encrypted) transport message
    # The message is sent with a messageNametag equal to the one received through the QR code
    aliceStep = stepHandshake(
        rng[],
        aliceHS,
        transportMessage = sentTransportMessage,
        messageNametag = qrMessageNametag,
      )
      .get()

    ###############################################
    # We prepare a Waku message from Alice's payload2
    wakuMsg = encodePayloadV2(aliceStep.payload2, contentTopic)

    check:
      wakuMsg.isOk()
      wakuMsg.get().contentTopic == contentTopic

    # At this point wakuMsg is sent over the Waku network and is received
    # We simulate this by creating the ProtoBuffer from wakuMsg
    pb = wakuMsg.get().encode()

    # We decode the WakuMessage from the ProtoBuffer
    msgFromPb = WakuMessage.decode(pb.buffer)

    check:
      msgFromPb.isOk()

    # We decode the payloadV2 from the WakuMessage
    readPayloadV2 = decodePayloadV2(msgFromPb.get()).get()

    check:
      readPayloadV2 == aliceStep.payload2
    ###############################################

    # Bob reads Alice's payloads, and returns the (decrypted) transport message Alice sent to him
    # Note that Bob verifies if the received payloadv2 has the expected messageNametag set
    bobStep = stepHandshake(
        rng[], bobHS, readPayloadV2 = readPayloadV2, messageNametag = qrMessageNametag
      )
      .get()

    check:
      bobStep.transportMessage == sentTransportMessage

    # We generate an authorization code using the handshake state
    let aliceAuthcode = genAuthcode(aliceHS)
    let bobAuthcode = genAuthcode(bobHS)

    # We check that they are equal. Note that this check has to be confirmed with a user interaction.
    check:
      aliceAuthcode == bobAuthcode

    ###############
    # 2nd step
    #
    # <- sB, eAsB    {r}
    ###############

    # Alice and Bob update their local next messageNametag using the available handshake information
    # During the handshake, messageNametag = HKDF(h), where h is the handshake hash value at the end of the last processed message
    aliceMessageNametag = toMessageNametag(aliceHS)
    bobMessageNametag = toMessageNametag(bobHS)

    # We set as a transport message the commitment randomness r
    sentTransportMessage = r

    # At this step, Bob writes and returns a payload
    bobStep = stepHandshake(
        rng[],
        bobHS,
        transportMessage = sentTransportMessage,
        messageNametag = bobMessageNametag,
      )
      .get()

    ###############################################
    # We prepare a Waku message from Bob's payload2
    wakuMsg = encodePayloadV2(bobStep.payload2, contentTopic)

    check:
      wakuMsg.isOk()
      wakuMsg.get().contentTopic == contentTopic

    # At this point wakuMsg is sent over the Waku network and is received
    # We simulate this by creating the ProtoBuffer from wakuMsg
    pb = wakuMsg.get().encode()

    # We decode the WakuMessage from the ProtoBuffer
    msgFromPb = WakuMessage.decode(pb.buffer)

    check:
      msgFromPb.isOk()

    # We decode the payloadV2 from the WakuMessage
    readPayloadV2 = decodePayloadV2(msgFromPb.get()).get()

    check:
      readPayloadV2 == bobStep.payload2
    ###############################################

    # While Alice reads and returns the (decrypted) transport message
    aliceStep = stepHandshake(
        rng[],
        aliceHS,
        readPayloadV2 = readPayloadV2,
        messageNametag = aliceMessageNametag,
      )
      .get()

    check:
      aliceStep.transportMessage == sentTransportMessage

    # Alice further checks if Bob's commitment opens to Bob's static key she just received
    let expectedBobCommittedStaticKey =
      commitPublicKey(aliceHS.rs, aliceStep.transportMessage)

    check:
      expectedBobCommittedStaticKey == bobCommittedStaticKey

    ###############
    # 3rd step
    #
    # -> sA, sAeB, sAsB  {s}
    ###############

    # Alice and Bob update their local next messageNametag using the available handshake information
    aliceMessageNametag = toMessageNametag(aliceHS)
    bobMessageNametag = toMessageNametag(bobHS)

    # We set as a transport message the commitment randomness s
    sentTransportMessage = s

    # Similarly as in first step, Alice writes a Waku2 payload containing the handshake message and the (encrypted) transport message
    aliceStep = stepHandshake(
        rng[],
        aliceHS,
        transportMessage = sentTransportMessage,
        messageNametag = aliceMessageNametag,
      )
      .get()

    ###############################################
    # We prepare a Waku message from Bob's payload2
    wakuMsg = encodePayloadV2(aliceStep.payload2, contentTopic)

    check:
      wakuMsg.isOk()
      wakuMsg.get().contentTopic == contentTopic

    # At this point wakuMsg is sent over the Waku network and is received
    # We simulate this by creating the ProtoBuffer from wakuMsg
    pb = wakuMsg.get().encode()

    # We decode the WakuMessage from the ProtoBuffer
    msgFromPb = WakuMessage.decode(pb.buffer)

    check:
      msgFromPb.isOk()

    # We decode the payloadV2 from the WakuMessage
    readPayloadV2 = decodePayloadV2(msgFromPb.get()).get()

    check:
      readPayloadV2 == aliceStep.payload2
    ###############################################

    # Bob reads Alice's payloads, and returns the (decrypted) transport message Alice sent to him
    bobStep = stepHandshake(
        rng[], bobHS, readPayloadV2 = readPayloadV2, messageNametag = bobMessageNametag
      )
      .get()

    check:
      bobStep.transportMessage == sentTransportMessage

    # Bob further checks if Alice's commitment opens to Alice's static key he just received
    let expectedAliceCommittedStaticKey =
      commitPublicKey(bobHS.rs, bobStep.transportMessage)

    check:
      expectedAliceCommittedStaticKey == aliceCommittedStaticKey

    #########################
    # Secure Transfer Phase
    #########################

    # We finalize the handshake to retrieve the Inbound/Outbound Symmetric States
    var aliceHSResult, bobHSResult: HandshakeResult

    aliceHSResult = finalizeHandshake(aliceHS)
    bobHSResult = finalizeHandshake(bobHS)

    # We test read/write of random messages exchanged between Alice and Bob
    var
      payload2: PayloadV2
      message: seq[byte]
      readMessage: seq[byte]

    # We test message exchange
    # Note that we exchange more than the number of messages contained in the nametag buffer to test if they are filled correctly as the communication proceeds
    for i in 0 .. 10 * MessageNametagBufferSize:
      # Alice writes to Bob
      message = randomSeqByte(rng[], 32)
      payload2 = writeMessage(
        aliceHSResult,
        message,
        outboundMessageNametagBuffer = aliceHSResult.nametagsOutbound,
      )
      readMessage = readMessage(
          bobHSResult,
          payload2,
          inboundMessageNametagBuffer = bobHSResult.nametagsInbound,
        )
        .get()

      check:
        message == readMessage

      # Bob writes to Alice
      message = randomSeqByte(rng[], 32)
      payload2 = writeMessage(
        bobHSResult,
        message,
        outboundMessageNametagBuffer = bobHSResult.nametagsOutbound,
      )
      readMessage = readMessage(
          aliceHSResult,
          payload2,
          inboundMessageNametagBuffer = aliceHSResult.nametagsInbound,
        )
        .get()

      check:
        message == readMessage

    # We test how nametag buffers help in detecting lost messages
    # Alice writes two messages to Bob, but only the second is received
    message = randomSeqByte(rng[], 32)
    payload2 = writeMessage(
      aliceHSResult,
      message,
      outboundMessageNametagBuffer = aliceHSResult.nametagsOutbound,
    )
    message = randomSeqByte(rng[], 32)
    payload2 = writeMessage(
      aliceHSResult,
      message,
      outboundMessageNametagBuffer = aliceHSResult.nametagsOutbound,
    )
    expect NoiseSomeMessagesWereLost:
      readMessage = readMessage(
          bobHSResult,
          payload2,
          inboundMessageNametagBuffer = bobHSResult.nametagsInbound,
        )
        .get()

    # We adjust bob nametag buffer for next test (i.e. the missed message is correctly recovered)
    delete(bobHSResult.nametagsInbound, 2)
    message = randomSeqByte(rng[], 32)
    payload2 = writeMessage(
      bobHSResult, message, outboundMessageNametagBuffer = bobHSResult.nametagsOutbound
    )
    readMessage = readMessage(
        aliceHSResult,
        payload2,
        inboundMessageNametagBuffer = aliceHSResult.nametagsInbound,
      )
      .get()

    check:
      message == readMessage

    # We test if a missing nametag is correctly detected
    message = randomSeqByte(rng[], 32)
    payload2 = writeMessage(
      aliceHSResult,
      message,
      outboundMessageNametagBuffer = aliceHSResult.nametagsOutbound,
    )
    delete(bobHSResult.nametagsInbound, 1)
    expect NoiseMessageNametagError:
      readMessage = readMessage(
          bobHSResult,
          payload2,
          inboundMessageNametagBuffer = bobHSResult.nametagsInbound,
        )
        .get()

# Waku Noise Protocols for Waku Payload Encryption
## See spec for more details:
## https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/35

{.push raises: [].}

import std/[options, strutils, tables]
import chronos
import chronicles
import bearssl/rand
import results

import libp2p/crypto/[chacha20poly1305, curve25519]

import ./noise_types
import ./noise
import ./noise_utils

logScope:
  topics = "waku noise"

#################################################################

# Handshake Processing

#################################
## Utilities
#################################

# Based on the message handshake direction and if the user is or not the initiator, returns a boolean tuple telling if the user
# has to read or write the next handshake message
proc getReadingWritingState(
    hs: HandshakeState, direction: MessageDirection
): (bool, bool) =
  var reading, writing: bool

  if hs.initiator and direction == D_r:
    # I'm Alice and direction is ->
    reading = false
    writing = true
  elif hs.initiator and direction == D_l:
    # I'm Alice and direction is <-
    reading = true
    writing = false
  elif not hs.initiator and direction == D_r:
    # I'm Bob and direction is ->
    reading = true
    writing = false
  elif not hs.initiator and direction == D_l:
    # I'm Bob and direction is <-
    reading = false
    writing = true

  return (reading, writing)

# Checks if a pre-message is valid according to Noise specifications
# http://www.noiseprotocol.org/noise.html#handshake-patterns
proc isValid(msg: seq[PreMessagePattern]): bool =
  var isValid: bool = true

  # Non-empty pre-messages can only have patterns "e", "s", "e,s" in each direction
  let allowedPatterns: seq[PreMessagePattern] = @[
    PreMessagePattern(direction: D_r, tokens: @[T_s]),
    PreMessagePattern(direction: D_r, tokens: @[T_e]),
    PreMessagePattern(direction: D_r, tokens: @[T_e, T_s]),
    PreMessagePattern(direction: D_l, tokens: @[T_s]),
    PreMessagePattern(direction: D_l, tokens: @[T_e]),
    PreMessagePattern(direction: D_l, tokens: @[T_e, T_s]),
  ]

  # We check if pre message patterns are allowed
  for pattern in msg:
    if not (pattern in allowedPatterns):
      isValid = false
      break

  return isValid

#################################
# Handshake messages processing procedures
#################################

# Processes pre-message patterns
proc processPreMessagePatternTokens(
    hs: var HandshakeState, inPreMessagePKs: seq[NoisePublicKey] = @[]
) {.
    raises: [Defect, NoiseMalformedHandshake, NoiseHandshakeError, NoisePublicKeyError]
.} =
  var
    # I make a copy of the input pre-message public keys, so that I can easily delete processed ones without using iterators/counters
    preMessagePKs = inPreMessagePKs
    # Here we store currently processed pre message public key
    currPK: NoisePublicKey

  # We retrieve the pre-message patterns to process, if any
  # If none, there's nothing to do
  if hs.handshakePattern.preMessagePatterns == EmptyPreMessage:
    return

  # If not empty, we check that pre-message is valid according to Noise specifications
  if isValid(hs.handshakePattern.preMessagePatterns) == false:
    raise newException(NoiseMalformedHandshake, "Invalid pre-message in handshake")

  # We iterate over each pattern contained in the pre-message
  for messagePattern in hs.handshakePattern.preMessagePatterns:
    let
      direction = messagePattern.direction
      tokens = messagePattern.tokens

    # We get if the user is reading or writing the current pre-message pattern
    var (reading, writing) = getReadingWritingState(hs, direction)

    # We process each message pattern token
    for token in tokens:
      # We process the pattern token
      case token
      of T_e:
        # We expect an ephemeral key, so we attempt to read it (next PK to process will always be at index 0 of preMessagePKs)
        if preMessagePKs.len > 0:
          currPK = preMessagePKs[0]
        else:
          raise newException(
            NoiseHandshakeError, "Noise pre-message read e, expected a public key"
          )

        # If user is reading the "e" token
        if reading:
          trace "noise pre-message read e"

          # We check if current key is encrypted or not. We assume pre-message public keys are all unencrypted on users' end
          if currPK.flag == 0.uint8:
            # Sets re and calls MixHash(re.public_key).
            hs.re = intoCurve25519Key(currPK.pk)
            hs.ss.mixHash(hs.re)
          else:
            raise newException(
              NoisePublicKeyError,
              "Noise read e, incorrect encryption flag for pre-message public key",
            )

        # If user is writing the "e" token
        elif writing:
          trace "noise pre-message write e"

          # When writing, the user is sending a public key,
          # We check that the public part corresponds to the set local key and we call MixHash(e.public_key).
          if hs.e.publicKey == intoCurve25519Key(currPK.pk):
            hs.ss.mixHash(hs.e.publicKey)
          else:
            raise newException(
              NoisePublicKeyError,
              "Noise pre-message e key doesn't correspond to locally set e key pair",
            )

        # Noise specification: section 9.2
        # In non-PSK handshakes, the "e" token in a pre-message pattern or message pattern always results
        # in a call to MixHash(e.public_key).
        # In a PSK handshake, all of these calls are followed by MixKey(e.public_key).
        if "psk" in hs.handshakePattern.name:
          hs.ss.mixKey(currPK.pk)

        # We delete processed public key
        preMessagePKs.delete(0)
      of T_s:
        # We expect a static key, so we attempt to read it (next PK to process will always be at index of preMessagePKs)
        if preMessagePKs.len > 0:
          currPK = preMessagePKs[0]
        else:
          raise newException(
            NoiseHandshakeError, "Noise pre-message read s, expected a public key"
          )

        # If user is reading the "s" token
        if reading:
          trace "noise pre-message read s"

          # We check if current key is encrypted or not. We assume pre-message public keys are all unencrypted on users' end
          if currPK.flag == 0.uint8:
            # Sets re and calls MixHash(re.public_key).
            hs.rs = intoCurve25519Key(currPK.pk)
            hs.ss.mixHash(hs.rs)
          else:
            raise newException(
              NoisePublicKeyError,
              "Noise read s, incorrect encryption flag for pre-message public key",
            )

        # If user is writing the "s" token
        elif writing:
          trace "noise pre-message write s"

          # If writing, it means that the user is sending a public key,
          # We check that the public part corresponds to the set local key and we call MixHash(s.public_key).
          if hs.s.publicKey == intoCurve25519Key(currPK.pk):
            hs.ss.mixHash(hs.s.publicKey)
          else:
            raise newException(
              NoisePublicKeyError,
              "Noise pre-message s key doesn't correspond to locally set s key pair",
            )

        # Noise specification: section 9.2
        # In non-PSK handshakes, the "e" token in a pre-message pattern or message pattern always results
        # in a call to MixHash(e.public_key).
        # In a PSK handshake, all of these calls are followed by MixKey(e.public_key).
        if "psk" in hs.handshakePattern.name:
          hs.ss.mixKey(currPK.pk)

        # We delete processed public key
        preMessagePKs.delete(0)
      else:
        raise
          newException(NoiseMalformedHandshake, "Invalid Token for pre-message pattern")

# This procedure encrypts/decrypts the implicit payload attached at the end of every message pattern
# An optional extraAd to pass extra additional data in encryption/decryption can be set (useful to authenticate messageNametag)
proc processMessagePatternPayload(
    hs: var HandshakeState, transportMessage: seq[byte], extraAd: openArray[byte] = []
): seq[byte] {.raises: [Defect, NoiseDecryptTagError, NoiseNonceMaxError].} =
  var payload: seq[byte]

  # We retrieve current message pattern (direction + tokens) to process
  let direction = hs.handshakePattern.messagePatterns[hs.msgPatternIdx].direction

  # We get if the user is reading or writing the input handshake message
  var (reading, writing) = getReadingWritingState(hs, direction)

  # We decrypt the transportMessage, if any
  if reading:
    payload = hs.ss.decryptAndHash(transportMessage, extraAd)
    payload = pkcs7_unpad(payload, NoisePaddingBlockSize)
  elif writing:
    payload = pkcs7_pad(transportMessage, NoisePaddingBlockSize)
    payload = hs.ss.encryptAndHash(payload, extraAd)

  return payload

# We process an input handshake message according to current handshake state and we return the next handshake step's handshake message
proc processMessagePatternTokens(
    rng: var rand.HmacDrbgContext,
    hs: var HandshakeState,
    inputHandshakeMessage: seq[NoisePublicKey] = @[],
): Result[seq[NoisePublicKey], cstring] {.
    raises: [
      Defect, NoiseHandshakeError, NoiseMalformedHandshake, NoisePublicKeyError,
      NoiseDecryptTagError, NoiseNonceMaxError,
    ]
.} =
  # We retrieve current message pattern (direction + tokens) to process
  let
    messagePattern = hs.handshakePattern.messagePatterns[hs.msgPatternIdx]
    direction = messagePattern.direction
    tokens = messagePattern.tokens

  # We get if the user is reading or writing the input handshake message
  var (reading, writing) = getReadingWritingState(hs, direction)

  # I make a copy of the handshake message so that I can easily delete processed PKs without using iterators/counters
  # (Possibly) non-empty if reading
  var inHandshakeMessage = inputHandshakeMessage

  # The party's output public keys
  # (Possibly) non-empty if writing
  var outHandshakeMessage: seq[NoisePublicKey] = @[]

  # In currPK we store the currently processed public key from the handshake message
  var currPK: NoisePublicKey

  # We process each message pattern token
  for token in tokens:
    case token
    of T_e:
      # If user is reading the "s" token
      if reading:
        trace "noise read e"

        # We expect an ephemeral key, so we attempt to read it (next PK to process will always be at index 0 of preMessagePKs)
        if inHandshakeMessage.len > 0:
          currPK = inHandshakeMessage[0]
        else:
          raise newException(NoiseHandshakeError, "Noise read e, expected a public key")

        # We check if current key is encrypted or not
        # Note: by specification, ephemeral keys should always be unencrypted. But we support encrypted ones.
        if currPK.flag == 0.uint8:
          # Unencrypted Public Key
          # Sets re and calls MixHash(re.public_key).
          hs.re = intoCurve25519Key(currPK.pk)
          hs.ss.mixHash(hs.re)

        # The following is out of specification: we call decryptAndHash for encrypted ephemeral keys, similarly as happens for (encrypted) static keys
        elif currPK.flag == 1.uint8:
          # Encrypted public key
          # Decrypts re, sets re and calls MixHash(re.public_key).
          hs.re = intoCurve25519Key(hs.ss.decryptAndHash(currPK.pk))
        else:
          raise newException(
            NoisePublicKeyError,
            "Noise read e, incorrect encryption flag for public key",
          )

        # Noise specification: section 9.2
        # In non-PSK handshakes, the "e" token in a pre-message pattern or message pattern always results
        # in a call to MixHash(e.public_key).
        # In a PSK handshake, all of these calls are followed by MixKey(e.public_key).
        if "psk" in hs.handshakePattern.name:
          hs.ss.mixKey(hs.re)

        # We delete processed public key
        inHandshakeMessage.delete(0)

      # If user is writing the "e" token
      elif writing:
        trace "noise write e"

        # We generate a new ephemeral keypair
        hs.e = genKeyPair(rng)

        # We update the state
        hs.ss.mixHash(hs.e.publicKey)

        # Noise specification: section 9.2
        # In non-PSK handshakes, the "e" token in a pre-message pattern or message pattern always results
        # in a call to MixHash(e.public_key).
        # In a PSK handshake, all of these calls are followed by MixKey(e.public_key).
        if "psk" in hs.handshakePattern.name:
          hs.ss.mixKey(hs.e.publicKey)

        # We add the ephemeral public key to the Waku payload
        outHandshakeMessage.add toNoisePublicKey(getPublicKey(hs.e))
    of T_s:
      # If user is reading the "s" token
      if reading:
        trace "noise read s"

        # We expect a static key, so we attempt to read it (next PK to process will always be at index 0 of preMessagePKs)
        if inHandshakeMessage.len > 0:
          currPK = inHandshakeMessage[0]
        else:
          raise newException(NoiseHandshakeError, "Noise read s, expected a public key")

        # We check if current key is encrypted or not
        if currPK.flag == 0.uint8:
          # Unencrypted Public Key
          # Sets re and calls MixHash(re.public_key).
          hs.rs = intoCurve25519Key(currPK.pk)
          hs.ss.mixHash(hs.rs)
        elif currPK.flag == 1.uint8:
          # Encrypted public key
          # Decrypts rs, sets rs and calls MixHash(rs.public_key).
          hs.rs = intoCurve25519Key(hs.ss.decryptAndHash(currPK.pk))
        else:
          raise newException(
            NoisePublicKeyError,
            "Noise read s, incorrect encryption flag for public key",
          )

        # We delete processed public key
        inHandshakeMessage.delete(0)

      # If user is writing the "s" token
      elif writing:
        trace "noise write s"

        # If the local static key is not set (the handshake state was not properly initialized), we raise an error
        if isDefault(hs.s):
          raise newException(NoisePublicKeyError, "Static key not set")

        # We encrypt the public part of the static key in case a key is set in the Cipher State
        # That is, encS may either be an encrypted or unencrypted static key.
        let encS = hs.ss.encryptAndHash(hs.s.publicKey)

        # We add the (encrypted) static public key to the Waku payload
        # Note that encS = (Enc(s) || tag) if encryption key is set, otherwise encS = s.
        # We distinguish these two cases by checking length of encryption and we set the proper encryption flag
        if encS.len > Curve25519Key.len:
          outHandshakeMessage.add NoisePublicKey(flag: 1, pk: encS)
        else:
          outHandshakeMessage.add NoisePublicKey(flag: 0, pk: encS)
    of T_psk:
      # If user is reading the "psk" token

      trace "noise psk"

      # Calls MixKeyAndHash(psk)
      hs.ss.mixKeyAndHash(hs.psk)
    of T_ee:
      # If user is reading the "ee" token

      trace "noise dh ee"

      # If local and/or remote ephemeral keys are not set, we raise an error
      if isDefault(hs.e) or isDefault(hs.re):
        raise newException(NoisePublicKeyError, "Local or remote ephemeral key not set")

      # Calls MixKey(DH(e, re)).
      hs.ss.mixKey(dh(hs.e.privateKey, hs.re))
    of T_es:
      # If user is reading the "es" token

      trace "noise dh es"

      # We check if keys are correctly set.
      # If both present, we call MixKey(DH(e, rs)) if initiator, MixKey(DH(s, re)) if responder.
      if hs.initiator:
        if isDefault(hs.e) or isDefault(hs.rs):
          raise newException(
            NoisePublicKeyError, "Local or remote ephemeral/static key not set"
          )
        hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))
      else:
        if isDefault(hs.re) or isDefault(hs.s):
          raise newException(
            NoisePublicKeyError, "Local or remote ephemeral/static key not set"
          )
        hs.ss.mixKey(dh(hs.s.privateKey, hs.re))
    of T_se:
      # If user is reading the "se" token

      trace "noise dh se"

      # We check if keys are correctly set.
      # If both present, call MixKey(DH(s, re)) if initiator, MixKey(DH(e, rs)) if responder.
      if hs.initiator:
        if isDefault(hs.s) or isDefault(hs.re):
          raise newException(
            NoiseMalformedHandshake, "Local or remote ephemeral/static key not set"
          )
        hs.ss.mixKey(dh(hs.s.privateKey, hs.re))
      else:
        if isDefault(hs.rs) or isDefault(hs.e):
          raise newException(
            NoiseMalformedHandshake, "Local or remote ephemeral/static key not set"
          )
        hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))
    of T_ss:
      # If user is reading the "ss" token

      trace "noise dh ss"

      # If local and/or remote static keys are not set, we raise an error
      if isDefault(hs.s) or isDefault(hs.rs):
        raise
          newException(NoiseMalformedHandshake, "Local or remote static key not set")

      # Calls MixKey(DH(s, rs)).
      hs.ss.mixKey(dh(hs.s.privateKey, hs.rs))

  return ok(outHandshakeMessage)

#################################
## Procedures to progress handshakes between users
#################################

# Initializes a Handshake State
proc initialize*(
    hsPattern: HandshakePattern,
    ephemeralKey: KeyPair = default(KeyPair),
    staticKey: KeyPair = default(KeyPair),
    prologue: seq[byte] = @[],
    psk: seq[byte] = @[],
    preMessagePKs: seq[NoisePublicKey] = @[],
    initiator: bool = false,
): HandshakeState {.
    raises: [Defect, NoiseMalformedHandshake, NoiseHandshakeError, NoisePublicKeyError]
.} =
  var hs = HandshakeState.init(hsPattern)
  hs.ss.mixHash(prologue)
  hs.e = ephemeralKey
  hs.s = staticKey
  hs.psk = psk
  hs.msgPatternIdx = 0
  hs.initiator = initiator
  # We process any eventual handshake pre-message pattern by processing pre-message public keys
  processPreMessagePatternTokens(hs, preMessagePKs)
  return hs

# Advances 1 step in handshake
# Each user in a handshake alternates writing and reading of handshake messages.
# If the user is writing the handshake message, the transport message (if not empty) and eventually a non-empty message nametag has to be passed to transportMessage and messageNametag and readPayloadV2 can be left to its default value
# It the user is reading the handshake message, the read payload v2 has to be passed to readPayloadV2 and the transportMessage can be left to its default values. Decryption is skipped if the payloadv2 read doesn't have a message nametag equal to messageNametag (empty input nametags are converted to all-0 MessageNametagLength bytes arrays)
proc stepHandshake*(
    rng: var rand.HmacDrbgContext,
    hs: var HandshakeState,
    readPayloadV2: PayloadV2 = default(PayloadV2),
    transportMessage: seq[byte] = @[],
    messageNametag: openArray[byte] = [],
): Result[HandshakeStepResult, cstring] {.
    raises: [
      Defect, NoiseHandshakeError, NoiseMessageNametagError, NoiseMalformedHandshake,
      NoisePublicKeyError, NoiseDecryptTagError, NoiseNonceMaxError,
    ]
.} =
  var hsStepResult: HandshakeStepResult

  # If there are no more message patterns left for processing
  # we return an empty HandshakeStepResult
  if hs.msgPatternIdx > uint8(hs.handshakePattern.messagePatterns.len - 1):
    info "stepHandshake called more times than the number of message patterns present in handshake"
    return ok(hsStepResult)

  # We process the next handshake message pattern

  # We get if the user is reading or writing the input handshake message
  let direction = hs.handshakePattern.messagePatterns[hs.msgPatternIdx].direction
  var (reading, writing) = getReadingWritingState(hs, direction)

  # If we write an answer at this handshake step
  if writing:
    # We initialize a payload v2 and we set proper protocol ID (if supported)
    try:
      hsStepResult.payload2.protocolId = PayloadV2ProtocolIDs[hs.handshakePattern.name]
    except CatchableError:
      raise newException(NoiseMalformedHandshake, "Handshake Pattern not supported")

    # We set the messageNametag and the handshake and transport messages
    hsStepResult.payload2.messageNametag = toMessageNametag(messageNametag)
    hsStepResult.payload2.handshakeMessage = processMessagePatternTokens(rng, hs).get()
    # We write the payload by passing the messageNametag as extra additional data
    hsStepResult.payload2.transportMessage = processMessagePatternPayload(
      hs, transportMessage, extraAd = hsStepResult.payload2.messageNametag
    )

  # If we read an answer during this handshake step
  elif reading:
    # If the read message nametag doesn't match the expected input one we raise an error
    if readPayloadV2.messageNametag != toMessageNametag(messageNametag):
      raise newException(
        NoiseMessageNametagError,
        "The message nametag of the read message doesn't match the expected one",
      )

    # We process the read public keys and (eventually decrypt) the read transport message
    let
      readHandshakeMessage = readPayloadV2.handshakeMessage
      readTransportMessage = readPayloadV2.transportMessage

    # Since we only read, nothing meanigful (i.e. public keys) is returned
    discard processMessagePatternTokens(rng, hs, readHandshakeMessage)
    # We retrieve and store the (decrypted) received transport message by passing the messageNametag as extra additional data
    hsStepResult.transportMessage = processMessagePatternPayload(
      hs, readTransportMessage, extraAd = readPayloadV2.messageNametag
    )
  else:
    raise newException(
      NoiseHandshakeError, "Handshake Error: neither writing or reading user"
    )

  # We increase the handshake state message pattern index to progress to next step
  hs.msgPatternIdx += 1

  return ok(hsStepResult)

# Finalizes the handshake by calling Split and assigning the proper Cipher States to users
proc finalizeHandshake*(hs: var HandshakeState): HandshakeResult =
  var hsResult: HandshakeResult

  ## Noise specification, Section 5:
  ## Processing the final handshake message returns two CipherState objects,
  ## the first for encrypting transport messages from initiator to responder,
  ## and the second for messages in the other direction.

  # We call Split()
  let (cs1, cs2) = hs.ss.split()

  # Optional: We derive a secret for the nametag derivation
  let (nms1, nms2) = genMessageNametagSecrets(hs)

  # We assign the proper Cipher States
  if hs.initiator:
    hsResult.csOutbound = cs1
    hsResult.csInbound = cs2
    # and nametags secrets
    hsResult.nametagsInbound.secret = some(nms1)
    hsResult.nametagsOutbound.secret = some(nms2)
  else:
    hsResult.csOutbound = cs2
    hsResult.csInbound = cs1
    # and nametags secrets
    hsResult.nametagsInbound.secret = some(nms2)
    hsResult.nametagsOutbound.secret = some(nms1)

  # We initialize the message nametags inbound/outbound buffers
  hsResult.nametagsInbound.initNametagsBuffer
  hsResult.nametagsOutbound.initNametagsBuffer

  # We store the optional fields rs and h
  hsResult.rs = hs.rs
  hsResult.h = hs.ss.h

  return hsResult

#################################
# After-handshake procedures
#################################

## Noise specification, Section 5:
## Transport messages are then encrypted and decrypted by calling EncryptWithAd()
## and DecryptWithAd() on the relevant CipherState with zero-length associated data.
## If DecryptWithAd() signals an error due to DECRYPT() failure, then the input message is discarded.
## The application may choose to delete the CipherState and terminate the session on such an error,
## or may continue to attempt communications. If EncryptWithAd() or DecryptWithAd() signal an error
## due to nonce exhaustion, then the application must delete the CipherState and terminate the session.

# Writes an encrypted message using the proper Cipher State
proc writeMessage*(
    hsr: var HandshakeResult,
    transportMessage: seq[byte],
    outboundMessageNametagBuffer: var MessageNametagBuffer,
): PayloadV2 {.raises: [Defect, NoiseNonceMaxError].} =
  var payload2: PayloadV2

  # We set the message nametag using the input buffer
  payload2.messageNametag = pop(outboundMessageNametagBuffer)

  # According to 35/WAKU2-NOISE RFC, no Handshake protocol information is sent when exchanging messages
  # This correspond to setting protocol-id to 0
  payload2.protocolId = 0.uint8
  # We pad the transport message
  let paddedTransportMessage = pkcs7_pad(transportMessage, NoisePaddingBlockSize)
  # Encryption is done with zero-length associated data as per specification
  payload2.transportMessage = encryptWithAd(
    hsr.csOutbound, ad = @(payload2.messageNametag), plaintext = paddedTransportMessage
  )

  return payload2

# Reads an encrypted message using the proper Cipher State
# Decryption is attempted only if the input PayloadV2 has a messageNametag equal to the one expected
proc readMessage*(
    hsr: var HandshakeResult,
    readPayload2: PayloadV2,
    inboundMessageNametagBuffer: var MessageNametagBuffer,
): Result[seq[byte], cstring] {.
    raises: [
      Defect, NoiseDecryptTagError, NoiseMessageNametagError, NoiseNonceMaxError,
      NoiseSomeMessagesWereLost,
    ]
.} =
  # The output decrypted message
  var message: seq[byte]

  # If the message nametag does not correspond to the nametag expected in the inbound message nametag buffer
  # an error is raised (to be handled externally, i.e. re-request lost messages, discard, etc.)
  let nametagIsOk =
    checkNametag(readPayload2.messageNametag, inboundMessageNametagBuffer).isOk
  assert(nametagIsOk)

  # At this point the messageNametag matches the expected nametag.
  # According to 35/WAKU2-NOISE RFC, no Handshake protocol information is sent when exchanging messages
  if readPayload2.protocolId == 0.uint8:
    # On application level we decide to discard messages which fail decryption, without raising an error
    try:
      # Decryption is done with messageNametag as associated data
      let paddedMessage = decryptWithAd(
        hsr.csInbound,
        ad = @(readPayload2.messageNametag),
        ciphertext = readPayload2.transportMessage,
      )
      # We unpdad the decrypted message
      message = pkcs7_unpad(paddedMessage, NoisePaddingBlockSize)
      # The message successfully decrypted, we can delete the first element of the inbound Message Nametag Buffer
      delete(inboundMessageNametagBuffer, 1)
    except NoiseDecryptTagError:
      info "A read message failed decryption. Returning empty message as plaintext."
      message = @[]

  return ok(message)

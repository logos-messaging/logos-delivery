# Waku Noise Protocols for Waku Payload Encryption
# Noise utilities module
## See spec for more details:
## https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/35

{.push raises: [].}

import std/[algorithm, base64, oids, options, strutils, tables, sequtils]
import chronos
import chronicles
import bearssl/rand
import results
import stew/[endians2, byteutils]
import nimcrypto/sha2

import libp2p/crypto/[chacha20poly1305, curve25519, hkdf]

import ./noise_types
import ./noise

logScope:
  topics = "waku noise"

#################################################################

#################################
# Generic Utilities
#################################

# Generates random byte sequences of given size
proc randomSeqByte*(rng: var HmacDrbgContext, size: int): seq[byte] =
  var output = newSeq[byte](size.uint32)
  hmacDrbgGenerate(rng, output)
  return output

# Pads a payload according to PKCS#7 as per RFC 5652 https://datatracker.ietf.org/doc/html/rfc5652#section-6.3
proc pkcs7_pad*(payload: seq[byte], paddingSize: int): seq[byte] =
  assert(paddingSize < 256)

  let k = paddingSize - (payload.len mod paddingSize)

  var padding: seq[byte]

  if k != 0:
    padding = newSeqWith(k, k.byte)
  else:
    padding = newSeqWith(paddingSize, paddingSize.byte)

  let padded = concat(payload, padding)

  return padded

# Unpads a payload according to PKCS#7 as per RFC 5652 https://datatracker.ietf.org/doc/html/rfc5652#section-6.3
proc pkcs7_unpad*(payload: seq[byte], paddingSize: int): seq[byte] =
  let k = payload[payload.high]
  let unpadded = payload[0 .. payload.high - k.int]
  return unpadded

proc seqToDigest256*(sequence: seq[byte]): MDigest[256] =
  var digest: MDigest[256]
  for i in 0 ..< digest.data.len:
    digest.data[i] = sequence[i]
  return digest

proc digestToSeq*[T](digest: MDigest[T]): seq[byte] =
  var sequence: seq[byte]
  for i in 0 ..< digest.data.len:
    sequence.add digest.data[i]
  return sequence

# Serializes input parameters to a base64 string for exposure through QR code (used by WakuPairing)
proc toQr*(
    applicationName: string,
    applicationVersion: string,
    shardId: string,
    ephemeralKey: EllipticCurveKey,
    committedStaticKey: MDigest[256],
): string =
  var qr: string
  qr.add encode(applicationName, safe = true) & ":"
  qr.add encode(applicationVersion, safe = true) & ":"
  qr.add encode(shardId, safe = true) & ":"
  qr.add encode(ephemeralKey, safe = true) & ":"
  qr.add encode(committedStaticKey.data, safe = true)

  return qr

# Deserializes input string in base64 to the corresponding (applicationName, applicationVersion, shardId, ephemeralKey, committedStaticKey)
proc fromQr*(
    qr: string
): (string, string, string, EllipticCurveKey, MDigest[256]) {.
    raises: [Defect, ValueError]
.} =
  let values = qr.split(":")

  assert(values.len == 5)

  let applicationName: string = decode(values[0])
  let applicationVersion: string = decode(values[1])
  let shardId: string = decode(values[2])

  let decodedEphemeralKey = decode(values[3]).toBytes
  var ephemeralKey: EllipticCurveKey
  for i in 0 ..< ephemeralKey.len:
    ephemeralKey[i] = decodedEphemeralKey[i]

  let committedStaticKey = seqToDigest256(decode(values[4]).toBytes)

  return
    (applicationName, applicationVersion, shardId, ephemeralKey, committedStaticKey)

# Converts a sequence or array (arbitrary size) to a MessageNametag
proc toMessageNametag*(input: openArray[byte]): MessageNametag =
  var byte_seq: seq[byte] = @input

  # We set its length to the default message nametag length (will be truncated or 0-padded)
  byte_seq.setLen(MessageNametagLength)

  # We copy it to a MessageNametag
  var messageNametag: MessageNametag
  for i in 0 ..< MessageNametagLength:
    messageNametag[i] = byte_seq[i]

  return messageNametag

# Uses the cryptographic information stored in the input handshake state to generate a random message nametag
# In current implementation the messageNametag = HKDF(handshake hash value), but other derivation mechanisms can be implemented
proc toMessageNametag*(hs: HandshakeState): MessageNametag =
  var output: array[1, array[MessageNametagLength, byte]]
  sha256.hkdf(hs.ss.h.data, [], [], output)
  return output[0]

proc genMessageNametagSecrets*(
    hs: HandshakeState
): (array[MessageNametagSecretLength, byte], array[MessageNametagSecretLength, byte]) =
  var output: array[2, array[MessageNametagSecretLength, byte]]
  sha256.hkdf(hs.ss.h.data, [], [], output)
  return (output[0], output[1])

# Simple utility that checks if the given variable is "default",
# Therefore, it has not been initialized
proc isDefault*[T](value: T): bool =
  value == static(default(T))

#################################################################

#################################
# Noise Handhshake Utilities
#################################

# Generate random (public, private) Elliptic Curve key pairs
proc genKeyPair*(rng: var HmacDrbgContext): KeyPair =
  var keyPair: KeyPair
  keyPair.privateKey = EllipticCurveKey.random(rng)
  keyPair.publicKey = keyPair.privateKey.public()
  return keyPair

# Gets private key from a key pair
proc getPrivateKey*(keypair: KeyPair): EllipticCurveKey =
  return keypair.privateKey

# Gets public key from a key pair
proc getPublicKey*(keypair: KeyPair): EllipticCurveKey =
  return keypair.publicKey

# Prints Handshake Patterns using Noise pattern layout
proc print*(self: HandshakePattern) {.raises: [IOError, NoiseMalformedHandshake].} =
  try:
    if self.name != "":
      stdout.write self.name, ":\n"
      stdout.flushFile()
    # We iterate over pre message patterns, if any
    if self.preMessagePatterns != EmptyPreMessage:
      for pattern in self.preMessagePatterns:
        stdout.write "  ", pattern.direction
        var first = true
        for token in pattern.tokens:
          if first:
            stdout.write " ", token
            first = false
          else:
            stdout.write ", ", token
        stdout.write "\n"
        stdout.flushFile()
      stdout.write "    ...\n"
      stdout.flushFile()
    # We iterate over message patterns
    for pattern in self.messagePatterns:
      stdout.write "  ", pattern.direction
      var first = true
      for token in pattern.tokens:
        if first:
          stdout.write " ", token
          first = false
        else:
          stdout.write ", ", token
      stdout.write "\n"
      stdout.flushFile()
  except CatchableError:
    raise newException(NoiseMalformedHandshake, "HandshakePattern malformed")

# Hashes a Noise protocol name using SHA256
proc hashProtocol*(protocolName: string): MDigest[256] =
  # The output hash value
  var hash: MDigest[256]

  # From Noise specification: Section 5.2
  # http://www.noiseprotocol.org/noise.html#the-symmetricstate-object
  # If protocol_name is less than or equal to HASHLEN bytes in length,
  # sets h equal to protocol_name with zero bytes appended to make HASHLEN bytes.
  # Otherwise sets h = HASH(protocol_name).
  if protocolName.len <= 32:
    hash.data[0 .. protocolName.high] = protocolName.toBytes
  else:
    hash = sha256.digest(protocolName)

  return hash

# Commits a public key pk for randomness r as H(pk || s)
proc commitPublicKey*(publicKey: EllipticCurveKey, r: seq[byte]): MDigest[256] =
  var hashInput: seq[byte]
  hashInput.add getBytes(publicKey)
  hashInput.add r

  # The output hash value
  var hash: MDigest[256]
  hash = sha256.digest(hashInput)

  return hash

# Generates an 8 decimal digits authorization code using HKDF and the handshake state
proc genAuthcode*(hs: HandshakeState): string =
  var output: array[1, array[8, byte]]
  sha256.hkdf(hs.ss.h.data, [], [], output)
  let code = cast[uint64](output[0]) mod 100_000_000
  return $code

# Initializes the empty Message nametag buffer. The n-th nametag is equal to HKDF( secret || n )
proc initNametagsBuffer*(mntb: var MessageNametagBuffer) =
  # We default the counter and buffer fields
  mntb.counter = 0
  mntb.buffer = default(array[MessageNametagBufferSize, MessageNametag])

  if mntb.secret.isSome:
    for i in 0 ..< mntb.buffer.len:
      mntb.buffer[i] = toMessageNametag(
        sha256.digest(@(mntb.secret.get()) & @(toBytesLE(mntb.counter))).data
      )
      mntb.counter += 1
  else:
    # We warn users if no secret is set
    info "The message nametags buffer has not a secret set"

# Deletes the first n elements in buffer and appends n new ones
proc delete*(mntb: var MessageNametagBuffer, n: int) =
  if n <= 0:
    return

  # We ensure n is at most MessageNametagBufferSize (the buffer will be fully replaced)
  let n = min(n, MessageNametagBufferSize)

  # We update the last n values in the array if a secret is set
  # Note that if the input MessageNametagBuffer is set to default, nothing is done here
  if mntb.secret.isSome:
    # We rotate left the array by n
    mntb.buffer.rotateLeft(n)

    for i in 0 ..< n:
      mntb.buffer[mntb.buffer.len - n + i] = toMessageNametag(
        sha256.digest(@(mntb.secret.get()) & @(toBytesLE(mntb.counter))).data
      )
      mntb.counter += 1
  else:
    # We warn users that no secret is set
    info "The message nametags buffer has no secret set"

# Checks if the input messageNametag is contained in the input MessageNametagBuffer
proc checkNametag*(
    messageNametag: MessageNametag, mntb: var MessageNametagBuffer
): Result[bool, cstring] {.
    raises: [Defect, NoiseMessageNametagError, NoiseSomeMessagesWereLost]
.} =
  let index = mntb.buffer.find(messageNametag)

  if index == -1:
    raise newException(NoiseMessageNametagError, "Message nametag not found in buffer")
  elif index > 0:
    raise newException(
      NoiseSomeMessagesWereLost,
      "Message nametag is present in buffer but is not the next expected nametag. One or more messages were probably lost",
    )

  # index is 0, hence the read message tag is the next expected one
  return ok(true)

# Deletes the first n elements in buffer and appends n new ones
proc pop*(mntb: var MessageNametagBuffer): MessageNametag =
  # Note that if the input MessageNametagBuffer is set to default, an all 0 messageNametag is returned
  let messageNametag = mntb.buffer[0]
  delete(mntb, 1)
  return messageNametag

# Performs a Diffie-Hellman operation between two elliptic curve keys (one private, one public)
proc dh*(private: EllipticCurveKey, public: EllipticCurveKey): EllipticCurveKey =
  # The output result of the Diffie-Hellman operation
  var output: EllipticCurveKey

  # Since the EC multiplication writes the result to the input, we copy the input to the output variable
  output = public
  # We execute the DH operation
  EllipticCurve.mul(output, private)

  return output

#################################################################

#################################
# ChaChaPoly Cipher utilities
#################################

# Generates a random ChaChaPolyKey for testing encryption/decryption
proc randomChaChaPolyKey*(rng: var HmacDrbgContext): ChaChaPolyKey =
  var key: ChaChaPolyKey
  hmacDrbgGenerate(rng, key)
  return key

# Generates a random ChaChaPoly Cipher State for testing encryption/decryption
proc randomChaChaPolyCipherState*(rng: var HmacDrbgContext): ChaChaPolyCipherState =
  var randomCipherState: ChaChaPolyCipherState
  randomCipherState.k = randomChaChaPolyKey(rng)
  hmacDrbgGenerate(rng, randomCipherState.nonce)
  randomCipherState.ad = newSeq[byte](32)
  hmacDrbgGenerate(rng, randomCipherState.ad)
  return randomCipherState

#################################################################

#################################
# Noise Public keys utilities
#################################

# Checks equality between two Noise public keys
proc `==`*(k1, k2: NoisePublicKey): bool =
  return (k1.flag == k2.flag) and (k1.pk == k2.pk)

# Converts a public Elliptic Curve key to an unencrypted Noise public key
proc toNoisePublicKey*(publicKey: EllipticCurveKey): NoisePublicKey =
  var noisePublicKey: NoisePublicKey
  noisePublicKey.flag = 0
  noisePublicKey.pk = getBytes(publicKey)
  return noisePublicKey

# Generates a random Noise public key
proc genNoisePublicKey*(rng: var HmacDrbgContext): NoisePublicKey =
  var noisePublicKey: NoisePublicKey
  # We generate a random key pair
  let keyPair: KeyPair = genKeyPair(rng)
  # Since it is unencrypted, flag is 0
  noisePublicKey.flag = 0
  # We copy the public X coordinate of the key pair to the output Noise public key
  noisePublicKey.pk = getBytes(keyPair.publicKey)
  return noisePublicKey

# Converts a Noise public key to a stream of bytes as in
# https://rfc.vac.dev/spec/35/#public-keys-serialization
proc serializeNoisePublicKey*(noisePublicKey: NoisePublicKey): seq[byte] =
  var serializedNoisePublicKey: seq[byte]
  # Public key is serialized as (flag || pk)
  # Note that pk contains the X coordinate of the public key if unencrypted
  # or the encryption concatenated with the authorization tag if encrypted
  serializedNoisePublicKey.add noisePublicKey.flag
  serializedNoisePublicKey.add noisePublicKey.pk
  return serializedNoisePublicKey

# Converts a serialized Noise public key to a NoisePublicKey object as in
# https://rfc.vac.dev/spec/35/#public-keys-serialization
proc intoNoisePublicKey*(
    serializedNoisePublicKey: seq[byte]
): NoisePublicKey {.raises: [Defect, NoisePublicKeyError].} =
  var noisePublicKey: NoisePublicKey
  # We retrieve the encryption flag
  noisePublicKey.flag = serializedNoisePublicKey[0]
  # If not 0 or 1 we raise a new exception
  if not (noisePublicKey.flag == 0 or noisePublicKey.flag == 1):
    raise newException(NoisePublicKeyError, "Invalid flag in serialized public key")
  # We set the remaining sequence to the pk value (this may be an encrypted or not encrypted X coordinate)
  noisePublicKey.pk = serializedNoisePublicKey[1 ..< serializedNoisePublicKey.len]
  return noisePublicKey

# Encrypts a Noise public key using a ChaChaPoly Cipher State
proc encryptNoisePublicKey*(
    cs: ChaChaPolyCipherState, noisePublicKey: NoisePublicKey
): NoisePublicKey {.raises: [Defect, NoiseEmptyChaChaPolyInput, NoiseNonceMaxError].} =
  var encryptedNoisePublicKey: NoisePublicKey
  # We proceed with encryption only if
  # - a key is set in the cipher state
  # - the public key is unencrypted
  if cs.k != EmptyKey and noisePublicKey.flag == 0:
    let encPk = encrypt(cs, noisePublicKey.pk)
    # We set the flag to 1, since encrypted
    encryptedNoisePublicKey.flag = 1
    # Authorization tag is appendend to the ciphertext
    encryptedNoisePublicKey.pk = encPk.data
    encryptedNoisePublicKey.pk.add encPk.tag
  # Otherwise we return the public key as it is
  else:
    encryptedNoisePublicKey = noisePublicKey
  return encryptedNoisePublicKey

# Decrypts a Noise public key using a ChaChaPoly Cipher State
proc decryptNoisePublicKey*(
    cs: ChaChaPolyCipherState, noisePublicKey: NoisePublicKey
): NoisePublicKey {.raises: [Defect, NoiseEmptyChaChaPolyInput, NoiseDecryptTagError].} =
  var decryptedNoisePublicKey: NoisePublicKey
  # We proceed with decryption only if
  # - a key is set in the cipher state
  # - the public key is encrypted
  if cs.k != EmptyKey and noisePublicKey.flag == 1:
    # Since the pk field would contain an encryption + tag, we retrieve the ciphertext length
    let pkLen = noisePublicKey.pk.len - ChaChaPolyTag.len
    # We isolate the ciphertext and the authorization tag
    let pk = noisePublicKey.pk[0 ..< pkLen]
    let pkAuth =
      intoChaChaPolyTag(noisePublicKey.pk[pkLen ..< pkLen + ChaChaPolyTag.len])
    # We convert it to a ChaChaPolyCiphertext
    let ciphertext = ChaChaPolyCiphertext(data: pk, tag: pkAuth)
    # We run decryption and store its value to a non-encrypted Noise public key (flag = 0)
    decryptedNoisePublicKey.pk = decrypt(cs, ciphertext)
    decryptedNoisePublicKey.flag = 0
  # Otherwise we return the public key as it is
  else:
    decryptedNoisePublicKey = noisePublicKey
  return decryptedNoisePublicKey

#################################################################

#################################
# Payload encoding/decoding procedures
#################################

# Checks equality between two PayloadsV2 objects
proc `==`*(p1, p2: PayloadV2): bool =
  return
    (p1.messageNametag == p2.messageNametag) and (p1.protocolId == p2.protocolId) and
    (p1.handshakeMessage == p2.handshakeMessage) and
    (p1.transportMessage == p2.transportMessage)

# Generates a random PayloadV2
proc randomPayloadV2*(rng: var HmacDrbgContext): PayloadV2 =
  var payload2: PayloadV2
  # We set a random messageNametag
  let randMessageNametag = randomSeqByte(rng, MessageNametagLength)
  for i in 0 ..< MessageNametagLength:
    payload2.messageNametag[i] = randMessageNametag[i]
  # To generate a random protocol id, we generate a random 1-byte long sequence, and we convert the first element to uint8
  payload2.protocolId = randomSeqByte(rng, 1)[0].uint8
  # We set the handshake message to three unencrypted random Noise Public Keys
  payload2.handshakeMessage =
    @[genNoisePublicKey(rng), genNoisePublicKey(rng), genNoisePublicKey(rng)]
  # We set the transport message to a random 128-bytes long sequence
  payload2.transportMessage = randomSeqByte(rng, 128)
  return payload2

# Serializes a PayloadV2 object to a byte sequences according to https://rfc.vac.dev/spec/35/.
# The output serialized payload concatenates the input PayloadV2 object fields as
# payload = ( protocolId || serializedHandshakeMessageLen || serializedHandshakeMessage || transportMessageLen || transportMessage)
# The output can be then passed to the payload field of a WakuMessage https://rfc.vac.dev/spec/14/
proc serializePayloadV2*(self: PayloadV2): Result[seq[byte], cstring] =
  # We collect public keys contained in the handshake message
  var
    # According to https://rfc.vac.dev/spec/35/, the maximum size for the handshake message is 256 bytes, that is
    # the handshake message length can be represented with 1 byte only. (its length can be stored in 1 byte)
    # However, to ease public keys length addition operation, we declare it as int and later cast to uit8
    serializedHandshakeMessageLen: int = 0
    # This variables will store the concatenation of the serializations of all public keys in the handshake message
    serializedHandshakeMessage = newSeqOfCap[byte](256)
    # A variable to store the currently processed public key serialization
    serializedPk: seq[byte]
  # For each public key in the handshake message
  for pk in self.handshakeMessage:
    # We serialize the public key
    serializedPk = serializeNoisePublicKey(pk)
    # We sum its serialized length to the total
    serializedHandshakeMessageLen += serializedPk.len
    # We add its serialization to the concatenation of all serialized public keys in the handshake message
    serializedHandshakeMessage.add serializedPk
    # If we are processing more than 256 byte, we return an error
    if serializedHandshakeMessageLen > uint8.high.int:
      info "PayloadV2 malformed: too many public keys contained in the handshake message"
      return err("Too many public keys in handshake message")

  # We get the transport message byte length
  let transportMessageLen = self.transportMessage.len

  # The output payload as in https://rfc.vac.dev/spec/35/. We concatenate all the PayloadV2 fields as
  # payload = ( protocolId || serializedHandshakeMessageLen || serializedHandshakeMessage || transportMessageLen || transportMessage)
  # We declare it as a byte sequence of length accordingly to the PayloadV2 information read
  var payload = newSeqOfCap[byte](
    MessageNametagLength + #MessageNametagLength bytes for messageNametag
    1 + # 1 byte for protocol ID
    1 + # 1 byte for length of serializedHandshakeMessage field
    serializedHandshakeMessageLen +
      # serializedHandshakeMessageLen bytes for serializedHandshakeMessage
    8 + # 8 bytes for transportMessageLen
    transportMessageLen # transportMessageLen bytes for transportMessage
  )

  # We concatenate all the data
  # The protocol ID (1 byte) and handshake message length (1 byte) can be directly casted to byte to allow direct copy to the payload byte sequence
  payload.add @(self.messageNametag)
  payload.add self.protocolId.byte
  payload.add serializedHandshakeMessageLen.byte
  payload.add serializedHandshakeMessage
  # The transport message length is converted from uint64 to bytes in Little-Endian
  payload.add toBytesLE(transportMessageLen.uint64)
  payload.add self.transportMessage

  return ok(payload)

# Deserializes a byte sequence to a PayloadV2 object according to https://rfc.vac.dev/spec/35/.
# The input serialized payload concatenates the output PayloadV2 object fields as
# payload = ( messageNametag || protocolId || serializedHandshakeMessageLen || serializedHandshakeMessage || transportMessageLen || transportMessage)
proc deserializePayloadV2*(
    payload: seq[byte]
): Result[PayloadV2, cstring] {.raises: [Defect, NoisePublicKeyError].} =
  # The output PayloadV2
  var payload2: PayloadV2

  # i is the read input buffer position index
  var i: uint64 = 0

  # We start by reading the messageNametag
  for j in 0 ..< MessageNametagLength:
    payload2.messageNametag[j] = payload[i + j.uint64]
  i += MessageNametagLength

  # We read the Protocol ID
  # TODO: when the list of supported protocol ID is defined, check if read protocol ID is supported
  payload2.protocolId = payload[i].uint8
  i += 1

  # We read the Handshake Message lenght (1 byte)
  var handshakeMessageLen = payload[i].uint64
  if handshakeMessageLen > uint8.high.uint64:
    info "Payload malformed: too many public keys contained in the handshake message"
    return err("Too many public keys in handshake message")

  i += 1

  # We now read for handshakeMessageLen bytes the buffer and we deserialize each (encrypted/unencrypted) public key read
  var
    # In handshakeMessage we accumulate the read deserialized Noise Public keys
    handshakeMessage: seq[NoisePublicKey]
    flag: byte
    pkLen: uint64
    written: uint64 = 0

  # We read the buffer until handshakeMessageLen are read
  while written != handshakeMessageLen:
    # We obtain the current Noise Public key encryption flag
    flag = payload[i]
    # If the key is unencrypted, we only read the X coordinate of the EC public key and we deserialize into a Noise Public Key
    if flag == 0:
      pkLen = 1 + EllipticCurveKey.len
      handshakeMessage.add intoNoisePublicKey(payload[i ..< i + pkLen])
      i += pkLen
      written += pkLen
    # If the key is encrypted, we only read the encrypted X coordinate and the authorization tag, and we deserialize into a Noise Public Key
    elif flag == 1:
      pkLen = 1 + EllipticCurveKey.len + ChaChaPolyTag.len
      handshakeMessage.add intoNoisePublicKey(payload[i ..< i + pkLen])
      i += pkLen
      written += pkLen
    else:
      return err("Invalid flag for Noise public key")

  # We save in the output PayloadV2 the read handshake message
  payload2.handshakeMessage = handshakeMessage

  # We read the transport message length (8 bytes) and we convert to uint64 in Little Endian
  let transportMessageLen = fromBytesLE(uint64, payload[i .. (i + 8 - 1)])
  i += 8

  # We read the transport message (handshakeMessage bytes)
  payload2.transportMessage = payload[i .. i + transportMessageLen - 1]
  i += transportMessageLen

  return ok(payload2)

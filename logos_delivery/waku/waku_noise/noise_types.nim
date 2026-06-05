# Waku Noise Protocols for Waku Payload Encryption
## See spec for more details:
## https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/35
##
## Implementation partially inspired by noise-libp2p:
## https://github.com/status-im/nim-libp2p/blob/master/libp2p/protocols/secure/noise.nim

{.push raises: [].}

import std/[options, tables]
import chronos
import chronicles
import bearssl
import nimcrypto/sha2

import libp2p/errors
import libp2p/crypto/[crypto, chacha20poly1305, curve25519]

logScope:
  topics = "waku noise"

#################################################################

# Constants and data structures

const
  # EmptyKey represents a non-initialized ChaChaPolyKey
  EmptyKey* = default(ChaChaPolyKey)
  # The maximum ChaChaPoly allowed nonce in Noise Handshakes
  NonceMax* = uint64.high - 1
  # The padding blocksize of  a transport message
  NoisePaddingBlockSize* = 248
  # The default length of a message nametag 
  MessageNametagLength* = 16
  # The default length of the secret to generate Inbound/Outbound nametags buffer 
  MessageNametagSecretLength* = 32
  # The default size of an Inbound/outbound MessageNametagBuffer
  MessageNametagBufferSize* = 50

type

  #################################
  # Elliptic Curve arithemtic
  #################################

  # Default underlying elliptic curve arithmetic (useful for switching to multiple ECs)
  # Current default is Curve25519
  EllipticCurve* = Curve25519
  EllipticCurveKey* = Curve25519Key

  # An EllipticCurveKey (public, private) key pair
  KeyPair* = object
    privateKey*: EllipticCurveKey
    publicKey*: EllipticCurveKey

  #################################
  # Noise Public Keys
  #################################

  # A Noise public key is a public key exchanged during Noise handshakes (no private part)
  # This follows https://rfc.vac.dev/spec/35/#public-keys-serialization
  # pk contains the X coordinate of the public key, if unencrypted (this implies flag = 0)
  # or the encryption of the X coordinate concatenated with the authorization tag, if encrypted (this implies flag = 1)
  # Note: besides encryption, flag can be used to distinguish among multiple supported Elliptic Curves
  NoisePublicKey* = object
    flag*: uint8
    pk*: seq[byte]

  #################################
  # ChaChaPoly Encryption
  #################################

  # A ChaChaPoly ciphertext (data) + authorization tag (tag)
  ChaChaPolyCiphertext* = object
    data*: seq[byte]
    tag*: ChaChaPolyTag

  # A ChaChaPoly Cipher State containing key (k), nonce (nonce) and associated data (ad)
  ChaChaPolyCipherState* = object
    k*: ChaChaPolyKey
    nonce*: ChaChaPolyNonce
    ad*: seq[byte]

  #################################
  # Noise handshake patterns
  #################################

  # The Noise tokens appearing in Noise (pre)message patterns 
  # as in http://www.noiseprotocol.org/noise.html#handshake-pattern-basics
  NoiseTokens* = enum
    T_e = "e"
    T_s = "s"
    T_es = "es"
    T_ee = "ee"
    T_se = "se"
    T_ss = "ss"
    T_psk = "psk"

  # The direction of a (pre)message pattern in canonical form (i.e. Alice-initiated form)
  # as in http://www.noiseprotocol.org/noise.html#alice-and-bob
  MessageDirection* = enum
    D_r = "->"
    D_l = "<-"

  # The pre message pattern consisting of a message direction and some Noise tokens, if any.
  # (if non empty, only tokens e and s are allowed: http://www.noiseprotocol.org/noise.html#handshake-pattern-basics)
  PreMessagePattern* = object
    direction*: MessageDirection
    tokens*: seq[NoiseTokens]

  # The message pattern consisting of a message direction and some Noise tokens
  # All Noise tokens are allowed
  MessagePattern* = object
    direction*: MessageDirection
    tokens*: seq[NoiseTokens]

  # The handshake pattern object. It stores the handshake protocol name, the handshake pre message patterns and the handshake message patterns
  HandshakePattern* = object
    name*: string
    preMessagePatterns*: seq[PreMessagePattern]
    messagePatterns*: seq[MessagePattern]

  #################################
  # Noise state machine
  #################################

  # The Cipher State as in https://noiseprotocol.org/noise.html#the-cipherstate-object
  # Contains an encryption key k and a nonce n (used in Noise as a counter)
  CipherState* = object
    k*: ChaChaPolyKey
    n*: uint64

  # The Symmetric State as in https://noiseprotocol.org/noise.html#the-symmetricstate-object
  # Contains a Cipher State cs, the chaining key ck and the handshake hash value h
  SymmetricState* = object
    cs*: CipherState
    ck*: ChaChaPolyKey
    h*: MDigest[256]

  # The Handshake State as in https://noiseprotocol.org/noise.html#the-handshakestate-object
  # Contains 
  #   - the local and remote ephemeral/static keys e,s,re,rs (if any)
  #   - the initiator flag (true if the user creating the state is the handshake initiator, false otherwise)
  #   - the handshakePattern (containing the handshake protocol name, and (pre)message patterns)
  # This object is futher extended from specifications by storing:
  #   - a message pattern index msgPatternIdx indicating the next handshake message pattern to process
  #   - the user's preshared psk, if any
  HandshakeState* = object
    s*: KeyPair
    e*: KeyPair
    rs*: EllipticCurveKey
    re*: EllipticCurveKey
    ss*: SymmetricState
    initiator*: bool
    handshakePattern*: HandshakePattern
    msgPatternIdx*: uint8
    psk*: seq[byte]

  # While processing messages patterns, users either:
  # - read (decrypt) the other party's (encrypted) transport message
  # - write (encrypt) a message, sent through a PayloadV2
  # These two intermediate results are stored in the HandshakeStepResult data structure
  HandshakeStepResult* = object
    payload2*: PayloadV2
    transportMessage*: seq[byte]

  # When a handshake is complete, the HandhshakeResult will contain the two 
  # Cipher States used to encrypt/decrypt outbound/inbound messages
  # The recipient static key rs and handshake hash values h are stored to address some possible future applications (channel-binding, session management, etc.).
  # However, are not required by Noise specifications and are thus optional
  HandshakeResult* = object
    csOutbound*: CipherState
    csInbound*: CipherState
    # Optional fields:
    nametagsInbound*: MessageNametagBuffer
    nametagsOutbound*: MessageNametagBuffer
    rs*: EllipticCurveKey
    h*: MDigest[256]

  #################################
  # Waku Payload V2
  #################################

  # PayloadV2 defines an object for Waku payloads with version 2 as in
  # https://rfc.vac.dev/spec/35/#public-keys-serialization
  # It contains a message nametag, protocol ID field, the handshake message (for Noise handshakes) and 
  # a transport message (for Noise handshakes and ChaChaPoly encryptions)
  MessageNametag* = array[MessageNametagLength, byte]

  MessageNametagBuffer* = object
    buffer*: array[MessageNametagBufferSize, MessageNametag]
    counter*: uint64
    secret*: Option[array[MessageNametagSecretLength, byte]]

  PayloadV2* = object
    messageNametag*: MessageNametag
    protocolId*: uint8
    handshakeMessage*: seq[NoisePublicKey]
    transportMessage*: seq[byte]

  #################################
  # Some useful error types
  #################################
  NoiseError* = object of LPError
  NoiseHandshakeError* = object of NoiseError
  NoiseEmptyChaChaPolyInput* = object of NoiseError
  NoiseDecryptTagError* = object of NoiseError
  NoiseNonceMaxError* = object of NoiseError
  NoisePublicKeyError* = object of NoiseError
  NoiseMalformedHandshake* = object of NoiseError
  NoiseMessageNametagError* = object of NoiseError
  NoiseSomeMessagesWereLost* = object of NoiseError

#################################
# Constants (supported protocols)
#################################
const

  # The empty pre message patterns
  EmptyPreMessage*: seq[PreMessagePattern] = @[]

  # Supported Noise handshake patterns as defined in https://rfc.vac.dev/spec/35/#specification
  NoiseHandshakePatterns* = {
    "K1K1": HandshakePattern(
      name: "Noise_K1K1_25519_ChaChaPoly_SHA256",
      preMessagePatterns: @[
        PreMessagePattern(direction: D_r, tokens: @[T_s]),
        PreMessagePattern(direction: D_l, tokens: @[T_s]),
      ],
      messagePatterns: @[
        MessagePattern(direction: D_r, tokens: @[T_e]),
        MessagePattern(direction: D_l, tokens: @[T_e, T_ee, T_es]),
        MessagePattern(direction: D_r, tokens: @[T_se]),
      ],
    ),
    "XK1": HandshakePattern(
      name: "Noise_XK1_25519_ChaChaPoly_SHA256",
      preMessagePatterns: @[PreMessagePattern(direction: D_l, tokens: @[T_s])],
      messagePatterns: @[
        MessagePattern(direction: D_r, tokens: @[T_e]),
        MessagePattern(direction: D_l, tokens: @[T_e, T_ee, T_es]),
        MessagePattern(direction: D_r, tokens: @[T_s, T_se]),
      ],
    ),
    "XX": HandshakePattern(
      name: "Noise_XX_25519_ChaChaPoly_SHA256",
      preMessagePatterns: EmptyPreMessage,
      messagePatterns: @[
        MessagePattern(direction: D_r, tokens: @[T_e]),
        MessagePattern(direction: D_l, tokens: @[T_e, T_ee, T_s, T_es]),
        MessagePattern(direction: D_r, tokens: @[T_s, T_se]),
      ],
    ),
    "XXpsk0": HandshakePattern(
      name: "Noise_XXpsk0_25519_ChaChaPoly_SHA256",
      preMessagePatterns: EmptyPreMessage,
      messagePatterns: @[
        MessagePattern(direction: D_r, tokens: @[T_psk, T_e]),
        MessagePattern(direction: D_l, tokens: @[T_e, T_ee, T_s, T_es]),
        MessagePattern(direction: D_r, tokens: @[T_s, T_se]),
      ],
    ),
    "WakuPairing": HandshakePattern(
      name: "Noise_WakuPairing_25519_ChaChaPoly_SHA256",
      preMessagePatterns: @[PreMessagePattern(direction: D_l, tokens: @[T_e])],
      messagePatterns: @[
        MessagePattern(direction: D_r, tokens: @[T_e, T_ee]),
        MessagePattern(direction: D_l, tokens: @[T_s, T_es]),
        MessagePattern(direction: D_r, tokens: @[T_s, T_se, T_ss]),
      ],
    ),
  }.toTable()

  # Supported Protocol ID for PayloadV2 objects
  # Protocol IDs are defined according to https://rfc.vac.dev/spec/35/#specification
  PayloadV2ProtocolIDs* = {
    "": 0.uint8,
    "Noise_K1K1_25519_ChaChaPoly_SHA256": 10.uint8,
    "Noise_XK1_25519_ChaChaPoly_SHA256": 11.uint8,
    "Noise_XX_25519_ChaChaPoly_SHA256": 12.uint8,
    "Noise_XXpsk0_25519_ChaChaPoly_SHA256": 13.uint8,
    "Noise_WakuPairing_25519_ChaChaPoly_SHA256": 14.uint8,
    "ChaChaPoly": 30.uint8,
  }.toTable()

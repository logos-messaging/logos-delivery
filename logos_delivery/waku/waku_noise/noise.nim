# Waku Noise Protocols for Waku Payload Encryption
# Noise module implementing the Noise State Objects and ChaChaPoly encryption/decryption primitives
## See spec for more details:
## https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/35
##
## Implementation partially inspired by noise-libp2p:
## https://github.com/status-im/nim-libp2p/blob/master/libp2p/protocols/secure/noise.nim

{.push raises: [].}

import std/[options, strutils]
import stew/byteutils
import chronos
import chronicles
import bearssl/rand
import stew/endians2
import nimcrypto/[sha2, hmac]

import libp2p/utility
import libp2p/crypto/[crypto, chacha20poly1305, hkdf]
import libp2p/protocols/secure/secure

import ./noise_types

logScope:
  topics = "waku noise"

#################################################################

# Noise state machine primitives

# Overview :
# - Alice and Bob process (i.e. read and write, based on their role) each token appearing in a handshake pattern, consisting of pre-message and message patterns;
# - Both users initialize and update according to processed tokens a Handshake State, a Symmetric State and a Cipher State;
# - A preshared key psk is processed by calling MixKeyAndHash(psk);
# - When an ephemeral public key e is read or written, the handshake hash value h is updated by calling mixHash(e); If the handshake expects a psk, MixKey(e) is further called
# - When an encrypted static public key s or a payload message m is read, it is decrypted with decryptAndHash;
# - When a static public key s or a payload message is writted, it is encrypted with encryptAndHash;
# - When any Diffie-Hellman token ee, es, se, ss is read or written, the chaining key ck is updated by calling MixKey on the computed secret;
# - If all tokens are processed, users compute two new Cipher States by calling Split;
# - The two Cipher States obtained from Split are used to encrypt/decrypt outbound/inbound messages.

#################################
# Cipher State Primitives
#################################

# Checks if a Cipher State has an encryption key set
proc hasKey*(cs: CipherState): bool =
  return (cs.k != EmptyKey)

# Encrypts a plaintext using key material in a Noise Cipher State
# The CipherState is updated increasing the nonce (used as a counter in Noise) by one
proc encryptWithAd*(
    state: var CipherState, ad, plaintext: openArray[byte]
): seq[byte] {.raises: [Defect, NoiseNonceMaxError].} =
  # We raise an error if encryption is called using a Cipher State with nonce greater than  MaxNonce
  if state.n > NonceMax:
    raise newException(NoiseNonceMaxError, "Noise max nonce value reached")

  var ciphertext: seq[byte]

  # If an encryption key is set in the Cipher state, we proceed with encryption
  if state.hasKey:
    # The output is the concatenation of the ciphertext and authorization tag
    # We define its length accordingly
    ciphertext = newSeqOfCap[byte](plaintext.len + sizeof(ChaChaPolyTag))

    # Since ChaChaPoly encryption primitive overwrites the input with the output,
    # we copy the plaintext in the output ciphertext variable and we pass it to encryption
    ciphertext.add(plaintext)

    # The nonce is read from the input CipherState
    # By Noise specification the nonce is 8 bytes long out of the 12 bytes supported by ChaChaPoly
    var nonce: ChaChaPolyNonce
    nonce[4 ..< 12] = toBytesLE(state.n)

    # We perform encryption and we store the authorization tag
    var authorizationTag: ChaChaPolyTag
    ChaChaPoly.encrypt(state.k, nonce, authorizationTag, ciphertext, ad)

    # We append the authorization tag to ciphertext
    ciphertext.add(authorizationTag)

    # We increase the Cipher state nonce
    inc state.n
    # If the nonce is greater than the maximum allowed nonce, we raise an exception
    if state.n > NonceMax:
      raise newException(NoiseNonceMaxError, "Noise max nonce value reached")

    trace "encryptWithAd",
      authorizationTag = byteutils.toHex(authorizationTag),
      ciphertext = ciphertext,
      nonce = state.n - 1

  # Otherwise we return the input plaintext according to specification http://www.noiseprotocol.org/noise.html#the-cipherstate-object
  else:
    ciphertext = @plaintext
    info "encryptWithAd called with no encryption key set. Returning plaintext."

  return ciphertext

# Decrypts a ciphertext using key material in a Noise Cipher State
# The CipherState is updated increasing the nonce (used as a counter in Noise) by one
proc decryptWithAd*(
    state: var CipherState, ad, ciphertext: openArray[byte]
): seq[byte] {.raises: [Defect, NoiseDecryptTagError, NoiseNonceMaxError].} =
  # We raise an error if encryption is called using a Cipher State with nonce greater than  MaxNonce
  if state.n > NonceMax:
    raise newException(NoiseNonceMaxError, "Noise max nonce value reached")

  var plaintext: seq[byte]

  # If an encryption key is set in the Cipher state, we proceed with decryption
  if state.hasKey:
    # We read the authorization appendend at the end of a ciphertext
    let inputAuthorizationTag = ciphertext.toOpenArray(
      ciphertext.len - ChaChaPolyTag.len, ciphertext.high
    ).intoChaChaPolyTag

    var
      authorizationTag: ChaChaPolyTag
      nonce: ChaChaPolyNonce

    # The nonce is read from the input CipherState
    # By Noise specification the nonce is 8 bytes long out of the 12 bytes supported by ChaChaPoly
    nonce[4 ..< 12] = toBytesLE(state.n)

    # Since ChaChaPoly decryption primitive overwrites the input with the output,
    # we copy the ciphertext (authorization tag excluded) in the output plaintext variable and we pass it to decryption  
    plaintext = ciphertext[0 .. (ciphertext.high - ChaChaPolyTag.len)]

    ChaChaPoly.decrypt(state.k, nonce, authorizationTag, plaintext, ad)

    # We check if the input authorization tag matches the decryption authorization tag
    if inputAuthorizationTag != authorizationTag:
      info "decryptWithAd failed",
        plaintext = plaintext,
        ciphertext = ciphertext,
        inputAuthorizationTag = inputAuthorizationTag,
        authorizationTag = authorizationTag
      raise
        newException(NoiseDecryptTagError, "decryptWithAd failed tag authentication.")

    # We increase the Cipher state nonce
    inc state.n
    # If the nonce is greater than the maximum allowed nonce, we raise an exception
    if state.n > NonceMax:
      raise newException(NoiseNonceMaxError, "Noise max nonce value reached")

    trace "decryptWithAd",
      inputAuthorizationTag = inputAuthorizationTag,
      authorizationTag = authorizationTag,
      nonce = state.n

  # Otherwise we return the input ciphertext according to specification http://www.noiseprotocol.org/noise.html#the-cipherstate-object    
  else:
    plaintext = @ciphertext
    info "decryptWithAd called with no encryption key set. Returning ciphertext."

  return plaintext

# Sets the nonce of a Cipher State
proc setNonce*(cs: var CipherState, nonce: uint64) =
  cs.n = nonce

# Sets the key of a Cipher State
proc setCipherStateKey*(cs: var CipherState, key: ChaChaPolyKey) =
  cs.k = key

# Generates a random Symmetric Cipher State for test purposes
proc randomCipherState*(rng: var HmacDrbgContext, nonce: uint64 = 0): CipherState =
  var randomCipherState: CipherState
  hmacDrbgGenerate(rng, randomCipherState.k)
  setNonce(randomCipherState, nonce)
  return randomCipherState

# Gets the key of a Cipher State
proc getKey*(cs: CipherState): ChaChaPolyKey =
  return cs.k

# Gets the nonce of a Cipher State
proc getNonce*(cs: CipherState): uint64 =
  return cs.n

#################################
# Symmetric State primitives
#################################

# Initializes a Symmetric State
proc init*(_: type[SymmetricState], hsPattern: HandshakePattern): SymmetricState =
  var ss: SymmetricState
  # We compute the hash of the protocol name
  ss.h = hsPattern.name.hashProtocol
  # We initialize the chaining key ck
  ss.ck = ss.h.data.intoChaChaPolyKey
  # We initialize the Cipher state
  ss.cs = CipherState(k: EmptyKey)
  return ss

# MixKey as per Noise specification http://www.noiseprotocol.org/noise.html#the-symmetricstate-object
# Updates a Symmetric state chaining key and symmetric state
proc mixKey*(ss: var SymmetricState, inputKeyMaterial: openArray[byte]) =
  # We derive two keys using HKDF
  var tempKeys: array[2, ChaChaPolyKey]
  sha256.hkdf(ss.ck, inputKeyMaterial, [], tempKeys)
  # We update ck and the Cipher state's key k using the output of HDKF 
  ss.ck = tempKeys[0]
  ss.cs = CipherState(k: tempKeys[1])
  trace "mixKey", ck = ss.ck, k = ss.cs.k

# MixHash as per Noise specification http://www.noiseprotocol.org/noise.html#the-symmetricstate-object
# Hashes data into a Symmetric State's handshake hash value h
proc mixHash*(ss: var SymmetricState, data: openArray[byte]) =
  # We prepare the hash context
  var ctx: sha256
  ctx.init()
  # We add the previous handshake hash
  ctx.update(ss.h.data)
  # We append the input data
  ctx.update(data)
  # We hash and store the result in the Symmetric State's handshake hash value
  ss.h = ctx.finish()
  trace "mixHash", hash = ss.h.data

# mixKeyAndHash as per Noise specification http://www.noiseprotocol.org/noise.html#the-symmetricstate-object
# Combines MixKey and MixHash
proc mixKeyAndHash*(
    ss: var SymmetricState, inputKeyMaterial: openArray[byte]
) {.used.} =
  var tempKeys: array[3, ChaChaPolyKey]
  # Derives 3 keys using HKDF, the chaining key and the input key material
  sha256.hkdf(ss.ck, inputKeyMaterial, [], tempKeys)
  # Sets the chaining key
  ss.ck = tempKeys[0]
  # Updates the handshake hash value
  ss.mixHash(tempKeys[1])
  # Updates the Cipher state's key
  # Note for later support of 512 bits hash functions: "If HASHLEN is 64, then truncates tempKeys[2] to 32 bytes."
  ss.cs = CipherState(k: tempKeys[2])

# EncryptAndHash as per Noise specification http://www.noiseprotocol.org/noise.html#the-symmetricstate-object
# Combines encryptWithAd and mixHash
# Note that by setting extraAd, it is possible to pass extra additional data that will be concatenated to the ad specified by Noise (can be used to authenticate messageNametag)
proc encryptAndHash*(
    ss: var SymmetricState, plaintext: openArray[byte], extraAd: openArray[byte] = []
): seq[byte] {.raises: [Defect, NoiseNonceMaxError].} =
  # The output ciphertext
  var ciphertext: seq[byte]
  # The additional data
  let ad = @(ss.h.data) & @(extraAd)
  # Note that if an encryption key is not set yet in the Cipher state, ciphertext will be equal to plaintex
  ciphertext = ss.cs.encryptWithAd(ad, plaintext)
  # We call mixHash over the result
  ss.mixHash(ciphertext)
  return ciphertext

# DecryptAndHash as per Noise specification http://www.noiseprotocol.org/noise.html#the-symmetricstate-object
# Combines decryptWithAd and mixHash
proc decryptAndHash*(
    ss: var SymmetricState, ciphertext: openArray[byte], extraAd: openArray[byte] = []
): seq[byte] {.raises: [Defect, NoiseDecryptTagError, NoiseNonceMaxError].} =
  # The output plaintext
  var plaintext: seq[byte]
  # The additional data
  let ad = @(ss.h.data) & @(extraAd)
  # Note that if an encryption key is not set yet in the Cipher state, plaintext will be equal to ciphertext
  plaintext = ss.cs.decryptWithAd(ad, ciphertext)
  # According to specification, the ciphertext enters mixHash (and not the plaintext)
  ss.mixHash(ciphertext)
  return plaintext

# Split as per Noise specification http://www.noiseprotocol.org/noise.html#the-symmetricstate-object
# Once a handshake is complete, returns two Cipher States to encrypt/decrypt outbound/inbound messages
proc split*(ss: var SymmetricState): tuple[cs1, cs2: CipherState] =
  # Derives 2 keys using HKDF and the chaining key
  var tempKeys: array[2, ChaChaPolyKey]
  sha256.hkdf(ss.ck, [], [], tempKeys)
  # Returns a tuple of two Cipher States initialized with the derived keys
  return (CipherState(k: tempKeys[0]), CipherState(k: tempKeys[1]))

# Gets the chaining key field of a Symmetric State
proc getChainingKey*(ss: SymmetricState): ChaChaPolyKey =
  return ss.ck

# Gets the handshake hash field of a Symmetric State
proc getHandshakeHash*(ss: SymmetricState): MDigest[256] =
  return ss.h

# Gets the Cipher State field of a Symmetric State
proc getCipherState*(ss: SymmetricState): CipherState =
  return ss.cs

#################################
# Handshake State primitives
#################################

# Initializes a Handshake State
proc init*(
    _: type[HandshakeState], hsPattern: HandshakePattern, psk: seq[byte] = @[]
): HandshakeState =
  # The output Handshake State
  var hs: HandshakeState
  # By default the Handshake State initiator flag is set to false
  # Will be set to true when the user associated to the handshake state starts an handshake
  hs.initiator = false
  # We copy the information on the handshake pattern for which the state is initialized (protocol name, handshake pattern, psk)
  hs.handshakePattern = hsPattern
  hs.psk = psk
  # We initialize the Symmetric State
  hs.ss = SymmetricState.init(hsPattern)
  return hs

#################################################################

#################################
# ChaChaPoly Symmetric Cipher
#################################

# ChaChaPoly encryption
# It takes a Cipher State (with key, nonce, and associated data) and encrypts a plaintext
# The cipher state in not changed
proc encrypt*(
    state: ChaChaPolyCipherState, plaintext: openArray[byte]
): ChaChaPolyCiphertext {.noinit, raises: [Defect, NoiseEmptyChaChaPolyInput].} =
  # If plaintext is empty, we raise an error
  if plaintext == @[]:
    raise newException(NoiseEmptyChaChaPolyInput, "Tried to encrypt empty plaintext")
  var ciphertext: ChaChaPolyCiphertext
  # Since ChaChaPoly's library "encrypt" primitive directly changes the input plaintext to the ciphertext,
  # we copy the plaintext into the ciphertext variable and we pass the latter to encrypt
  ciphertext.data.add plaintext
  # TODO: add padding
  # ChaChaPoly.encrypt takes as input: the key (k), the nonce (nonce), a data structure for storing the computed authorization tag (tag), 
  # the plaintext (overwritten to ciphertext) (data), the associated data (ad)
  ChaChaPoly.encrypt(state.k, state.nonce, ciphertext.tag, ciphertext.data, state.ad)
  return ciphertext

# ChaChaPoly decryption
# It takes a Cipher State (with key, nonce, and associated data) and decrypts a ciphertext
# The cipher state is not changed
proc decrypt*(
    state: ChaChaPolyCipherState, ciphertext: ChaChaPolyCiphertext
): seq[byte] {.raises: [Defect, NoiseEmptyChaChaPolyInput, NoiseDecryptTagError].} =
  # If ciphertext is empty, we raise an error
  if ciphertext.data == @[]:
    raise newException(NoiseEmptyChaChaPolyInput, "Tried to decrypt empty ciphertext")
  var
    # The input authorization tag
    tagIn = ciphertext.tag
    # The authorization tag computed during decryption
    tagOut: ChaChaPolyTag
  # Since ChaChaPoly's library "decrypt" primitive directly changes the input ciphertext to the plaintext,
  # we copy the ciphertext into the plaintext variable and we pass the latter to decrypt
  var plaintext = ciphertext.data
  # ChaChaPoly.decrypt takes as input: the key (k), the nonce (nonce), a data structure for storing the computed authorization tag (tag), 
  # the ciphertext (overwritten to plaintext) (data), the associated data (ad)
  ChaChaPoly.decrypt(state.k, state.nonce, tagOut, plaintext, state.ad)
  # TODO: add unpadding
  trace "decrypt", tagIn = tagIn, tagOut = tagOut, nonce = state.nonce
  # We check if the authorization tag computed while decrypting is the same as the input tag
  if tagIn != tagOut:
    info "decrypt failed", plaintext = shortLog(plaintext)
    raise newException(NoiseDecryptTagError, "decrypt tag authentication failed.")
  return plaintext

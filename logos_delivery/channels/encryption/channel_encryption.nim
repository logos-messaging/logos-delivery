## Pluggable per-channel encryption, supplied to `createReliableChannel`.
## No scheme is mandated.
##
## Applied per segment *inside* the SDS wrap, so the ciphertext is the SDS
## `content` field: routing metadata stays readable, SDS's caches hold
## ciphertext, and repairs replay the wire verbatim. Decrypt sees segments
## in network order, so each result must carry its own nonce or key id.
##
## That readable metadata (channelId, senderId, causal history) is exposed
## on the wire; protecting it is logos-messaging/logos-delivery#4239.
##
## A channel created with a cipher always uses it, and a failure fails the
## message -- never a fallback to plaintext. A channel created without one
## sends and receives plaintext.

{.push raises: [].}

import results, chronos

import ../types

type ChannelCrypto* = object
  ## Only constructible through `init`, which rejects a half-nil pair, so a
  ## channel's cipher always has both directions.
  encryptFn: ChannelCryptoFn
  decryptFn: ChannelCryptoFn

func init*(
    T: type ChannelCrypto, encrypt: ChannelCryptoFn, decrypt: ChannelCryptoFn
): Result[T, string] =
  if encrypt.isNil():
    return err("encrypt callback is nil")
  if decrypt.isNil():
    return err("decrypt callback is nil")
  return ok(T(encryptFn: encrypt, decryptFn: decrypt))

proc encrypt*(
    self: ChannelCrypto, segments: seq[seq[byte]]
): Future[Result[seq[seq[byte]], string]] {.async: (raises: []).} =
  ## All segments or none. Fails closed: one failure aborts the whole
  ## message rather than letting any plaintext reach the wire.
  var encrypted = newSeqOfCap[seq[byte]](segments.len)
  for segment in segments:
    let sealed = (await self.encryptFn(segment)).valueOr:
      return err(error)
    encrypted.add(sealed)
  return ok(encrypted)

proc decrypt*(
    self: ChannelCrypto, ciphertext: seq[byte]
): Future[Result[seq[byte], string]] {.async: (raises: []).} =
  ## One at a time, unlike `encrypt`: inbound deliverables are independent
  ## messages, so a bad key on one must not discard the rest.
  return await self.decryptFn(ciphertext)

{.pop.}

## Per-channel encryption: `channelId -> encrypt/decrypt` closures supplied
## by the application. No scheme is mandated.
##
## Applied per segment *inside* the SDS wrap, so the ciphertext is the SDS
## `content` field: routing metadata stays readable, SDS's caches hold
## ciphertext, and repairs replay the wire verbatim. Decrypt sees segments
## in network order, so each result must carry its own nonce or key id.
##
## A registered pair is always used and its failure fails the message --
## never plaintext; no entry means passthrough. Register before
## `createReliableChannel` (the channel is live at once); the entry
## survives `closeChannel`, which is reversible.

{.push raises: [].}

import std/tables
import results, chronos, chronicles

import ../types

logScope:
  topics = "reliable-channel encryption"

type
  ChannelCrypto* = object
    ## Only constructible through `init`, which rejects a half-nil pair, so
    ## a registered cipher always has both directions.
    encryptFn: ChannelCryptoFn
    decryptFn: ChannelCryptoFn

  ChannelEncryptionRegistry* = ref object
    entries: Table[ChannelId, ChannelCrypto]

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

func new*(T: type ChannelEncryptionRegistry): T =
  return T(entries: initTable[ChannelId, ChannelCrypto]())

proc setChannelEncryption*(
    self: ChannelEncryptionRegistry,
    channelId: ChannelId,
    encrypt: ChannelCryptoFn,
    decrypt: ChannelCryptoFn,
): Result[void, string] =
  ## Replaces any pair already registered for `channelId`.
  if self.isNil():
    return err("encryption registry is not available")

  let crypto = ?ChannelCrypto.init(encrypt, decrypt)
  self.entries[channelId] = crypto

  info "channel encryption registered", channelId = channelId
  return ok()

proc clearChannelEncryption*(
    self: ChannelEncryptionRegistry, channelId: ChannelId
): Result[void, string] =
  if self.isNil():
    return err("encryption registry is not available")
  if not self.entries.hasKey(channelId):
    return err("no encryption registered for channel: " & channelId)

  self.entries.del(channelId)

  # A downgrade to plaintext must never be silent, but it is a requested
  # operation, so not WARN: a healthy node logs nothing above NOTICE.
  notice "channel encryption cleared, channel now sends plaintext",
    channelId = channelId
  return ok()

func getChannelCrypto*(
    self: ChannelEncryptionRegistry, channelId: ChannelId
): Opt[ChannelCrypto] =
  ## `none` means the channel is not encrypted, which is a valid state and
  ## not a failure.
  if self.isNil() or not self.entries.hasKey(channelId):
    return Opt.none(ChannelCrypto)
  return Opt.some(self.entries.getOrDefault(channelId))

func len*(self: ChannelEncryptionRegistry): int =
  if self.isNil(): 0 else: self.entries.len

func clear*(self: ChannelEncryptionRegistry) =
  if not self.isNil():
    self.entries.clear()

{.pop.}

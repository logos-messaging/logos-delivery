## Per-channel encryption: `channelId -> encrypt/decrypt` closures supplied
## by the application. No scheme is mandated.
##
## Applied to one segment at a time, *inside* the SDS wrap: the ciphertext
## becomes the SDS `content` field, so routing metadata stays readable and
## SDS's history and repair cache hold ciphertext. Repairs therefore replay
## the wire verbatim and never re-enter a cipher.
##
## Decrypt sees segments in network order, so each output must carry what
## decrypting it needs (a nonce, a key id) rather than relying on
## invocation order.
##
## Two rules:
##   - a registered pair is always used; if it fails, the message fails.
##     There is no fallback to plaintext.
##   - no entry means no encryption; the payload passes through.
##
## Registration is independent of channel existence, so an app can register
## before `createReliableChannel` (no window where traffic arrives on a
## channel with no cipher) and it survives `closeChannel` (which is
## reversible, so clearing there would silently downgrade a re-created
## channel).

{.push raises: [].}

import std/tables
import results, chronicles

import ../types

logScope:
  topics = "reliable-channel encryption"

type
  ChannelCrypto* = object
    ## Only constructible via `init`, so a stored pair is never nil.
    encrypt: ChannelCryptoFn
    decrypt: ChannelCryptoFn

  ChannelEncryptionRegistry* = ref object
    ## Owned by `ReliableChannelManager`, shared by reference with every
    ## channel it creates.
    entries: Table[ChannelId, ChannelCrypto]

func init*(
    T: type ChannelCrypto, encrypt: ChannelCryptoFn, decrypt: ChannelCryptoFn
): Result[T, string] =
  if encrypt.isNil():
    return err("encrypt callback is nil")
  if decrypt.isNil():
    return err("decrypt callback is nil")
  return ok(T(encrypt: encrypt, decrypt: decrypt))

func encryptFn*(self: ChannelCrypto): ChannelCryptoFn {.inline.} =
  self.encrypt

func decryptFn*(self: ChannelCrypto): ChannelCryptoFn {.inline.} =
  self.decrypt

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
  if self.isNil():
    return Opt.none(ChannelCrypto)
  try:
    return Opt.some(self.entries[channelId])
  except KeyError:
    return Opt.none(ChannelCrypto)

func len*(self: ChannelEncryptionRegistry): int =
  if self.isNil(): 0 else: self.entries.len

func clear*(self: ChannelEncryptionRegistry) =
  if not self.isNil():
    self.entries.clear()

{.pop.}

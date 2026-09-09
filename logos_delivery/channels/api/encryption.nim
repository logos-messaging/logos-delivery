## Reliable Channel layer API — per-channel encryption registration.
import results

import logos_delivery/channels/reliable_channel_manager
import logos_delivery/channels/encryption/channel_encryption

export channel_encryption

proc setChannelEncryption*(
    self: ReliableChannelManager,
    channelId: ChannelId,
    encrypt: ChannelCryptoFn,
    decrypt: ChannelCryptoFn,
): Result[void, string] =
  ## Registers the cipher used for every send, repair rebroadcast and
  ## receive on `channelId`.
  ##
  ## Call this *before* `createReliableChannel`: the channel goes live as
  ## soon as it is created, and anything that arrives before a cipher is
  ## registered cannot be decrypted and is dropped. Calling it on a live
  ## channel is allowed, for key rotation, and takes effect on the next
  ## message -- sends already in flight keep the cipher they started with.
  return self.encryption.setChannelEncryption(channelId, encrypt, decrypt)

proc clearChannelEncryption*(
    self: ReliableChannelManager, channelId: ChannelId
): Result[void, string] =
  ## Reverts the channel to plaintext for new messages; a send already in
  ## flight keeps the cipher it started with. `closeChannel` does not do
  ## this. Traffic already sent stays encrypted, repairs included.
  return self.encryption.clearChannelEncryption(channelId)

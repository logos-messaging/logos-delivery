## Reliable Channel API entry point.
##
## Owns the set of `ReliableChannel` instances and exposes lifecycle and
## send/receive operations addressed by `ChannelId`.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/tables
import results
import chronos
import chronicles
import stew/byteutils

import brokers/broker_context

import logos_delivery/api/types
import logos_delivery/api/reliable_channel_manager_api
import logos_delivery/api/messaging_client_api
import logos_delivery/api/conf/channels_conf

import ./reliable_channel
import ./encryption/channel_encryption

export reliable_channel, channels_conf

type ReliableChannelManager* = ref object ## Implements `ReliableChannelApi`.
  channels*: Table[ChannelId, ReliableChannel] ## read by `channels/api.nim`
  conf*: ReliableChannelManagerConf
  brokerCtx*: BrokerContext
  encryption*: ChannelEncryptionRegistry
    ## `channelId -> cipher`. Outlives individual channels on purpose.

proc new*(
    T: type ReliableChannelManager,
    conf: ReliableChannelManagerConf,
    brokerCtx: BrokerContext = globalBrokerContext(),
): Result[T, string] =
  if conf.rateLimitEnabled.isSome() or conf.rateLimitEpochPeriodSec.isSome() or
      conf.rateLimitMessagesPerEpoch.isSome():
    warn "channel-level rate-limit config is deprecated and ignored; " &
      "rate limiting moved to the messaging client (MessagingClientConf.rateLimit)"

  return ok(
    T(
      channels: initTable[ChannelId, ReliableChannel](),
      conf: conf,
      brokerCtx: brokerCtx,
      encryption: ChannelEncryptionRegistry.new(),
    )
  )

proc start*(self: ReliableChannelManager): Result[void, string] =
  ## Per-channel listeners are installed in `ReliableChannel.new`, so only
  ## deferred subscriptions are left to wire up here.
  # Subscribe channels created before the MessagingSubscribe provider existed.
  if MessagingSubscribe.isProvided(self.brokerCtx):
    for chn in self.channels.values:
      MessagingSubscribe.request(self.brokerCtx, chn.getContentTopic()).isOkOr:
        warn "failed to subscribe channel's content topic",
          channelId = chn.getChannelId(),
          contentTopic = chn.getContentTopic(),
          error = error
  ok()

proc stop*(self: ReliableChannelManager) {.async.} =
  ## Stops every channel's SDS background loops. Persisted state survives.
  for chn in self.channels.values:
    await chn.stop()
  self.channels.clear()
  let registeredCiphers = self.encryption.len
  self.encryption.clear()
  if registeredCiphers > 0:
    notice "channel encryption registrations dropped on manager stop; " &
      "re-register before restarting, or channels resume in plaintext",
      count = registeredCiphers

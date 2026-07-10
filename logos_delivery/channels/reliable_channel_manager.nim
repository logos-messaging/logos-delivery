## Reliable Channel API entry point.
##
## Owns the set of `ReliableChannel` instances and exposes lifecycle and
## send/receive operations addressed by `ChannelId`.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/[options, tables]
import results
import chronos
import chronicles
import stew/byteutils

import brokers/broker_context

import logos_delivery/api/types
import logos_delivery/api/reliable_channel_manager_api

import ./reliable_channel

export reliable_channel

type
  ReliableChannelManagerConf* = object
    ## All-`Option` partial; unset fields fall back to `createReliableChannel` defaults.
    segmentationEnableReedSolomon*: Option[bool]
      ## Add Reed-Solomon parity segments for recovery of lost segments.
    segmentationSegmentSizeBytes*: Option[int] ## Maximum segment size in bytes.
    sdsAcknowledgementTimeoutMs*: Option[int]
      ## Time to wait before retransmitting an unacknowledged message.
    sdsMaxRetransmissions*: Option[int]
      ## Maximum retransmission attempts before delivery fails.
    sdsCausalHistorySize*: Option[int] ## Number of message ids kept in causal history.
    rateLimitEnabled*: Option[bool] ## Enable rate limiting.
    rateLimitEpochPeriodSec*: Option[int] ## Rate-limit epoch length in seconds.
    rateLimitMessagesPerEpoch*: Option[int] ## Messages allowed per rate-limit epoch.

  ReliableChannelManager* = ref object ## Implements `ReliableChannelApi`.
    channels*: Table[ChannelId, ReliableChannel] ## read by `channels/api.nim`
    conf*: ReliableChannelManagerConf
    brokerCtx*: BrokerContext

proc new*(
    T: type ReliableChannelManager,
    conf: ReliableChannelManagerConf,
    brokerCtx: BrokerContext = globalBrokerContext(),
): Result[T, string] =
  return ok(
    T(
      channels: initTable[ChannelId, ReliableChannel](),
      conf: conf,
      brokerCtx: brokerCtx,
    )
  )

proc start*(self: ReliableChannelManager): Result[void, string] =
  ## Placeholder: per-channel listeners are installed in `ReliableChannel.new`,
  ## so the manager has nothing to start at this layer. Kept for symmetry
  ## with the `Waku` mount/start lifecycle and as a hook for future state.
  discard
  ok()

proc stop*(self: ReliableChannelManager) {.async.} =
  ## Stops every channel's SDS background loops. Persisted state survives.
  for chn in self.channels.values:
    await chn.stop()
  self.channels.clear()

## Inbound messages are not handed to the manager by direct call. Each
## `ReliableChannel` installs its own `MessageReceivedEvent` listener
## in `ReliableChannel.new`, filters by spec marker and `contentTopic`,
## and routes to its private `onMessageReceived`. This keeps the lower
## layer (MessagingClient/Waku) unaware of the existence of ReliableChannel
## and keeps the manager out of per-channel event dispatch.

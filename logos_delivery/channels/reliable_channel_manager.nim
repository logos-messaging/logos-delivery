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
    ## Per-layer config object for the reliable
    ## channel API. Placeholder for now (segmentation / SDS / rate-limit defaults
    ## will move here in a follow-up PR); kept so each layer owns its own config.

  ReliableChannelManager*[M: MessagingSender] = ref object
    ## Owns the set of channels and the messaging node they dispatch through.
    ## Generic over the egress `M`; hands the node to every channel it creates.
    ## Holding the node here keeps `createReliableChannel` node-free — the
    ## node-bound consumer surface the `ReliableChannelApi` concept describes.
    channels*: Table[ChannelId, ReliableChannel[M]] ## read by `channels/api.nim`
    messaging*: M ## egress node, passed on to each `ReliableChannel`
    brokerCtx*: BrokerContext

proc new*[M: MessagingSender](
    T: type ReliableChannelManager,
    conf: ReliableChannelManagerConf,
    messaging: M,
    brokerCtx: BrokerContext = globalBrokerContext(),
): Result[ReliableChannelManager[M], string] =
  return ok(
    ReliableChannelManager[M](
      channels: initTable[ChannelId, ReliableChannel[M]](),
      messaging: messaging,
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

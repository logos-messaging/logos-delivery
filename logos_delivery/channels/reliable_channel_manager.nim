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
import logos_delivery/api/conf/channels_conf

import ./reliable_channel
import ./encryption/noop_encryption

export reliable_channel, channels_conf

type ReliableChannelManager* = ref object ## Implements `ReliableChannelApi`.
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
  ## Per-channel listeners are installed in `ReliableChannel.new`, so the only
  ## thing to wire up here is the encryption brokers. Channels encrypt on egress
  ## and decrypt on ingress via the `Encrypt`/`Decrypt` request brokers; with no
  ## provider registered every send and receive would fail, so `channel_send`
  ## would never reach the wire and `ChannelMessageReceivedEvent` would never
  ## fire. Install the pass-through noop so channels default to unencrypted
  ## payloads. `setProvider` refuses to overwrite, so an application that
  ## installed its own encryption before start keeps it.
  setNoopEncryption()
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

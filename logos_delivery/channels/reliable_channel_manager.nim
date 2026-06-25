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

import logos_delivery/messaging/messaging_client
import logos_delivery/messaging/api/send
import logos_delivery/api/types

import ./reliable_channel

export reliable_channel

type
  ReliableChannelManagerConf* = object
    ## Per-layer config object for the reliable
    ## channel API. Placeholder for now (segmentation / SDS / rate-limit defaults
    ## will move here in a follow-up PR); kept so each layer owns its own config.

  ReliableChannelManager* = ref object
    channels*: Table[ChannelId, ReliableChannel] ## read by `channels/api.nim`
    messagingClient: MessagingClient ## The channel layer chains onto messaging.
    sendHandler*: SendHandler
      ## Default egress dispatch for channels created through this manager.
      ## Built in `new` as a closure over `MessagingClient.send` so the channel
      ## layer itself stays callable-only.
    brokerCtx*: BrokerContext

proc new*(
    T: type ReliableChannelManager,
    conf: ReliableChannelManagerConf,
    messagingClient: MessagingClient,
    brokerCtx: BrokerContext = globalBrokerContext(),
): Result[T, string] =
  ## The reliable channel layer chains onto the messaging layer: its default
  ## egress is `MessagingClient.send`, wrapped here so callers never wire the
  ## handler themselves.
  if messagingClient.isNil():
    return err("messaging client is required")

  let defaultSendHandler: SendHandler = proc(
      envelope: MessageEnvelope
  ): Future[Result[RequestId, string]] {.async: (raises: [CatchableError]), gcsafe.} =
    return await messagingClient.send(envelope)

  return ok(
    T(
      channels: initTable[ChannelId, ReliableChannel](),
      messagingClient: messagingClient,
      sendHandler: defaultSendHandler,
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

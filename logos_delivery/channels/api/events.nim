## Reliable Channel layer API — event surface.
##
## Lifecycle events for individual segments (sent / propagated / errored)
## are the same as the network-level ones the MessagingClient already
## emits — `requestId` is shared across layers — so we just re-export
## `messaging/api/events` and avoid declaring duplicates.
##
## Only the channel-level `MessageReceivedEvent` carries data that has
## no analogue in the lower layer (reassembled application payload,
## senderId, channelId), so it lives here.

import logos_delivery/messaging/api/events as messaging_events
import brokers/event_broker

import logos_delivery/channels/types as channel_types

export messaging_events, channel_types, event_broker

EventBroker:
  type ChannelMessageReceivedEvent* = object
    channelId*: ChannelId
    senderId*: SdsParticipantID
    payload*: seq[byte]

EventBroker:
  ## Emitted when every segment of a channel-level `send()` reached
  ## `Confirmed`. Channel-level analogue of `MessageSentEvent`; the
  ## `requestId` is the channel-layer parent returned by `send()`.
  type ChannelMessageSentEvent* = object
    channelId*: ChannelId
    requestId*: RequestId

EventBroker:
  ## Emitted when a channel-level `send()` finalises with at least one
  ## segment in `Failed`. Channel-level analogue of `MessageErrorEvent`.
  type ChannelMessageErrorEvent* = object
    channelId*: ChannelId
    requestId*: RequestId
    error*: string

## Reliable Channel event types emitted to API consumers.
##
## Lifecycle events for individual segments (sent / propagated / errored)
## are the same as the network-level ones the DeliveryService already
## emits — `requestId` is shared across layers — so we just re-export
## `waku/events/message_events` and avoid declaring duplicates.
##
## Only the channel-level `MessageReceivedEvent` carries data that has
## no analogue in the lower layer (reassembled application payload,
## senderId, channelId), so it lives here.

import waku/events/message_events as waku_message_events
import brokers/event_broker

import ./types as channel_types

export waku_message_events, channel_types, event_broker

EventBroker:
  type ChannelMessageReceivedEvent* = object
    channelId*: ChannelId
    senderId*: SdsParticipantID
    payload*: seq[byte]

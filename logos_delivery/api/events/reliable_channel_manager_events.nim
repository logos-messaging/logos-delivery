import brokers/event_broker

import logos_delivery/channels/types as channel_types

export event_broker, channel_types

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

EventBroker:
  ## Emitted when an inbound payload can no longer be reassembled: its segment
  ## set expired, was evicted under memory pressure, or failed its integrity
  ## check. There is no `requestId` -- the send was a peer's.
  type ChannelMessageLostEvent* = object
    channelId*: ChannelId
    payloadHash*: seq[byte]
    reason*: string

## Reliable Channel event types emitted to API consumers.

import waku/api/types

import ./types as channel_types

export types, channel_types

type
  MessageReceivedEvent* = object
    channelId*: ChannelId
    senderId*: SdsParticipantID
    payload*: seq[byte]

  MessageSentEvent* = object
    requestId*: ReliableRequestId

  MessageDeliveredEvent* = object
    requestId*: ReliableRequestId

  MessageSendErrorEvent* = object
    requestId*: ReliableRequestId
    reason*: string

  MessageDeliveryErrorEvent* = object
    requestId*: ReliableRequestId
    reason*: string

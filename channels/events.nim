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
    requestId*: RequestId

  MessageDeliveredEvent* = object
    requestId*: RequestId

  MessageSendErrorEvent* = object
    requestId*: RequestId
    reason*: string

  MessageDeliveryErrorEvent* = object
    requestId*: RequestId
    reason*: string

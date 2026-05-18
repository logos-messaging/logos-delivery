## Reliable Channel event types emitted to API consumers.

import ./scalable_data_sync/scalable_data_sync

type
  ChannelId* = SdsChannelID
  RequestId* = string

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

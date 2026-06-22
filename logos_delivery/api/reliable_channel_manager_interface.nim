## ReliableChannelManagerInterface — create / close / send on a reliable channel,
## plus a MessageReceived event (bridged from the channel layer's own
## ChannelMessageReceivedEvent by the impl).

import results, chronos
import brokers/broker_interface

import logos_delivery/api/types
export types

BrokerInterface(ReliableChannelManagerInterface):
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

  RequestBroker:
    # Returns the channel id of the created channel.
    proc createReliableChannel(
      channelId: ChannelId, contentTopic: ContentTopic, senderId: SdsParticipantID
    ): Future[Result[ChannelId, string]] {.async.}

  RequestBroker:
    proc closeChannel(channelId: ChannelId): Future[Result[void, string]] {.async.}

  RequestBroker:
    # Returns the RequestId in its string form. Named `sendOnChannel` (not `send`)
    # for the global-verb-uniqueness reason noted on MessagingClientInterface.sendMessage.
    proc sendOnChannel(
      channelId: ChannelId, payload: seq[byte], ephemeral: bool
    ): Future[Result[RequestId, string]] {.async.}

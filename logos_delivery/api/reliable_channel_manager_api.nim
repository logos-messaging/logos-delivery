import chronos, results

import brokers/event_broker

import logos_delivery/api/types as api_types
import logos_delivery/channels/types as channel_types

# The channel layer re-uses the messaging-layer message events (the `requestId`
# is shared across layers), so it re-exports the messaging interface's event
# surface and only adds the channel-level events that have no lower-layer
# analogue (reassembled payload / senderId / channelId).
import logos_delivery/api/messaging_client_api

export event_broker, api_types
export channel_types, messaging_client_api

type
  SendHandler* = proc(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.
    async: (raises: [CatchableError]), gcsafe
  .}
    ## Egress dispatch boundary. Typically wraps `MessagingClient.send`;
    ## tests inject a fake that records calls and returns canned
    ## `RequestId`s so the send state machine can be exercised end-to-end
    ## without a network.

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

# Structural API contract for the reliable-channel surface (ops in `channels/api/*`).
type ReliableChannelApi* = concept c
  createReliableChannel(c, ChannelId, ContentTopic, SdsParticipantID) is
    Result[ChannelId, string]
  closeChannel(c, ChannelId) is Future[Result[void, string]]
  send(c, ChannelId, seq[byte]) is Future[Result[RequestId, string]]

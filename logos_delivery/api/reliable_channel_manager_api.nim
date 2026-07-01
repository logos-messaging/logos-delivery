import chronos, results

import logos_delivery/api/types as api_types
import logos_delivery/channels/types as channel_types

export api_types, channel_types

type SendHandler* = proc(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.
  async: (raises: [CatchableError]), gcsafe
.}
  ## Egress dispatch boundary. Typically wraps `MessagingClient.send`;
  ## tests inject a fake that records calls and returns canned
  ## `RequestId`s so the send state machine can be exercised end-to-end
  ## without a network.

# Structural API contract for the reliable-channel surface (ops in `channels/api/*`).
type ReliableChannelApi* = concept c
  createReliableChannel(
    c, channelId = ChannelId, contentTopic = ContentTopic, senderId = SdsParticipantID
  ) is Result[ChannelId, string]
  closeChannel(c, channelId = ChannelId) is Future[Result[void, string]]
  send(c, channelId = ChannelId, appPayload = seq[byte]) is
    Future[Result[RequestId, string]]

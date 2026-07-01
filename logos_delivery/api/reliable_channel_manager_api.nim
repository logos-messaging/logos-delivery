import chronos, results

import logos_delivery/api/types as api_types
import logos_delivery/api/messaging_client_api
import logos_delivery/channels/types as channel_types

# `messaging_client_api` is re-exported for `MessagingSender`, the egress
# capability the generic `ReliableChannel[M]`/`ReliableChannelManager[M]` need.
export api_types, messaging_client_api, channel_types

# Structural API contract for the reliable-channel surface. This is the
# node-bound consumer view (the messaging node is already bound), so it is
# satisfied by `LogosDelivery` — the concentrator that owns the node — rather
# than by the manager, whose `createReliableChannel` takes the node explicitly.
type ReliableChannelApi* = concept c
  createReliableChannel(
    c, channelId = ChannelId, contentTopic = ContentTopic, senderId = SdsParticipantID
  ) is Result[ChannelId, string]
  closeChannel(c, channelId = ChannelId) is Future[Result[void, string]]
  send(c, channelId = ChannelId, appPayload = seq[byte]) is
    Future[Result[RequestId, string]]

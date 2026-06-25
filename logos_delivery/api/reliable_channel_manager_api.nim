import chronos, results

import brokers/event_broker

import logos_delivery/api/types as api_types

# The channel-layer event surface lives in the decomposed `channels/api/events`
# module. Re-export it here so the events stay reachable at the interface level
# without duplicating the EventBroker types.
import logos_delivery/channels/api/events as channel_events

export event_broker, api_types
export channel_events

type
  IReliableChannelManager* = ref object of RootObj

  SendHandler* = proc(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.
    async: (raises: [CatchableError]), gcsafe
  .}
    ## Egress dispatch boundary. Typically wraps `MessagingClient.send`;
    ## tests inject a fake that records calls and returns canned
    ## `RequestId`s so the send state machine can be exercised end-to-end
    ## without a network.

method createReliableChannel*(
    self: IReliableChannelManager,
    channelId: ChannelId,
    contentTopic: ContentTopic,
    senderId: SdsParticipantID,
    sendHandler: SendHandler = nil,
): Result[ChannelId, string] {.base.} =
  return err("Interface IReliableChannelManager.createReliableChannel not implemented")

method closeChannel*(
    self: IReliableChannelManager, channelId: ChannelId
): Future[Result[void, string]] {.async: (raises: []), base.} =
  return err("Interface IReliableChannelManager.closeChannel not implemented")

method send*(
    self: IReliableChannelManager,
    channelId: ChannelId,
    appPayload: seq[byte],
    ephemeral: bool = false,
): Future[Result[RequestId, string]] {.async: (raises: []), base.} =
  return err("Interface IReliableChannelManager.send not implemented")

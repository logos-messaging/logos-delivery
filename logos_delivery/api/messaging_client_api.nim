import chronos, results
import brokers/event_broker

import logos_delivery/api/types as api_types

# The messaging-layer event surface lives in the decomposed
# `messaging/api/events` module. Re-export it here so the events stay reachable
# at the interface level without duplicating the EventBroker types.
import logos_delivery/messaging/api/events as messaging_events

export event_broker, api_types
export messaging_events

type IMessagingClient* = ref object of RootObj

method subscribe*(
    self: IMessagingClient, contentTopic: ContentTopic
): Future[Result[void, string]] {.async: (raises: []), base.} =
  return err("Interface IMessagingClient.subscribe not implemented")

method unsubscribe*(
    self: IMessagingClient, contentTopic: ContentTopic
): Result[void, string] {.base, raises: [].} =
  return err("Interface IMessagingClient.unsubscribe not implemented")

method send*(
    self: IMessagingClient, envelope: MessageEnvelope
): Future[Result[RequestId, string]] {.async: (raises: []), base.} =
  return err("Interface IMessagingClient.send not implemented")

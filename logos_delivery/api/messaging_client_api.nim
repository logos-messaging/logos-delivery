import chronos, results
import brokers/event_broker

import logos_delivery/api/types as api_types
import logos_delivery/waku/waku_core/message

export event_broker, api_types

type IMessagingClient* = ref object of RootObj

EventBroker:
  # Event emitted when a message is sent to the network
  type MessageSentEvent* = object
    requestId*: RequestId
    messageHash*: string

EventBroker:
  # Event emitted when a message send operation fails
  type MessageErrorEvent* = object
    requestId*: RequestId
    messageHash*: string
    error*: string

EventBroker:
  # Confirmation that a message has been correctly delivered to some neighbouring nodes.
  type MessagePropagatedEvent* = object
    requestId*: RequestId
    messageHash*: string

EventBroker:
  # Event emitted when a message is received via Waku
  type MessageReceivedEvent* = object
    messageHash*: string
    message*: WakuMessage

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

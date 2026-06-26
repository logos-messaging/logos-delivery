import chronos, results
import brokers/event_broker

import logos_delivery/api/types as api_types
import logos_delivery/waku/waku_core/message

export event_broker, api_types

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

# Structural API contract for a messaging client (ops in `messaging/api/*`).
type MessagingApi* = concept c
  subscribe(c, ContentTopic) is Future[Result[void, string]]
  unsubscribe(c, ContentTopic) is Result[void, string]
  send(c, MessageEnvelope) is Future[Result[RequestId, string]]

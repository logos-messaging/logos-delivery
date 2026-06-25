## Messaging layer API — event surface (messaging-level message events).
import brokers/event_broker
import logos_delivery/api/types
import logos_delivery/waku/waku_core/message
export event_broker, types

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

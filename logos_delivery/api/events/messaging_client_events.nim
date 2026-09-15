import brokers/event_broker

import logos_delivery/api/types as api_types

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
  # Event emitted when a send is held back because the epoch's rate-limit budget
  # is spent. The message stays queued and is sent once the budget refills.
  type MessageQueuedEvent* = object
    requestId*: RequestId
    messageHash*: string

EventBroker:
  # Confirmation that a message has been correctly delivered to some neighbouring nodes.
  type MessagePropagatedEvent* = object
    requestId*: RequestId
    messageHash*: string

EventBroker:
  # Event emitted when either a message belongs to Live communication or
  # recovered from Store. The source field has this information.
  type MessageReceivedEvent* = object
    messageHash*: string
    message*: WakuMessage
    source*: MessageSource

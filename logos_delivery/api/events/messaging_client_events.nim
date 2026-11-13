import brokers/event_broker

import logos_delivery/api/types as api_types

export event_broker, api_types

EventBroker:
  # Event emitted when a store node, or the mix exit for a send over mix, confirms
  # a message. Only with the `reliability` option on, and never for an ephemeral
  # message.
  type MessageSentEvent* = object
    messageHash*: string

EventBroker:
  # Event emitted when a message send operation fails
  type MessageErrorEvent* = object
    messageHash*: string
    kind*: MessageErrorKind
    error*: string

EventBroker:
  # Confirmation that a message has been correctly delivered to some neighbouring nodes.
  type MessagePropagatedEvent* = object
    messageHash*: string

EventBroker:
  # Event emitted when either a message belongs to Live communication or
  # recovered from Store. The source field has this information.
  type MessageReceivedEvent* = object
    messageHash*: string
    message*: WakuMessage
    source*: MessageSource

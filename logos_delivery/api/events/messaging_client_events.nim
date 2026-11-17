import brokers/event_broker

import logos_delivery/api/types as api_types

export event_broker, api_types

EventBroker:
  # Event emitted when a store node, or the mix exit for a send over mix, confirms
  # a message. Only with the `reliability` option on, and never for an ephemeral
  # message.
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

EventBroker:
  # Emitted once for each message that a history query finds.
  type HistoryQueryMessageEvent* = object
    requestId*: RequestId
    messageHash*: string
    message*: WakuMessage

EventBroker:
  # Emitted when a history query completes, after its last `HistoryQueryMessageEvent`.
  type HistoryQueryCompletedEvent* = object
    requestId*: RequestId
    messageCount*: int

EventBroker:
  # Emitted when a history query fails, as the last event of the query.
  type HistoryQueryErrorEvent* = object
    requestId*: RequestId
    error*: string

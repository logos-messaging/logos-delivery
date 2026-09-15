import brokers/event_broker

import logos_delivery/api/types as api_types
import logos_delivery/waku/waku_core/time

export event_broker, api_types, time

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
    expectedPublishTimestamp*: Timestamp
      ## Nanoseconds, when the budget refills; 0 when no epoch period is known.
      ## The earliest the send can go out, not a promise that it will: budget
      ## released at the boundary is shared with every other queued message.

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

import waku/[api/types, waku_core/message, waku_core/topics, common/broker/event_broker]

export types

EventBroker:
  # Event emitted when a message is sent to the network
  type MessageSentEvent* = object
    requestId*: RequestId
    messageHash*: string

EventBroker:
  # Event emitted when a message send operation fails
  type MessageSendErrorEvent* = object
    requestId*: RequestId
    messageHash*: string
    error*: string

EventBroker:
  # Confirmation that a message has been correctly delivered to some neighbouring nodes.
  type MessageSendPropagatedEvent* = object
    requestId*: RequestId
    messageHash*: string

EventBroker:
  # Event emitted when a message is received via Waku
  type MessageReceivedEvent* = object
    messageHash*: string
    message*: WakuMessage

EventBroker:
  # Internal event emitted when a message arrives from the network via any protocol
  type MessageSeenEvent* = object
    topic*: PubsubTopic
    message*: WakuMessage

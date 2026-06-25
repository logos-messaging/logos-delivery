import brokers/event_broker
import logos_delivery/api/types
import logos_delivery/waku/[waku_core/message, waku_core/topics]
export event_broker, types

EventBroker:
  # Internal event emitted when a message arrives from the network via any protocol
  type MessageSeenEvent* = object
    topic*: PubsubTopic
    message*: WakuMessage

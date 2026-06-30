import brokers/event_broker

import logos_delivery/api/types
import logos_delivery/waku/waku_core/topics/pubsub_topic
import logos_delivery/waku/waku_core/message

export event_broker, pubsub_topic, message

EventBroker:
  # Internal event emitted when a message arrives from the network via any protocol
  type MessageSeenEvent* = object
    topic*: PubsubTopic
    message*: WakuMessage

# Emitted by the health monitor when overall node connectivity changes.
EventBroker:
  type EventConnectionStatusChange* = object
    connectionStatus*: ConnectionStatus

import results
import brokers/event_broker

import logos_delivery/api/types
import logos_delivery/waku/waku_core/topics/[pubsub_topic, content_topic]
import logos_delivery/waku/waku_core/message
from logos_delivery/waku/waku_core/time import Timestamp

export event_broker, pubsub_topic, content_topic, message

EventBroker:
  # Internal event emitted when a message arrives from the network via any protocol
  type MessageSeenEvent* = object
    topic*: PubsubTopic
    message*: WakuMessage

# Emitted when a content topic becomes subscribed on a shard.
EventBroker:
  type ContentTopicSubscribedEvent* = object
    shard*: PubsubTopic
    contentTopic*: ContentTopic
    startTime*: Opt[Timestamp] ## the subscriber also wants the messages since then

# Emitted when a content topic stops being subscribed on a shard.
EventBroker:
  type ContentTopicUnsubscribedEvent* = object
    shard*: PubsubTopic
    contentTopic*: ContentTopic

# Emitted by the health monitor when overall node connectivity changes.
EventBroker:
  type EventConnectionStatusChange* = object
    connectionStatus*: ConnectionStatus

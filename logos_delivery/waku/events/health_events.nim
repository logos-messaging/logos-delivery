import brokers/event_broker

import logos_delivery/waku/api/types
import logos_delivery/waku/node/health_monitor/[protocol_health, topic_health]
import logos_delivery/waku/waku_core/topics

export protocol_health, topic_health

# Notify health changes to node connectivity
EventBroker:
  type ConnectionStatusChangeEvent* = object
    connectionStatus*: ConnectionStatus

# Notify health changes to a subscribed topic
# TODO: emit content topic health change events when subscribe/unsubscribe
#       from/to content topic is provided in the new API (so we know which
#       content topics are of interest to the application)
EventBroker:
  type ContentTopicHealthChangeEvent* = object
    contentTopic*: ContentTopic
    health*: TopicHealth

# Notify health changes to a shard (pubsub topic)
EventBroker:
  type ShardTopicHealthChangeEvent* = object
    topic*: PubsubTopic
    health*: TopicHealth

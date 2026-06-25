import brokers/event_broker

import logos_delivery/api/types
import logos_delivery/waku/node/health_monitor/[protocol_health, topic_health]
import logos_delivery/waku/waku_core/topics

export protocol_health, topic_health

# Note: `EventConnectionStatusChange` lives in `logos_delivery/api/logos_delivery_api`
# (the top-level orchestrator interface owns the node-connectivity event).

# Notify health changes to a subscribed topic
# TODO: emit content topic health change events when subscribe/unsubscribe
#       from/to content topic is provided in the new API (so we know which
#       content topics are of interest to the application)
EventBroker:
  type EventContentTopicHealthChange* = object
    contentTopic*: ContentTopic
    health*: TopicHealth

# Notify health changes to a shard (pubsub topic)
EventBroker:
  type EventShardTopicHealthChange* = object
    topic*: PubsubTopic
    health*: TopicHealth

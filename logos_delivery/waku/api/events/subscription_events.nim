{.push raises: [].}

## Shard subscription change events.
##
## Emitted by the node whenever it starts or stops being subscribed to a
## shard (relay subscriptions and filter subscriptions alike), so components
## that mirror the node's interests -- e.g. discv5 keeping the ENR shard
## fields in sync -- can react without polling a queue.

import brokers/event_broker
import logos_delivery/waku/waku_core/topics/pubsub_topic

export event_broker, pubsub_topic

EventBroker:
  # The node became subscribed to `topic`.
  type ShardSubscribedEvent* = object
    topic*: PubsubTopic

EventBroker:
  # The node stopped being subscribed to `topic`.
  type ShardUnsubscribedEvent* = object
    topic*: PubsubTopic

import brokers/event_broker
import logos_delivery/waku/waku_core/[message/message, message/digest]

EventBroker:
  type OnFilterSubscribeEvent* = object
    pubsubTopic*: string
    contentTopics*: seq[string]

EventBroker:
  type OnFilterUnSubscribeEvent* = object
    pubsubTopic*: string
    contentTopics*: seq[string]

import waku/waku_core/[message/message, message/digest], waku/common/broker/event_broker

EventBroker:
  type OnFilterSubscribeEvent* = object
    pubsubTopic*: string
    contentTopics*: seq[string]

EventBroker:
  type OnFilterUnSubscribeEvent* = object
    pubsubTopic*: string
    contentTopics*: seq[string]

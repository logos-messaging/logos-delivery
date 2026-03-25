import waku/waku_core/[message/message, message/digest], waku/common/broker/event_broker

type DeliveryDirection* {.pure.} = enum
  PUBLISHING
  RECEIVING

type DeliverySuccess* {.pure.} = enum
  SUCCESSFUL
  UNSUCCESSFUL

EventBroker:
  type DeliveryFeedbackEvent* = ref object
    success*: DeliverySuccess
    dir*: DeliveryDirection
    comment*: string
    msgHash*: WakuMessageHash
    msg*: WakuMessage

EventBroker:
  type OnFilterSubscribeEvent* = object
    pubsubTopic*: string
    contentTopics*: seq[string]

EventBroker:
  type OnFilterUnSubscribeEvent* = object
    pubsubTopic*: string
    contentTopics*: seq[string]

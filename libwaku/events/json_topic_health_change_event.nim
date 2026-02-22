import system, results, std/json
import stew/byteutils
import ../../waku/common/base64, ./json_base_event
import ../../waku/waku_relay

type JsonTopicHealthChangeEvent* = ref object of JsonEvent
  pubsubTopic*: string
  topicHealth*: TopicHealth

proc new*(
    T: type JsonTopicHealthChangeEvent, pubsubTopic: string, topicHealth: TopicHealth
): T =
  return JsonTopicHealthChangeEvent(
    eventType: "relay_topic_health_change",
    pubsubTopic: pubsubTopic,
    topicHealth: topicHealth,
  )

method `$`*(jsonTopicHealthChange: JsonTopicHealthChangeEvent): string =
  $(%*jsonTopicHealthChange)

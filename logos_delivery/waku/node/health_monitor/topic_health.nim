import chronos

import waku/waku_core

type TopicHealth* = enum
  UNHEALTHY
  MINIMALLY_HEALTHY
  SUFFICIENTLY_HEALTHY
  NOT_SUBSCRIBED

proc `$`*(t: TopicHealth): string =
  result =
    case t
    of UNHEALTHY: "UnHealthy"
    of MINIMALLY_HEALTHY: "MinimallyHealthy"
    of SUFFICIENTLY_HEALTHY: "SufficientlyHealthy"
    of NOT_SUBSCRIBED: "NotSubscribed"

type TopicHealthChangeHandler* = proc(
  pubsubTopic: PubsubTopic, topicHealth: TopicHealth
): Future[void] {.gcsafe, raises: [Defect].}

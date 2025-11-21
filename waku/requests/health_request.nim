import waku/common/broker/[request_broker, multi_request_broker]

import waku/api/types
import waku/node/health_monitor/[protocol_health, topic_health]
import waku/waku_core/topics

export protocol_health, topic_health

RequestBroker:
  type RequestNodeHealth* = object
    healthStatus*: NodeHealth

RequestBroker:
  type RequestRelayTopicsHealth* = object
    topicHealth*: seq[tuple[topic: PubsubTopic, health: TopicHealth]]

  proc signature(
    topics: seq[PubsubTopic]
  ): Future[Result[RequestRelayTopicsHealth, string]] {.async.}

MultiRequestBroker:
  type RequestProtocolHealth* = object
    healthStatus*: ProtocolHealth

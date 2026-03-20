import waku/common/broker/request_broker

import waku/api/types
import waku/node/health_monitor/[protocol_health, topic_health, health_report]
import waku/waku_core/topics
import waku/common/waku_protocol

export protocol_health, topic_health

# Get the overall node connectivity status
RequestBroker(sync):
  type RequestConnectionStatus* = object
    connectionStatus*: ConnectionStatus

# Get the health status of a set of content topics
RequestBroker(sync):
  type RequestContentTopicsHealth* = object
    contentTopicHealth*: seq[tuple[topic: ContentTopic, health: TopicHealth]]

  proc signature(topics: seq[ContentTopic]): Result[RequestContentTopicsHealth, string]

# Get a consolidated node health report
RequestBroker:
  type RequestHealthReport* = object
    healthReport*: HealthReport

# Get the health status of a set of shards (pubsub topics)
RequestBroker(sync):
  type RequestShardTopicsHealth* = object
    topicHealth*: seq[tuple[topic: PubsubTopic, health: TopicHealth]]

  proc signature(topics: seq[PubsubTopic]): Result[RequestShardTopicsHealth, string]

# Get the health status of a mounted protocol
RequestBroker:
  type RequestProtocolHealth* = object
    healthStatus*: ProtocolHealth

  proc signature(protocol: WakuProtocol): Future[Result[RequestProtocolHealth, string]]

import waku/common/broker/request_broker

import waku/api/types
import waku/node/health_monitor/[protocol_health, topic_health, health_report]
import waku/waku_core/topics
import waku/common/waku_protocol

export protocol_health, topic_health

RequestBroker(sync):
  type RequestConnectionStatus* = object
    connectionStatus*: ConnectionStatus

# TODO: content topic vs pubsub topic
RequestBroker(sync):
  type RequestRelayTopicsHealth* = object
    topicHealth*: seq[tuple[topic: PubsubTopic, health: TopicHealth]]

  proc signature(topics: seq[PubsubTopic]): Result[RequestRelayTopicsHealth, string]

RequestBroker:
  type RequestProtocolHealth* = object
    healthStatus*: ProtocolHealth

  proc signature(protocol: WakuProtocol): Future[Result[RequestProtocolHealth, string]]

RequestBroker:
  type RequestHealthReport* = object
    healthReport*: HealthReport

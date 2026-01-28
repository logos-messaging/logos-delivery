import waku/common/broker/event_broker

import waku/api/types
import waku/node/health_monitor/[protocol_health, topic_health]
import waku/waku_core/topics

export protocol_health, topic_health

EventBroker:
  type ConnectionStatusChangeEvent* = object
    connectionStatus*: ConnectionStatus

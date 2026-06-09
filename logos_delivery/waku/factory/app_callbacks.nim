import ../waku_relay, ../node/peer_manager, ../node/health_monitor/connection_status

type AppCallbacks* = ref object
  relayHandler*: WakuRelayHandler
  topicHealthChangeHandler*: TopicHealthChangeHandler
  connectionChangeHandler*: ConnectionChangeHandler
  connectionStatusChangeHandler*: ConnectionStatusChangeHandler

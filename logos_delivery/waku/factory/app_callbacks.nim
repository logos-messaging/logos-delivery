import ../waku_relay, ../node/peer_manager, ../node/health_monitor/connection_status

# Re-export the modules that define the handler types below, so that consumers
# of `AppCallbacks` (e.g. the FFI library) can construct the handlers.
export waku_relay, peer_manager, connection_status

type AppCallbacks* = ref object
  relayHandler*: WakuRelayHandler
  topicHealthChangeHandler*: TopicHealthChangeHandler
  connectionChangeHandler*: ConnectionChangeHandler
  connectionStatusChangeHandler*: ConnectionStatusChangeHandler

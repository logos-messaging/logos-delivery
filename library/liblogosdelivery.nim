import logos_delivery/waku/compat/option_valueor
import std/[atomics, options, macros]
import chronicles, chronos, chronos/threadsync, ffi
import
  logos_delivery/waku/waku_core/message/message,
  logos_delivery/waku/waku_core/topics/pubsub_topic,
  logos_delivery/waku/waku_relay,
  logos_delivery,
  logos_delivery/waku/factory/waku,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/node/peer_manager/peer_manager,
  logos_delivery/waku/node/health_monitor/health_status,
  logos_delivery/waku/node/health_monitor/topic_health,
  logos_delivery/waku/node/health_monitor/connection_status,
  ../logos_delivery/waku/factory/app_callbacks,
  ./events/json_message_event,
  ./events/json_topic_health_change_event,
  ./events/json_connection_change_event,
  ./events/json_connection_status_change_event,
  ./declare_lib

################################################################################
## Shared FFI event wiring

proc buildAppCallbacks(ctx: ptr FFIContext[LogosDelivery]): AppCallbacks =
  ## Builds the libp2p-level callbacks that bridge node events onto the FFI
  ## event callback. Shared by the single create_node entry point so both the
  ## stable (messaging) and kernel (waku_*) header surfaces get the same wiring.
  proc onReceivedMessage(ctx: ptr FFIContext): WakuRelayHandler =
    return proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
      callEventCallback(ctx, "onReceivedMessage"):
        $JsonMessageEvent.new(pubsubTopic, msg)

  proc onTopicHealthChange(ctx: ptr FFIContext): TopicHealthChangeHandler =
    return proc(pubsubTopic: PubsubTopic, topicHealth: TopicHealth) {.async.} =
      callEventCallback(ctx, "onTopicHealthChange"):
        $JsonTopicHealthChangeEvent.new(pubsubTopic, topicHealth)

  proc onConnectionChange(ctx: ptr FFIContext): ConnectionChangeHandler =
    return proc(peerId: PeerId, peerEvent: PeerEventKind) {.async.} =
      callEventCallback(ctx, "onConnectionChange"):
        $JsonConnectionChangeEvent.new($peerId, peerEvent)

  proc onConnectionStatusChange(ctx: ptr FFIContext): ConnectionStatusChangeHandler =
    return proc(status: ConnectionStatus) {.async.} =
      callEventCallback(ctx, "onConnectionStatusChange"):
        $JsonConnectionStatusChangeEvent.new(status)

  return AppCallbacks(
    relayHandler: onReceivedMessage(ctx),
    topicHealthChangeHandler: onTopicHealthChange(ctx),
    connectionChangeHandler: onConnectionChange(ctx),
    connectionStatusChangeHandler: onConnectionStatusChange(ctx),
  )

################################################################################
## Include different APIs, i.e. all procs with {.ffi.} pragma

include
  ./logos_delivery_api/node_api,
  ./logos_delivery_api/messaging_api,
  ./logos_delivery_api/debug_api,
  ./kernel_api/peer_manager_api,
  ./kernel_api/discovery_api,
  ./kernel_api/debug_node_api,
  ./kernel_api/ping_api,
  ./kernel_api/protocols/relay_api,
  ./kernel_api/protocols/store_api,
  ./kernel_api/protocols/lightpush_api,
  ./kernel_api/protocols/filter_api

import logos_delivery/waku/compat/option_valueor
import std/[atomics, options, macros]
import chronicles, chronos, chronos/threadsync, ffi
import
  logos_delivery/waku/waku_core/message/message,
  logos_delivery/waku/waku_core/topics/pubsub_topic,
  logos_delivery/waku/waku_relay,
  logos_delivery,
  logos_delivery/waku/waku,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/node/health_monitor/health_status,
  ./events/json_message_event,
  ./declare_lib

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
  ./kernel_api/protocols/filter_api,
  ./channels_api/channel_api

# Node lifecycle (create / start / stop / destroy) is unified under the stable
# logosdelivery_* surface in ./logos_delivery_api/node_api. The former
# waku_new / waku_start / waku_stop / waku_destroy entry points were removed to
# avoid maintaining two parallel node-lifecycle APIs.

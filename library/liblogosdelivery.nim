## C FFI library root (nim-ffi v0.2.0).
##
## The FFI context owns one `LogosDelivery` (the per-layer concentrator). The
## v0.2.0 framework generates the C ABI, CBOR (de)serialization and the request
## channel from the `{.ffiCtor.}` / `{.ffiDtor.}` / `{.ffi.}` / `{.ffiEvent.}`
## annotations below and in the included api modules; `genBindings()` (last
## call) emits the foreign-language bindings under `-d:ffiGenBindings`.
import ffi
import std/strutils
import chronos, results, chronicles

import logos_delivery
import logos_delivery/api/types
import tools/confutils/conf_from_json
import logos_delivery/waku/api/events/peer_events
import logos_delivery/waku/waku_core

declareLibrary("logosdelivery", LogosDelivery, defaultABIFormat = "cbor")

# --- shared wire types -----------------------------------------------------
type PeerConnInfoFFI* {.ffi.} = object
  peerId: string
  protocols: seq[string]
  addresses: seq[string]

# --- library-initiated events (one {.ffi.} type-set + listener per file) -----
include
  ./events/message_events,
  ./events/connection_status_events,
  ./events/topic_health_events,
  ./events/connection_change_events

proc listenInternalEvents(self: LogosDelivery) =
  ## Feed every FFI event from an internal nim-broker event.
  ## Listener handles are discarded on purpose: the listeners live for the node's lifetime.
  self.listenMessageEvents()
  self.listenConnectionStatusEvents()
  self.listenTopicHealthEvents()
  self.listenConnectionChangeEvents()

# --- constructor / destructor ----------------------------------------------
proc logosdelivery_create*(
    configJson: string
): Future[Result[LogosDelivery, string]] {.ffiCtor.} =
  let conf = parseNodeConfFromJson(configJson).valueOr:
    return err("failed to parse node config: " & error)

  let logos = (await LogosDelivery.new(conf)).valueOr:
    return err("failed to create LogosDelivery: " & error)

  logos.listenInternalEvents()

  return ok(logos)

proc logosdelivery_destroy*(self: LogosDelivery) {.ffiDtor.} =
  ## The framework drains the FFI thread and frees the context; callers stop the
  ## node via `logosdelivery_stop` first.
  discard

# --- lifecycle -------------------------------------------------------------
proc start*(self: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  (await self.start()).isOkOr:
    return err(error)
  return ok("")

proc stop*(self: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  (await self.stop()).isOkOr:
    return err(error)
  return ok("")

# --- operations (typed {.ffi.} procs, grouped per protocol) ----------------
include
  ./messaging_api/subscriptions_api,
  ./messaging_api/send_api,
  ./kernel_api/node_info_api,
  ./kernel_api/debug_node_api,
  ./kernel_api/ping_api,
  ./kernel_api/peer_manager_api,
  ./kernel_api/discovery_api,
  ./kernel_api/protocols/relay_api,
  ./kernel_api/protocols/lightpush_api,
  ./kernel_api/protocols/store_api,
  ./kernel_api/protocols/filter_api

# genBindings() MUST be the last top-level call — after every {.ffi.},
# {.ffiCtor.}, {.ffiDtor.} and {.ffiEvent.} pragma (incl. the included files).
genBindings()

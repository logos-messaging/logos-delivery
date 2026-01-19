import std/[atomics, options, atomics, macros]
import chronicles, chronos, chronos/threadsync, ffi
import
  waku/waku_core/message/message,
  waku/waku_core/topics/pubsub_topic,
  waku/waku_relay,
  ./events/json_message_event,
  ./events/json_topic_health_change_event,
  ./events/json_connection_change_event,
  ./events/json_node_health_change_event,
  ../waku/factory/app_callbacks,
  waku/factory/waku,
  waku/node/waku_node,
  waku/node/health_monitor/health_status,
  ./declare_lib

################################################################################
## Include different APIs, i.e. all procs with {.ffi.} pragma
include
  ./kernel_api/peer_manager_api,
  ./kernel_api/discovery_api,
  ./kernel_api/node_lifecycle_api,
  ./kernel_api/debug_node_api,
  ./kernel_api/ping_api,
  ./kernel_api/protocols/relay_api,
  ./kernel_api/protocols/store_api,
  ./kernel_api/protocols/lightpush_api,
  ./kernel_api/protocols/filter_api

################################################################################
### Exported procs

proc waku_new(
    configJson: cstring, callback: FFICallback, userData: pointer
): pointer {.dynlib, exportc, cdecl.} =
  initializeLibrary()

  ## Creates a new instance of the WakuNode.
  if isNil(callback):
    echo "error: missing callback in waku_new"
    return nil

  ## Create the Waku thread that will keep waiting for req from the main thread.
  var ctx = ffi.createFFIContext[Waku]().valueOr:
    let msg = "Error in createFFIContext: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  ctx.userData = userData

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

  proc onNodeHealthChange(ctx: ptr FFIContext): NodeHealthChangeHandler =
    return proc(status: NodeHealthStatus) {.async.} =
      callEventCallback(ctx, "onNodeHealthChange"):
        $JsonNodeHealthChangeEvent.new(status)

  let appCallbacks = AppCallbacks(
    relayHandler: onReceivedMessage(ctx),
    topicHealthChangeHandler: onTopicHealthChange(ctx),
    connectionChangeHandler: onConnectionChange(ctx),
    nodeHealthChangeHandler: onNodeHealthChange(ctx)
  )

  ffi.sendRequestToFFIThread(
    ctx, CreateNodeRequest.ffiNewReq(callback, userData, configJson, appCallbacks)
  ).isOkOr:
    let msg = "error in sendRequestToFFIThread: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  return ctx

proc waku_destroy(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)

  ffi.destroyFFIContext(ctx).isOkOr:
    let msg = "libwaku error: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  ## always need to invoke the callback although we don't retrieve value to the caller
  callback(RET_OK, nil, 0, userData)

  return RET_OK

# ### End of exported procs
# ################################################################################

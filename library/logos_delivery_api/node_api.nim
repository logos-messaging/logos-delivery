import std/json
import chronos, chronicles, results, ffi
import libp2p/peerid # pull PeerId pretty string formatting
import logos_delivery/waku/common/base64
import
  logos_delivery,
  logos_delivery/waku/node/waku_node,
  logos_delivery/api/types,
  logos_delivery/waku/api/events/health_events,
  logos_delivery/waku/api/events/peer_events,
  logos_delivery/api/conf/logos_delivery_conf_json,
  ../declare_lib,
  ../json_event

# Add JSON serialization for RequestId
proc `%`*(id: RequestId): JsonNode =
  %($id)

registerReqFFI(CreateNodeRequest, ctx: ptr FFIContext[LogosDelivery]):
  proc(configJson: cstring): Future[Result[string, string]] {.async.} =
    let conf = parseLogosDeliveryConf($configJson).valueOr:
      error "Failed to parse Logos Delivery configuration JSON",
        error = error, configJson = $configJson
      return err("failed parseLogosDeliveryConf " & error)

    ctx.myLib[] = (await LogosDelivery.new(conf)).valueOr:
      let errMsg = $error
      chronicles.error "CreateNodeRequest failed", err = errMsg
      return err(errMsg)

    return ok("")

proc logosdelivery_destroy(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  if not LogosDeliveryFFIPool.isValidCtx(cast[pointer](ctx)):
    return RET_ERR
  checkParams(ctx, callback, userData)

  # Recycle instead of destroy: under refc a full teardown cannot close the
  # context signal fds, so every create/destroy cycle would leak them.
  ffi.recycleFFIContext(LogosDeliveryFFIPool, ctx).isOkOr:
    let msg = "liblogosdelivery error: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  ## always need to invoke the callback although we don't retrieve value to the caller
  callback(RET_OK, nil, 0, userData)

  return RET_OK

proc logosdelivery_create_node(
    configJson: cstring, callback: FFICallback, userData: pointer
): pointer {.dynlib, exportc, cdecl.} =
  initializeLibrary()

  if callback.isNil():
    echo "error: missing callback in logosdelivery_create_node"
    return nil

  var ctx = ffi.createFFIContext(LogosDeliveryFFIPool).valueOr:
    let msg = "Error in createFFIContext: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  ctx.userData = userData

  ffi.sendRequestToFFIThread(
    ctx, CreateNodeRequest.ffiNewReq(callback, userData, configJson)
  ).isOkOr:
    let msg = "error in sendRequestToFFIThread: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    # free allocated resources as they won't be available
    ffi.recycleFFIContext(LogosDeliveryFFIPool, ctx).isOkOr:
      chronicles.error "Error in recycleFFIContext after sendRequestToFFIThread during creation",
        err = $error
    return nil

  return ctx

proc logosdelivery_start_node(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffiRaw.} =
  requireInitializedNode(ctx, "START_NODE"):
    return err(errMsg)

  # setting up outgoing event listeners
  let sentListener = MessageSentEvent.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: MessageSentEvent) {.async: (raises: []).} =
      emitEvent("onMessageSent"):
        $newJsonEvent("message_sent", event),
  ).valueOr:
    chronicles.error "MessageSentEvent.listen failed", err = $error
    return err("MessageSentEvent.listen failed: " & $error)

  let errorListener = MessageErrorEvent.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: MessageErrorEvent) {.async: (raises: []).} =
      emitEvent("onMessageError"):
        $newJsonEvent("message_error", event),
  ).valueOr:
    chronicles.error "MessageErrorEvent.listen failed", err = $error
    return err("MessageErrorEvent.listen failed: " & $error)

  let propagatedListener = MessagePropagatedEvent.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
      emitEvent("onMessagePropagated"):
        $newJsonEvent("message_propagated", event),
  ).valueOr:
    chronicles.error "MessagePropagatedEvent.listen failed", err = $error
    return err("MessagePropagatedEvent.listen failed: " & $error)

  let receivedListener = MessageReceivedEvent.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: MessageReceivedEvent) {.async: (raises: []).} =
      emitEvent("onMessageReceived"):
        $newJsonEvent("message_received", event),
  ).valueOr:
    chronicles.error "MessageReceivedEvent.listen failed", err = $error
    return err("MessageReceivedEvent.listen failed: " & $error)

  let ConnectionStatusChangeListener = EventConnectionStatusChange.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: EventConnectionStatusChange) {.async: (raises: []).} =
      emitEvent("onConnectionStatusChange"):
        $newJsonEvent("connection_status_change", event),
  ).valueOr:
    chronicles.error "ConnectionStatusChange.listen failed", err = $error
    return err("ConnectionStatusChange.listen failed: " & $error)

  let shardTopicHealthListener = EventShardTopicHealthChange.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: EventShardTopicHealthChange) {.async: (raises: []).} =
      emitEvent("onTopicHealthChange"):
        $(
          %*{
            "eventType": "relay_topic_health_change",
            "pubsubTopic": $event.topic,
            "topicHealth": $event.health,
          }
        ),
  ).valueOr:
    chronicles.error "EventShardTopicHealthChange.listen failed", err = $error
    return err("EventShardTopicHealthChange.listen failed: " & $error)

  let peerEventListener = WakuPeerEvent.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: WakuPeerEvent) {.async: (raises: []).} =
      emitEvent("onConnectionChange"):
        $(
          %*{
            "eventType": "connection_change",
            "peerId": $event.peerId,
            "peerEvent": $event.kind,
          }
        ),
  ).valueOr:
    chronicles.error "WakuPeerEvent.listen failed", err = $error
    return err("WakuPeerEvent.listen failed: " & $error)

  let channelReceivedListener = ChannelMessageReceivedEvent.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: ChannelMessageReceivedEvent) {.async: (raises: []).} =
      emitEvent("onChannelMessageReceived"):
        $(
          %*{
            "eventType": "channel_message_received",
            "channelId": string(event.channelId),
            "senderId": $event.senderId,
            "payload": string(base64.encode(event.payload)),
          }
        ),
  ).valueOr:
    chronicles.error "ChannelMessageReceivedEvent.listen failed", err = $error
    return err("ChannelMessageReceivedEvent.listen failed: " & $error)

  let channelSentListener = ChannelMessageSentEvent.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: ChannelMessageSentEvent) {.async: (raises: []).} =
      emitEvent("onChannelMessageSent"):
        $newJsonEvent("channel_message_sent", event),
  ).valueOr:
    chronicles.error "ChannelMessageSentEvent.listen failed", err = $error
    return err("ChannelMessageSentEvent.listen failed: " & $error)

  let channelErrorListener = ChannelMessageErrorEvent.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: ChannelMessageErrorEvent) {.async: (raises: []).} =
      emitEvent("onChannelMessageError"):
        $newJsonEvent("channel_message_error", event),
  ).valueOr:
    chronicles.error "ChannelMessageErrorEvent.listen failed", err = $error
    return err("ChannelMessageErrorEvent.listen failed: " & $error)

  (await ctx.myLib[].start()).isOkOr:
    let errMsg = $error
    chronicles.error "START_NODE failed", err = errMsg
    return err("failed to start: " & errMsg)
  return ok("")

proc logosdelivery_stop_node(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffiRaw.} =
  requireInitializedNode(ctx, "STOP_NODE"):
    return err(errMsg)

  await MessageErrorEvent.dropAllListeners(ctx.myLib[].waku.brokerCtx)
  await MessageSentEvent.dropAllListeners(ctx.myLib[].waku.brokerCtx)
  await MessagePropagatedEvent.dropAllListeners(ctx.myLib[].waku.brokerCtx)
  await MessageReceivedEvent.dropAllListeners(ctx.myLib[].waku.brokerCtx)
  await EventConnectionStatusChange.dropAllListeners(ctx.myLib[].waku.brokerCtx)
  await EventShardTopicHealthChange.dropAllListeners(ctx.myLib[].waku.brokerCtx)
  await WakuPeerEvent.dropAllListeners(ctx.myLib[].waku.brokerCtx)
  await ChannelMessageReceivedEvent.dropAllListeners(ctx.myLib[].waku.brokerCtx)
  await ChannelMessageSentEvent.dropAllListeners(ctx.myLib[].waku.brokerCtx)
  await ChannelMessageErrorEvent.dropAllListeners(ctx.myLib[].waku.brokerCtx)

  (await ctx.myLib[].stop()).isOkOr:
    let errMsg = $error
    chronicles.error "STOP_NODE failed", err = errMsg
    return err("failed to stop: " & errMsg)
  return ok("")

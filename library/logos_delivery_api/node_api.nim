import std/json
import chronos, chronicles, results, ffi
import
  logos_delivery,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/api/[api, types],
  logos_delivery/waku/events/[message_events, health_events],
  tools/confutils/conf_from_json,
  ../declare_lib,
  ../json_event

# Add JSON serialization for RequestId
proc `%`*(id: RequestId): JsonNode =
  %($id)

registerReqFFI(CreateNodeRequest, ctx: ptr FFIContext[LogosDelivery]):
  proc(configJson: cstring): Future[Result[string, string]] {.async.} =
    let conf = parseNodeConfFromJson($configJson).valueOr:
      error "Failed to assemble WakuNodeConf from JSON",
        error = error, configJson = $configJson
      return err("failed parseNodeConfFromJson " & error)

    ctx.myLib[] = (await LogosDelivery.new(conf)).valueOr:
      let errMsg = $error
      chronicles.error "CreateNodeRequest failed", err = errMsg
      return err(errMsg)

    return ok("")

proc logosdelivery_destroy(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)

  ffi.destroyFFIContext(ctx).isOkOr:
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

  var ctx = ffi.createFFIContext[LogosDelivery]().valueOr:
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
    ffi.destroyFFIContext(ctx).isOkOr:
      chronicles.error "Error in destroyFFIContext after sendRequestToFFIThread during creation",
        err = $error
    return nil

  return ctx

proc logosdelivery_start_node(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  requireInitializedNode(ctx, "START_NODE"):
    return err(errMsg)

  # setting up outgoing event listeners
  let sentListener = MessageSentEvent.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: MessageSentEvent) {.async: (raises: []).} =
      callEventCallback(ctx, "onMessageSent"):
        $newJsonEvent("message_sent", event),
  ).valueOr:
    chronicles.error "MessageSentEvent.listen failed", err = $error
    return err("MessageSentEvent.listen failed: " & $error)

  let errorListener = MessageErrorEvent.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: MessageErrorEvent) {.async: (raises: []).} =
      callEventCallback(ctx, "onMessageError"):
        $newJsonEvent("message_error", event),
  ).valueOr:
    chronicles.error "MessageErrorEvent.listen failed", err = $error
    return err("MessageErrorEvent.listen failed: " & $error)

  let propagatedListener = MessagePropagatedEvent.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
      callEventCallback(ctx, "onMessagePropagated"):
        $newJsonEvent("message_propagated", event),
  ).valueOr:
    chronicles.error "MessagePropagatedEvent.listen failed", err = $error
    return err("MessagePropagatedEvent.listen failed: " & $error)

  let receivedListener = MessageReceivedEvent.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: MessageReceivedEvent) {.async: (raises: []).} =
      callEventCallback(ctx, "onMessageReceived"):
        $newJsonEvent("message_received", event),
  ).valueOr:
    chronicles.error "MessageReceivedEvent.listen failed", err = $error
    return err("MessageReceivedEvent.listen failed: " & $error)

  let ConnectionStatusChangeListener = EventConnectionStatusChange.listen(
    ctx.myLib[].waku.brokerCtx,
    proc(event: EventConnectionStatusChange) {.async: (raises: []).} =
      callEventCallback(ctx, "onConnectionStatusChange"):
        $newJsonEvent("connection_status_change", event),
  ).valueOr:
    chronicles.error "ConnectionStatusChange.listen failed", err = $error
    return err("ConnectionStatusChange.listen failed: " & $error)

  (await ctx.myLib[].start()).isOkOr:
    let errMsg = $error
    chronicles.error "START_NODE failed", err = errMsg
    return err("failed to start: " & errMsg)
  return ok("")

proc logosdelivery_stop_node(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  requireInitializedNode(ctx, "STOP_NODE"):
    return err(errMsg)

  await MessageErrorEvent.dropAllListeners(ctx.myLib[].waku.brokerCtx)
  await MessageSentEvent.dropAllListeners(ctx.myLib[].waku.brokerCtx)
  await MessagePropagatedEvent.dropAllListeners(ctx.myLib[].waku.brokerCtx)
  await MessageReceivedEvent.dropAllListeners(ctx.myLib[].waku.brokerCtx)
  await EventConnectionStatusChange.dropAllListeners(ctx.myLib[].waku.brokerCtx)

  (await ctx.myLib[].stop()).isOkOr:
    let errMsg = $error
    chronicles.error "STOP_NODE failed", err = errMsg
    return err("failed to stop: " & errMsg)
  return ok("")

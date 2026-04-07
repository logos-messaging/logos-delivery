import std/[json, strutils, sets]
import chronos, chronicles, results, confutils, confutils/std/net, ffi
import
  waku/factory/waku,
  waku/node/waku_node,
  waku/api/[api, types],
  waku/events/[message_events, health_events],
  tools/confutils/cli_args,
  ../declare_lib,
  ../json_event

# Add JSON serialization for RequestId
proc `%`*(id: RequestId): JsonNode =
  %($id)

registerReqFFI(CreateNodeRequest, ctx: ptr FFIContext[Waku]):
  proc(configJson: cstring): Future[Result[string, string]] {.async.} =
    ## Parse the JSON configuration using fieldPairs approach (WakuNodeConf)
    var conf = defaultWakuNodeConf().valueOr:
      return err("Failed creating default conf: " & error)

    var jsonNode: JsonNode
    try:
      jsonNode = parseJson($configJson)
    except Exception:
      return err(
        "Failed to parse config JSON: " & getCurrentExceptionMsg() &
          " configJson string: " & $configJson
      )

    # Collect known fields
    var knownFields = initHashSet[string]()
    for confField, _ in fieldPairs(conf):
      knownFields.incl(confField)
    # Check for unknown keys
    for key in jsonNode.keys:
      if key notin knownFields:
        error "Invalid configuration option found.", option = key
        return err("Invalid configuration option found: " & key)

    for confField, confValue in fieldPairs(conf):
      if jsonNode.contains(confField):
        let formattedString = ($jsonNode[confField]).strip(chars = {'\"'})
        try:
          confValue = parseCmdArg(typeof(confValue), formattedString)
        except Exception:
          return err(
            "Failed to parse field '" & confField & "': " & getCurrentExceptionMsg() &
              ". Value: " & formattedString
          )

    # Create the node
    ctx.myLib[] = (await api.createNode(conf)).valueOr:
      let errMsg = $error
      chronicles.error "CreateNodeRequest failed", err = errMsg
      return err(errMsg)

    return ok("")

proc logosdelivery_destroy(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
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

  if isNil(callback):
    echo "error: missing callback in logosdelivery_create_node"
    return nil

  var ctx = ffi.createFFIContext[Waku]().valueOr:
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
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  requireInitializedNode(ctx, "START_NODE"):
    return err(errMsg)

  # setting up outgoing event listeners
  let sentListener = MessageSentEvent.listen(
    ctx.myLib[].brokerCtx,
    proc(event: MessageSentEvent) {.async: (raises: []).} =
      callEventCallback(ctx, "onMessageSent"):
        $newJsonEvent("message_sent", event),
  ).valueOr:
    chronicles.error "MessageSentEvent.listen failed", err = $error
    return err("MessageSentEvent.listen failed: " & $error)

  let errorListener = MessageErrorEvent.listen(
    ctx.myLib[].brokerCtx,
    proc(event: MessageErrorEvent) {.async: (raises: []).} =
      callEventCallback(ctx, "onMessageError"):
        $newJsonEvent("message_error", event),
  ).valueOr:
    chronicles.error "MessageErrorEvent.listen failed", err = $error
    return err("MessageErrorEvent.listen failed: " & $error)

  let propagatedListener = MessagePropagatedEvent.listen(
    ctx.myLib[].brokerCtx,
    proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
      callEventCallback(ctx, "onMessagePropagated"):
        $newJsonEvent("message_propagated", event),
  ).valueOr:
    chronicles.error "MessagePropagatedEvent.listen failed", err = $error
    return err("MessagePropagatedEvent.listen failed: " & $error)

  let receivedListener = MessageReceivedEvent.listen(
    ctx.myLib[].brokerCtx,
    proc(event: MessageReceivedEvent) {.async: (raises: []).} =
      callEventCallback(ctx, "onMessageReceived"):
        $newJsonEvent("message_received", event),
  ).valueOr:
    chronicles.error "MessageReceivedEvent.listen failed", err = $error
    return err("MessageReceivedEvent.listen failed: " & $error)

  let ConnectionStatusChangeListener = EventConnectionStatusChange.listen(
    ctx.myLib[].brokerCtx,
    proc(event: EventConnectionStatusChange) {.async: (raises: []).} =
      callEventCallback(ctx, "onConnectionStatusChange"):
        $newJsonEvent("connection_status_change", event),
  ).valueOr:
    chronicles.error "ConnectionStatusChange.listen failed", err = $error
    return err("ConnectionStatusChange.listen failed: " & $error)

  (await startWaku(addr ctx.myLib[])).isOkOr:
    let errMsg = $error
    chronicles.error "START_NODE failed", err = errMsg
    return err("failed to start: " & errMsg)
  return ok("")

proc logosdelivery_stop_node(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  requireInitializedNode(ctx, "STOP_NODE"):
    return err(errMsg)

  MessageErrorEvent.dropAllListeners(ctx.myLib[].brokerCtx)
  MessageSentEvent.dropAllListeners(ctx.myLib[].brokerCtx)
  MessagePropagatedEvent.dropAllListeners(ctx.myLib[].brokerCtx)
  MessageReceivedEvent.dropAllListeners(ctx.myLib[].brokerCtx)
  EventConnectionStatusChange.dropAllListeners(ctx.myLib[].brokerCtx)

  (await ctx.myLib[].stop()).isOkOr:
    let errMsg = $error
    chronicles.error "STOP_NODE failed", err = errMsg
    return err("failed to stop: " & errMsg)
  return ok("")

import std/[json, strutils, tables]
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
      let exceptionMsg = getCurrentExceptionMsg()
      error "Failed to parse config JSON",
        error = exceptionMsg, configJson = $configJson
      return err(
        "Failed to parse config JSON: " & exceptionMsg & " configJson string: " &
          $configJson
      )

    var jsonFields: Table[string, (string, JsonNode)]
    for key, value in jsonNode:
      let lowerKey = key.toLowerAscii()

      if jsonFields.hasKey(lowerKey):
        error "Duplicate configuration option found when normalized to lowercase",
          key = key
        return err(
          "Duplicate configuration option found when normalized to lowercase: '" & key &
            "'"
        )

      jsonFields[lowerKey] = (key, value)

    for confField, confValue in fieldPairs(conf):
      let lowerField = confField.toLowerAscii()
      if jsonFields.hasKey(lowerField):
        let (jsonKey, jsonValue) = jsonFields[lowerField]
        let formattedString = ($jsonValue).strip(chars = {'\"'})
        try:
          confValue = parseCmdArg(typeof(confValue), formattedString)
        except Exception:
          return err(
            "Failed to parse field '" & confField & "' from JSON key '" & jsonKey & "': " &
              getCurrentExceptionMsg() & ". Value: " & formattedString
          )

        jsonFields.del(lowerField)

    if jsonFields.len > 0:
      var unknownKeys = newSeq[string]()
      for _, (jsonKey, _) in pairs(jsonFields):
        unknownKeys.add(jsonKey)
      error "Unrecognized configuration option(s) found", option = unknownKeys
      return err("Unrecognized configuration option(s) found: " & $unknownKeys)

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
        $newJsonEvent("message:sent", event),
  ).valueOr:
    chronicles.error "MessageSentEvent.listen failed", err = $error
    return err("MessageSentEvent.listen failed: " & $error)

  let errorListener = MessageSendErrorEvent.listen(
    ctx.myLib[].brokerCtx,
    proc(event: MessageSendErrorEvent) {.async: (raises: []).} =
      callEventCallback(ctx, "onMessageSendError"):
        $newJsonEvent("message:send-error", event),
  ).valueOr:
    chronicles.error "MessageSendErrorEvent.listen failed", err = $error
    return err("MessageSendErrorEvent.listen failed: " & $error)

  let propagatedListener = MessageSendPropagatedEvent.listen(
    ctx.myLib[].brokerCtx,
    proc(event: MessageSendPropagatedEvent) {.async: (raises: []).} =
      callEventCallback(ctx, "onMessageSendPropagated"):
        $newJsonEvent("message:send-propagated", event),
  ).valueOr:
    chronicles.error "MessageSendPropagatedEvent.listen failed", err = $error
    return err("MessageSendPropagatedEvent.listen failed: " & $error)

  let receivedListener = MessageReceivedEvent.listen(
    ctx.myLib[].brokerCtx,
    proc(event: MessageReceivedEvent) {.async: (raises: []).} =
      callEventCallback(ctx, "onMessageReceived"):
        $newJsonEvent("message:received", event),
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

  MessageSendErrorEvent.dropAllListeners(ctx.myLib[].brokerCtx)
  MessageSentEvent.dropAllListeners(ctx.myLib[].brokerCtx)
  MessageSendPropagatedEvent.dropAllListeners(ctx.myLib[].brokerCtx)
  MessageReceivedEvent.dropAllListeners(ctx.myLib[].brokerCtx)
  EventConnectionStatusChange.dropAllListeners(ctx.myLib[].brokerCtx)

  (await ctx.myLib[].stop()).isOkOr:
    let errMsg = $error
    chronicles.error "STOP_NODE failed", err = errMsg
    return err("failed to stop: " & errMsg)
  return ok("")

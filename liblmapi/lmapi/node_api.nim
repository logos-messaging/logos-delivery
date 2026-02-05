import std/[json, options]
import chronos, results, ffi
import
  waku/factory/waku,
  waku/node/waku_node,
  waku/api/[api, api_conf, types],
  waku/events/message_events,
  ../declare_lib,
  ../json_event

# Add JSON serialization for RequestId
proc `%`*(id: RequestId): JsonNode =
  %($id)

registerReqFFI(CreateNodeRequest, ctx: ptr FFIContext[Waku]):
  proc(configJson: cstring): Future[Result[string, string]] {.async.} =
    ## Parse the JSON configuration and create a node
    var jsonNode: JsonNode
    try:
      jsonNode = parseJson($configJson)
    except Exception as e:
      return err("Failed to parse config JSON: " & e.msg)

    # Extract basic configuration
    let mode =
      if jsonNode.hasKey("mode") and jsonNode["mode"].getStr() == "Edge":
        WakuMode.Edge
      else:
        WakuMode.Core

    # Build protocols config
    var entryNodes: seq[string] = @[]
    if jsonNode.hasKey("entryNodes"):
      for node in jsonNode["entryNodes"]:
        entryNodes.add(node.getStr())

    var staticStoreNodes: seq[string] = @[]
    if jsonNode.hasKey("staticStoreNodes"):
      for node in jsonNode["staticStoreNodes"]:
        staticStoreNodes.add(node.getStr())

    let clusterId =
      if jsonNode.hasKey("clusterId"):
        uint16(jsonNode["clusterId"].getInt())
      else:
        1u16 # Default cluster ID

    # Build networking config
    let networkingConfig =
      if jsonNode.hasKey("networkingConfig"):
        let netJson = jsonNode["networkingConfig"]
        NetworkingConfig(
          listenIpv4: netJson.getOrDefault("listenIpv4").getStr("0.0.0.0"),
          p2pTcpPort: uint16(netJson.getOrDefault("p2pTcpPort").getInt(60000)),
          discv5UdpPort: uint16(netJson.getOrDefault("discv5UdpPort").getInt(9000)),
        )
      else:
        DefaultNetworkingConfig

    # Build protocols config
    let protocolsConfig = ProtocolsConfig.init(
      entryNodes = entryNodes,
      staticStoreNodes = staticStoreNodes,
      clusterId = clusterId,
    )

    # Build node config
    let nodeConfig = NodeConfig.init(
      mode = mode,
      protocolsConfig = protocolsConfig,
      networkingConfig = networkingConfig,
    )

    # Create the node
    ctx.myLib[] = (await api.createNode(nodeConfig)).valueOr:
      let errMsg = $error
      chronicles.error "CreateNodeRequest failed", err = errMsg
      return err(errMsg)

    return ok("")

proc lmapi_create_node(
    configJson: cstring, callback: FFICallback, userData: pointer
): pointer {.dynlib, exportc, cdecl.} =
  initializeLibrary()

  if isNil(callback):
    echo "error: missing callback in lmapi_create_node"
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
    return nil

  return ctx

proc lmapi_start_node(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
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

  (await startWaku(addr ctx.myLib[])).isOkOr:
    let errMsg = $error
    chronicles.error "START_NODE failed", err = errMsg
    return err("failed to start: " & errMsg)
  return ok("")

proc lmapi_stop_node(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  MessageErrorEvent.dropAllListeners(ctx.myLib[].brokerCtx)
  MessageSentEvent.dropAllListeners(ctx.myLib[].brokerCtx)
  MessagePropagatedEvent.dropAllListeners(ctx.myLib[].brokerCtx)

  (await ctx.myLib[].stop()).isOkOr:
    let errMsg = $error
    chronicles.error "STOP_NODE failed", err = errMsg
    return err("failed to stop: " & errMsg)
  return ok("")

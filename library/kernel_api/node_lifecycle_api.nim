import logos_delivery/waku/compat/option_valueor
import std/[options, json, strutils, net]
import chronos, chronicles, results, confutils, confutils/std/net, ffi

import
  logos_delivery/waku/node/peer_manager/peer_manager,
  tools/confutils/cli_args,
  logos_delivery/waku/factory/waku,
  logos_delivery/waku/factory/node_factory,
  logos_delivery/waku/factory/app_callbacks,
  logos_delivery/waku/rest_api/endpoint/builder,
  library/declare_lib

proc createWaku(
    configJson: cstring, appCallbacks: AppCallbacks = nil
): Future[Result[LogosDelivery, string]] {.async.} =
  var conf = defaultWakuNodeConf().valueOr:
    return err("Failed creating node: " & error)

  var errorResp: string

  var jsonNode: JsonNode
  try:
    jsonNode = parseJson($configJson)
  except Exception:
    return err(
      "exception in createWaku when calling parseJson: " & getCurrentExceptionMsg() &
        " configJson string: " & $configJson
    )

  for confField, confValue in fieldPairs(conf):
    if jsonNode.contains(confField):
      # Make sure string doesn't contain the leading or trailing " character
      let formattedString = ($jsonNode[confField]).strip(chars = {'\"'})
      # Override conf field with the value set in the json-string
      try:
        confValue = parseCmdArg(typeof(confValue), formattedString)
      except Exception:
        return err(
          "exception in createWaku when parsing configuration. exc: " &
            getCurrentExceptionMsg() & ". string that could not be parsed: " &
            formattedString & ". expected type: " & $typeof(confValue)
        )

  # Don't send relay app callbacks if relay is disabled
  if not conf.relay and not appCallbacks.isNil():
    appCallbacks.relayHandler = nil
    appCallbacks.topicHealthChangeHandler = nil

  conf.rest = false ## libwaku never runs the REST server

  let logosRes = (await LogosDelivery.new(conf, appCallbacks)).valueOr:
    error "LogosDelivery initialization failed", error = error
    return err("Failed setting up LogosDelivery: " & $error)

  return ok(logosRes)

registerReqFFI(CreateNodeWithCallbacksRequest, ctx: ptr FFIContext[LogosDelivery]):
  proc(
      configJson: cstring, appCallbacks: AppCallbacks
  ): Future[Result[string, string]] {.async.} =
    ctx.myLib[] = (await createWaku(configJson, cast[AppCallbacks](appCallbacks))).valueOr:
      error "CreateNodeWithCallbacksRequest failed", error = error
      return err($error)

    return ok("")

proc waku_start(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  (await ctx.myLib[].start()).isOkOr:
    error "START_NODE failed", error = error
    return err("failed to start: " & $error)
  return ok("")

proc waku_stop(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  (await ctx.myLib[].stop()).isOkOr:
    error "STOP_NODE failed", error = error
    return err("failed to stop: " & $error)
  return ok("")

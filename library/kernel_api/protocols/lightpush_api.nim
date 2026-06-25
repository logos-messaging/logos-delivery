import std/[json, strformat]
import chronicles, chronos, results, ffi
import
  logos_delivery,
  logos_delivery/waku/waku_core/message,
  logos_delivery/waku/waku_core/topics/pubsub_topic,
  library/events/json_message_event,
  library/declare_lib

proc waku_lightpush_publish(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
    jsonWakuMessage: cstring,
) {.ffi.} =
  var jsonMessage: JsonMessage
  try:
    let jsonContent = parseJson($jsonWakuMessage)
    jsonMessage = JsonMessage.fromJsonNode(jsonContent).valueOr:
      raise newException(JsonParsingError, $error)
  except JsonParsingError as exc:
    return err(fmt"Error parsing json message: {exc.msg}")

  let msg = json_message_event.toWakuMessage(jsonMessage).valueOr:
    return err("Problem building the WakuMessage: " & $error)

  let msgHashHex = (
    await ctx.myLib[].waku.lightpushPublish(PubsubTopic($pubSubTopic), msg)
  ).valueOr:
    error "PUBLISH failed", error = error
    return err(error)

  return ok(msgHashHex)

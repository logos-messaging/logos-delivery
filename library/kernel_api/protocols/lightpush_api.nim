import logos_delivery/waku/compat/option_valueor
import options, std/[json, strformat]
import chronicles, chronos, results, ffi
import
  logos_delivery/waku/waku_core/message/message,
  logos_delivery/waku/waku_core/codecs,
  logos_delivery/waku/factory/waku,
  logos_delivery/waku/waku_core/message,
  logos_delivery/waku/waku_core/topics/pubsub_topic,
  logos_delivery/waku/waku_lightpush_legacy/client,
  logos_delivery/waku/node/peer_manager/peer_manager,
  library/events/json_message_event,
  library/declare_lib

proc waku_lightpush_publish(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
    jsonWakuMessage: cstring,
) {.ffi.} =
  if ctx.myLib[].waku.node.wakuLightpushClient.isNil():
    let errorMsg = "LightpushRequest waku.node.wakuLightpushClient is nil"
    error "PUBLISH failed", error = errorMsg
    return err(errorMsg)

  var jsonMessage: JsonMessage
  try:
    let jsonContent = parseJson($jsonWakuMessage)
    jsonMessage = JsonMessage.fromJsonNode(jsonContent).valueOr:
      raise newException(JsonParsingError, $error)
  except JsonParsingError as exc:
    return err(fmt"Error parsing json message: {exc.msg}")

  let msg = json_message_event.toWakuMessage(jsonMessage).valueOr:
    return err("Problem building the WakuMessage: " & $error)

  let peerOpt = ctx.myLib[].waku.node.peerManager.selectPeer(WakuLightPushCodec)
  if peerOpt.isNone():
    let errorMsg = "failed to lightpublish message, no suitable remote peers"
    error "PUBLISH failed", error = errorMsg
    return err(errorMsg)

  let msgHashHex = (
    await ctx.myLib[].waku.node.wakuLegacyLightpushClient.publish(
      $pubsubTopic, msg, peer = peerOpt.get()
    )
  ).valueOr:
    error "PUBLISH failed", error = error
    return err($error)

  return ok(msgHashHex)

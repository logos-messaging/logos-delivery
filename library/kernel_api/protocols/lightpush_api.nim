import options, std/[json, strformat]
import chronicles, chronos, results, ffi
import
  waku/waku_core/message/message,
  waku/waku_core/codecs,
  waku/factory/waku,
  waku/waku_core/message,
  waku/waku_core/topics/pubsub_topic,
  waku/waku_lightpush_legacy/client,
  waku/node/peer_manager/peer_manager,
  library/events/json_message_event,
  library/declare_lib

proc waku_lightpush_publish(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
    jsonWakuMessage: cstring,
) {.ffi.} =
  if ctx.myLib[].node.wakuLightpushClient.isNil():
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

  let peerOpt = ctx.myLib[].node.peerManager.selectPeer(WakuLightPushCodec)
  if peerOpt.isNone():
    let errorMsg = "failed to lightpublish message, no suitable remote peers"
    error "PUBLISH failed", error = errorMsg
    return err(errorMsg)
  let topic =
    if ($pubsubTopic).len == 0:
      none(PubsubTopic)
    else:
      some(PubsubTopic($pubsubTopic))

  let messageHash = (await ctx.myLib[].node.lightpushPublish(topic, msg, peerOpt)).valueOr:
    let errorMsg = error.desc.get($error.code.int)
    error "PUBLISH failed", error = errorMsg
    return err(errorMsg)

  return ok($messageHash)

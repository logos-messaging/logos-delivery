import std/json
import chronos, results, ffi
import
  logos_delivery/waku/common/base64,
  logos_delivery,
  logos_delivery/waku/waku_core/topics/content_topic,
  logos_delivery/api/types,
  ../declare_lib

proc logosdelivery_channel_create(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    channelIdStr: cstring,
    contentTopicStr: cstring,
    senderIdStr: cstring,
) {.ffi.} =
  requireInitializedNode(ctx, "ChannelCreate"):
    return err(errMsg)

  let id = ctx.myLib[].reliableChannelManager.createReliableChannel(
    ChannelId($channelIdStr),
    ContentTopic($contentTopicStr),
    SdsParticipantID($senderIdStr),
  ).valueOr:
    return err("ChannelCreate failed: " & $error)

  return ok(string(id))

proc logosdelivery_channel_send(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    channelIdStr: cstring,
    messageJson: cstring,
) {.ffi.} =
  ## `messageJson` carries `{ "payload": <base64>, "ephemeral": <bool> }`.
  requireInitializedNode(ctx, "ChannelSend"):
    return err(errMsg)

  var jsonNode: JsonNode
  try:
    jsonNode = parseJson($messageJson)
  except Exception as e:
    return err("Failed to parse channel message JSON: " & e.msg)

  if not jsonNode.hasKey("payload"):
    return err("Missing payload field")

  let payload = base64.decode(Base64String(jsonNode["payload"].getStr())).valueOr:
    return err("invalid payload format: " & error)

  let ephemeral = jsonNode.getOrDefault("ephemeral").getBool(false)

  let requestId = (
    await ctx.myLib[].reliableChannelManager.send(
      ChannelId($channelIdStr), payload, ephemeral
    )
  ).valueOr:
    return err("ChannelSend failed: " & $error)

  return ok($requestId)

proc logosdelivery_channel_close(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    channelIdStr: cstring,
) {.ffi.} =
  requireInitializedNode(ctx, "ChannelClose"):
    return err(errMsg)

  (await ctx.myLib[].reliableChannelManager.closeChannel(ChannelId($channelIdStr))).isOkOr:
    return err("ChannelClose failed: " & $error)

  return ok("")

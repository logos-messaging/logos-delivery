import std/[json]
import chronos, results, ffi
import stew/byteutils
import
  logos_delivery/waku/common/base64,
  logos_delivery/waku/factory/waku,
  logos_delivery/waku/waku_core/topics/content_topic,
  logos_delivery/waku/api/[api, types],
  ../declare_lib

proc logosdelivery_subscribe(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    contentTopicStr: cstring,
) {.ffi.} =
  requireInitializedNode(ctx, "Subscribe"):
    return err(errMsg)

  # ContentTopic is just a string type alias
  let contentTopic = ContentTopic($contentTopicStr)

  (await api.subscribe(ctx.myLib[].waku, contentTopic)).isOkOr:
    let errMsg = $error
    return err("Subscribe failed: " & errMsg)

  return ok("")

proc logosdelivery_unsubscribe(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    contentTopicStr: cstring,
) {.ffi.} =
  requireInitializedNode(ctx, "Unsubscribe"):
    return err(errMsg)

  # ContentTopic is just a string type alias
  let contentTopic = ContentTopic($contentTopicStr)

  api.unsubscribe(ctx.myLib[].waku, contentTopic).isOkOr:
    let errMsg = $error
    return err("Unsubscribe failed: " & errMsg)

  return ok("")

proc logosdelivery_send(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    messageJson: cstring,
) {.ffi.} =
  requireInitializedNode(ctx, "Send"):
    return err(errMsg)

  ## Parse the message JSON and send the message
  var jsonNode: JsonNode
  try:
    jsonNode = parseJson($messageJson)
  except Exception as e:
    return err("Failed to parse message JSON: " & e.msg)

  # Extract content topic
  if not jsonNode.hasKey("contentTopic"):
    return err("Missing contentTopic field")

  # ContentTopic is just a string type alias
  let contentTopic = ContentTopic(jsonNode["contentTopic"].getStr())

  # Extract payload (expect base64 encoded string)
  if not jsonNode.hasKey("payload"):
    return err("Missing payload field")

  let payloadStr = jsonNode["payload"].getStr()
  let payload = base64.decode(Base64String(payloadStr)).valueOr:
    return err("invalid payload format: " & error)

  # Extract ephemeral flag
  let ephemeral = jsonNode.getOrDefault("ephemeral").getBool(false)

  # Create message envelope
  let envelope = MessageEnvelope.init(
    contentTopic = contentTopic, payload = payload, ephemeral = ephemeral
  )

  # Send the message via the messaging layer's own API.
  let requestId = (await ctx.myLib[].messagingClient.send(envelope)).valueOr:
    let errMsg = $error
    return err("Send failed: " & errMsg)

  return ok($requestId)

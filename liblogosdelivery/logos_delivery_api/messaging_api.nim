import std/[json, base64]
import chronos, results, ffi
import stew/byteutils
import
  waku/factory/waku,
  waku/waku_core/topics/content_topic,
  waku/api/[api, types],
  ../declare_lib

proc logosdelivery_subscribe(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    contentTopicStr: cstring,
) {.ffi.} =
  # ContentTopic is just a string type alias
  let contentTopic = ContentTopic($contentTopicStr)

  (await api.subscribe(ctx.myLib[], contentTopic)).isOkOr:
    let errMsg = $error
    return err("Subscribe failed: " & errMsg)

  return ok("")

proc logosdelivery_unsubscribe(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    contentTopicStr: cstring,
) {.ffi.} =
  # ContentTopic is just a string type alias
  let contentTopic = ContentTopic($contentTopicStr)

  api.unsubscribe(ctx.myLib[], contentTopic).isOkOr:
    let errMsg = $error
    return err("Unsubscribe failed: " & errMsg)

  return ok("")

proc logosdelivery_send(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    messageJson: cstring,
) {.ffi.} =
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

  var payload: seq[byte]
  try:
    let payloadStr = jsonNode["payload"].getStr()
    # base64.decode returns string, convert to seq[byte]
    let decodedStr = base64.decode(payloadStr)
    payload = cast[seq[byte]](decodedStr)
  except Exception as e:
    return err("Failed to decode payload: " & e.msg)

  # Extract ephemeral flag
  let ephemeral = jsonNode.getOrDefault("ephemeral").getBool(false)

  # Create message envelope
  let envelope = MessageEnvelope.init(
    contentTopic = contentTopic, payload = payload, ephemeral = ephemeral
  )

  # Send the message
  let requestId = (await api.send(ctx.myLib[], envelope)).valueOr:
    let errMsg = $error
    return err("Send failed: " & errMsg)

  return ok($requestId)

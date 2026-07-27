import std/json
import chronos, results, ffi
import
  logos_delivery/waku/common/base64,
  logos_delivery,
  logos_delivery/waku/waku_core/topics/content_topic,
  logos_delivery/api/types,
  ../declare_lib

proc logosdelivery_channel_create(
    ld: LogosDelivery, channelId: cstring, contentTopic: cstring, senderId: cstring
): Future[Result[string, string]] {.ffi.} =
  requireInitializedNode(ld, "ChannelCreate"):
    return err(errMsg)

  requireChannels(ld, "ChannelCreate"):
    return err(errMsg)

  let id = ld.reliableChannelManager.createReliableChannel(
    ChannelId($channelId), ContentTopic($contentTopic), SdsParticipantID($senderId)
  ).valueOr:
    return err("ChannelCreate failed: " & $error)

  return ok(string(id))

proc logosdelivery_channel_exists(
    ld: LogosDelivery, channelId: cstring
): Future[Result[string, string]] {.ffi.} =
  ## Returns `"true"` or `"false"`; a missing channel is not an error.
  requireInitializedNode(ld, "ChannelExists"):
    return err(errMsg)

  requireChannels(ld, "ChannelExists"):
    return err(errMsg)

  return ok($ld.reliableChannelManager.channelExists(ChannelId($channelId)))

proc logosdelivery_channel_send(
    ld: LogosDelivery, channelId: cstring, messageJson: cstring
): Future[Result[string, string]] {.ffi.} =
  ## `messageJson` carries `{ "payload": <base64>, "ephemeral": <bool> }`.
  requireInitializedNode(ld, "ChannelSend"):
    return err(errMsg)

  requireChannels(ld, "ChannelSend"):
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
    await ld.reliableChannelManager.send(ChannelId($channelId), payload, ephemeral)
  ).valueOr:
    return err("ChannelSend failed: " & $error)

  return ok($requestId)

proc logosdelivery_channel_close(
    ld: LogosDelivery, channelId: cstring
): Future[Result[string, string]] {.ffi.} =
  requireInitializedNode(ld, "ChannelClose"):
    return err(errMsg)

  requireChannels(ld, "ChannelClose"):
    return err(errMsg)

  (await ld.reliableChannelManager.closeChannel(ChannelId($channelId))).isOkOr:
    return err("ChannelClose failed: " & $error)

  return ok("")

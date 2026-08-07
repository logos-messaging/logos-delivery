import std/json
import chronos, results, ffi
import
  logos_delivery/waku/common/base64,
  logos_delivery,
  logos_delivery/waku/waku_core/topics/content_topic,
  logos_delivery/api/types,
  ../declare_lib

proc logosdelivery_channel_create(
    self: LogosDelivery,
    channelIdStr: string,
    contentTopicStr: string,
    senderIdStr: string,
): Future[Result[string, string]] {.ffi.} =
  requireChannels(self, "ChannelCreate"):
    return err(errMsg)

  let id = self.reliableChannelManager.createReliableChannel(
    ChannelId(channelIdStr),
    ContentTopic(contentTopicStr),
    SdsParticipantID(senderIdStr),
  ).valueOr:
    return err("ChannelCreate failed: " & $error)

  return ok(string(id))

proc logosdelivery_channel_exists(
    self: LogosDelivery, channelIdStr: string
): Future[Result[string, string]] {.ffi.} =
  ## Returns `"true"` or `"false"`; a missing channel is not an error.
  requireChannels(self, "ChannelExists"):
    return err(errMsg)

  return ok($self.reliableChannelManager.channelExists(ChannelId(channelIdStr)))

proc logosdelivery_channel_send(
    self: LogosDelivery, channelIdStr: string, messageJson: string
): Future[Result[string, string]] {.ffi.} =
  ## `messageJson` carries `{ "payload": <base64>, "ephemeral": <bool> }`.
  requireChannels(self, "ChannelSend"):
    return err(errMsg)

  var jsonNode: JsonNode
  try:
    jsonNode = parseJson(messageJson)
  except Exception as e:
    return err("Failed to parse channel message JSON: " & e.msg)

  if not jsonNode.hasKey("payload"):
    return err("Missing payload field")

  let payload = base64.decode(Base64String(jsonNode["payload"].getStr())).valueOr:
    return err("invalid payload format: " & error)

  let ephemeral = jsonNode.getOrDefault("ephemeral").getBool(false)

  let requestId = (
    await self.reliableChannelManager.send(ChannelId(channelIdStr), payload, ephemeral)
  ).valueOr:
    return err("ChannelSend failed: " & $error)

  return ok($requestId)

proc logosdelivery_channel_close(
    self: LogosDelivery, channelIdStr: string
): Future[Result[string, string]] {.ffi.} =
  requireChannels(self, "ChannelClose"):
    return err(errMsg)

  (await self.reliableChannelManager.closeChannel(ChannelId(channelIdStr))).isOkOr:
    return err("ChannelClose failed: " & $error)

  return ok("")

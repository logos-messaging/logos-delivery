import std/[json]
import chronos, results, ffi
import
  logos_delivery/waku/common/base64,
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_core/topics/content_topic,
  logos_delivery/api/types,
  ../declare_lib

proc logosdelivery_subscribe(
    self: LogosDelivery, contentTopicStr: string
): Future[Result[string, string]] {.ffi.} =
  requireMessaging(self, "Subscribe"):
    return err(errMsg)

  # ContentTopic is just a string type alias
  let contentTopic = ContentTopic(contentTopicStr)

  (await self.messagingClient.subscribe(contentTopic)).isOkOr:
    let errMsg = $error
    return err("Subscribe failed: " & errMsg)

  return ok("")

proc logosdelivery_unsubscribe(
    self: LogosDelivery, contentTopicStr: string
): Future[Result[string, string]] {.ffi.} =
  requireMessaging(self, "Unsubscribe"):
    return err(errMsg)

  # ContentTopic is just a string type alias
  let contentTopic = ContentTopic(contentTopicStr)

  self.messagingClient.unsubscribe(contentTopic).isOkOr:
    let errMsg = $error
    return err("Unsubscribe failed: " & errMsg)

  return ok("")

proc logosdelivery_send(
    self: LogosDelivery, messageJson: string
): Future[Result[string, string]] {.ffi.} =
  requireMessaging(self, "Send"):
    return err(errMsg)

  ## Parse the message JSON and send the message
  var jsonNode: JsonNode
  try:
    jsonNode = parseJson(messageJson)
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
  let requestId = (await self.messagingClient.send(envelope)).valueOr:
    let errMsg = $error
    return err("Send failed: " & errMsg)

  return ok($requestId)

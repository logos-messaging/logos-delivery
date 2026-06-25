proc messaging_send*(
    self: LogosDelivery, contentTopic: string, payload: seq[byte], ephemeral: bool
): Future[Result[string, string]] {.ffi.} =
  let envelope = MessageEnvelope.init(
    contentTopic = ContentTopic(contentTopic), payload = payload, ephemeral = ephemeral
  )
  let requestId = (await self.messagingClient.send(envelope)).valueOr:
    return err(error)
  return ok($requestId)

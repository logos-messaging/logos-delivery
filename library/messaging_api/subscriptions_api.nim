proc subscribe*(
    self: LogosDelivery, contentTopic: string
): Future[Result[string, string]] {.ffi.} =
  (await self.messagingClient.subscribe(ContentTopic(contentTopic))).isOkOr:
    return err(error)
  return ok("")

proc unsubscribe*(
    self: LogosDelivery, contentTopic: string
): Future[Result[string, string]] {.ffi.} =
  self.messagingClient.unsubscribe(ContentTopic(contentTopic)).isOkOr:
    return err(error)
  return ok("")

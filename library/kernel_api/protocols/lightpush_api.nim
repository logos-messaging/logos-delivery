proc lightpush_publish*(
    self: LogosDelivery, pubsubTopic: string, message: WakuMessage
): Future[Result[string, string]] {.ffi.} =
  ## Returns the published message hash.
  let hash = (await self.waku.lightpushPublish(PubsubTopic(pubsubTopic), message)).valueOr:
    return err(error)
  return ok(hash)

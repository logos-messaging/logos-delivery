proc ping_peer*(
    self: LogosDelivery, peerAddr: string, timeoutMs: int
): Future[Result[string, string]] {.ffi.} =
  ## Returns the round-trip time in nanoseconds.
  let rtt = (await self.waku.pingPeer(peerAddr, timeoutMs)).valueOr:
    return err(error)
  return ok($rtt)

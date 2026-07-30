import chronos, results, ffi
import logos_delivery, library/declare_lib

proc waku_ping_peer(
    self: LogosDelivery, peerAddr: string, timeoutMs: uint32
): Future[Result[string, string]] {.ffi.} =
  let rttNanos = (await self.waku.pingPeer(peerAddr, int(timeoutMs))).valueOr:
    return err(error)
  return ok($rttNanos)

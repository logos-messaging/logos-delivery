import chronos, results, ffi
import logos_delivery, library/declare_lib

proc waku_ping_peer(
    ld: LogosDelivery, peerAddr: cstring, timeoutMs: cuint
): Future[Result[string, string]] {.ffi.} =
  let rttNanos = (await ld.waku.pingPeer($peerAddr, int(timeoutMs))).valueOr:
    return err(error)
  return ok($rttNanos)

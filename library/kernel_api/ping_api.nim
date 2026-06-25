import chronos, results, ffi
import logos_delivery, library/declare_lib

proc waku_ping_peer(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    peerAddr: cstring,
    timeoutMs: cuint,
) {.ffi.} =
  let rttNanos = (await ctx.myLib[].waku.pingPeer($peerAddr, int(timeoutMs))).valueOr:
    return err(error)
  return ok($rttNanos)

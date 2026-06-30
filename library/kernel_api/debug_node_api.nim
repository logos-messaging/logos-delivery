import std/strutils
import chronos, results, ffi
import logos_delivery, library/declare_lib

proc waku_version(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  let v = (await ctx.myLib[].waku.version()).valueOr:
    return err(error)
  return ok(v)

proc waku_listen_addresses(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  ## returns a comma-separated string of the listen addresses
  let addrs = (await ctx.myLib[].waku.listenAddresses()).valueOr:
    return err(error)
  return ok(addrs.join(","))

proc waku_get_my_enr(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  let enrUri = (await ctx.myLib[].waku.myEnr()).valueOr:
    return err(error)
  return ok(enrUri)

proc waku_get_my_peerid(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  let peerId = (await ctx.myLib[].waku.myPeerId()).valueOr:
    return err(error)
  return ok(peerId)

proc waku_get_metrics(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  let m = (await ctx.myLib[].waku.metrics()).valueOr:
    return err(error)
  return ok(m)

proc waku_is_online(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  let online = (await ctx.myLib[].waku.isOnline()).valueOr:
    return err(error)
  return ok($online)

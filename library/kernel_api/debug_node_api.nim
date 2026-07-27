import std/strutils
import chronos, results, ffi
import logos_delivery, library/declare_lib

proc waku_version(ld: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  let v = (await ld.waku.version()).valueOr:
    return err(error)
  return ok(v)

proc waku_listen_addresses(ld: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  ## returns a comma-separated string of the listen addresses
  let addrs = (await ld.waku.listenAddresses()).valueOr:
    return err(error)
  return ok(addrs.join(","))

proc waku_get_my_enr(ld: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  let enrUri = (await ld.waku.myEnr()).valueOr:
    return err(error)
  return ok(enrUri)

proc waku_get_my_peerid(ld: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  let peerId = (await ld.waku.myPeerId()).valueOr:
    return err(error)
  return ok(peerId)

proc waku_get_metrics(ld: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  let m = (await ld.waku.metrics()).valueOr:
    return err(error)
  return ok(m)

proc waku_is_online(ld: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  let online = (await ld.waku.isOnline()).valueOr:
    return err(error)
  return ok($online)

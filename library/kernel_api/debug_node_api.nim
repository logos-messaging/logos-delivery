import std/strutils
import chronos, results, ffi
import logos_delivery, library/declare_lib

proc waku_version(self: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  let v = (await self.waku.version()).valueOr:
    return err(error)
  return ok(v)

proc waku_listen_addresses(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## returns a comma-separated string of the listen addresses
  let addrs = (await self.waku.listenAddresses()).valueOr:
    return err(error)
  return ok(addrs.join(","))

proc waku_get_my_enr(self: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  let enrUri = (await self.waku.myEnr()).valueOr:
    return err(error)
  return ok(enrUri)

proc waku_get_my_peerid(self: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  let peerId = (await self.waku.myPeerId()).valueOr:
    return err(error)
  return ok(peerId)

proc waku_get_metrics(self: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  let m = (await self.waku.metrics()).valueOr:
    return err(error)
  return ok(m)

proc waku_is_online(self: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  let online = (await self.waku.isOnline()).valueOr:
    return err(error)
  return ok($online)

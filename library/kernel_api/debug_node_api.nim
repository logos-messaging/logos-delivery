## The waku api getters are synchronous and can't fail, so the bodies just wrap
## the value; the `{.ffi.}` macro wraps it into the `Future` it must expose.

proc version*(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  return ok(self.waku.version())

proc listen_addresses*(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  return ok(self.waku.listenAddresses().join(","))

proc get_my_enr*(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  return ok(self.waku.myEnr())

proc get_my_peerid*(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  return ok(self.waku.myPeerId())

proc get_metrics*(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  return ok(self.waku.metrics())

proc is_online*(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  return ok($self.waku.isOnline())

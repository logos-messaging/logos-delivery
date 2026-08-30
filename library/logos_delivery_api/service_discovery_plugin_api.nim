import chronos, chronicles, results, ffi
import
  logos_delivery,
  logos_delivery/waku/discovery/plugin/service_discovery_accessor,
  ../declare_lib

## Registration surface for the external service-discovery plugin declared in
## `library/logosdelivery_service_discovery.h`.
##
## The vtable travels as its address, not as a payload: it is a struct of
## function pointers, which neither the CBOR wire nor the (mt) broker codec can
## marshal. Passing the address is also what lets the node thread run the
## registration, and that matters -- `SetServiceDiscoveryPlugin`'s provider is
## registered by `ExternalServiceDiscovery.new` into a thread-local registry on
## the node's FFI thread, so it is unreachable from the host thread that calls
## the C entry point. Routing through `{.ffi.}` puts the request on the thread
## that owns the provider.
##
## The caller keeps ownership of the struct and must keep it alive until the
## reply callback fires; the provider copies it into a lock-guarded global that
## the discovery worker thread reads.
##
## When the node was not configured for external discovery no backend exists to
## provide the broker, so the request fails with "no provider registered" -- the
## refusal the header documents for registration without configuration.

proc logosdelivery_set_service_discovery_plugin(
    self: LogosDelivery, pluginPtr: uint64
): Future[Result[string, string]] {.ffi.} =
  ## Installs (or replaces) the service-discovery plugin.
  ## pluginPtr - address of an `LdServiceDiscoveryPlugin`, borrowed for the call
  if pluginPtr == 0:
    error "SET_SERVICE_DISCOVERY_PLUGIN failed", err = "null plugin pointer"
    return err("plugin pointer is null")

  let plugin = cast[ptr ServiceDiscoveryPlugin](pluginPtr)[]
  (await SetServiceDiscoveryPlugin.request(self.waku.brokerCtx, plugin)).isOkOr:
    error "SET_SERVICE_DISCOVERY_PLUGIN failed", err = error
    return err(error)
  return ok("service discovery plugin installed")

proc logosdelivery_clear_service_discovery_plugin(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## Removes the installed plugin; discovery verbs fail until a new one arrives.
  (await ClearServiceDiscoveryPlugin.request(self.waku.brokerCtx)).isOkOr:
    error "CLEAR_SERVICE_DISCOVERY_PLUGIN failed", err = error
    return err(error)
  return ok("service discovery plugin cleared")

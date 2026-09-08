import chronos, chronicles, results, ffi
import
  logos_delivery,
  logos_delivery/waku/discovery/plugin/service_discovery_accessor,
  ../declare_lib

## Registration entry points for the external service-discovery plugin
## declared in `library/logosdelivery_service_discovery.h`.
##
## The vtable is passed by address: a struct of function pointers cannot be
## marshalled, and the request has to run on the node's FFI thread, where the
## provider lives. The caller keeps the struct alive until the reply callback
## fires. Without external-discovery configuration there is no provider and
## the request fails with "no provider registered".

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

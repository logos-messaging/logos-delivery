import chronos, chronicles, results, ffi
import
  logos_delivery, logos_delivery/waku/rln/rln_lez/plugin_accessor, ../declare_lib

## Registration surface for the external RLN plugin declared in
## `library/liblogosdelivery_rln.h`.
##
## The vtable travels as its address, not as a payload: it is a struct of
## function pointers, which neither the CBOR wire nor the (mt) broker codec
## can marshal. Routing through `{.ffi.}` puts the request on the node thread
## that owns the `SetRlnPlugin` provider (registered by the lez backend).
##
## The caller keeps ownership of the struct; it is borrowed only for the
## duration of the install call — the provider validates and copies it.
##
## When the node was not configured for lez RLN no backend exists to provide
## the broker, so the request fails with "no provider registered" — the
## refusal the header documents for registration without configuration.

proc logosdelivery_set_rln_plugin(
    self: LogosDelivery, pluginPtr: uint64
): Future[Result[string, string]] {.ffi.} =
  ## Installs (or replaces) the RLN plugin.
  ## pluginPtr - address of an `LdRlnPlugin`, borrowed for the call
  if pluginPtr == 0:
    error "SET_RLN_PLUGIN failed", err = "null plugin pointer"
    return err("plugin pointer is null")

  let plugin = cast[ptr RlnPlugin](pluginPtr)[]
  (await SetRlnPlugin.request(self.waku.brokerCtx, plugin)).isOkOr:
    error "SET_RLN_PLUGIN failed", err = error
    return err(error)
  return ok("rln plugin installed")

proc logosdelivery_clear_rln_plugin(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## Removes the installed plugin; RLN verbs fail until a new one arrives.
  (await ClearRlnPlugin.request(self.waku.brokerCtx)).isOkOr:
    error "CLEAR_RLN_PLUGIN failed", err = error
    return err(error)
  return ok("rln plugin cleared")

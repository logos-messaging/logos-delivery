import std/[macros, os]
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

macro emitAbiLayoutGuards(T: typedesc, cname: static string, header: static string) =
  ## Emits one C `_Static_assert` per field of the Nim mirror `T` against the
  ## C struct `cname` from `header`, plus size and ABI-version checks, so a
  ## mirror that drifts from the header fails the C compile of this library
  ## with the field's name in the message. This module is the one place both
  ## sides are visible: the header pulls in the generated `logosdelivery.h`,
  ## which exists only in the library build.
  var text =
    "_Static_assert(LD_DISCO_ABI_VERSION == " & $LdDiscoAbiVersion &
    ", \"LD_DISCO_ABI_VERSION drifted from LdDiscoAbiVersion\");\n"
  let impl = getTypeImpl(T)[1].getTypeImpl()
  for def in impl[2]:
    let field = def[0]
    text.add "_Static_assert(offsetof(" & cname & ", " & $field & ") == " &
      $getOffset(field) & ", \"" & cname & "." & $field &
      " drifted from the Nim mirror\");\n"
  text.add "_Static_assert(sizeof(" & cname & ") == " & $getSize(T) & ", \"" & cname &
    " size drifted from the Nim mirror\");\n"
  result = newStmtList(
    nnkPragma.newTree(
      nnkExprColonExpr.newTree(
        ident"emit",
        newLit(
          "/*INCLUDESECTION*/\n#include <stddef.h>\n#define LD_DISCO_ABI_ONLY 1\n#include \"" &
            header & "\"\n"
        ),
      )
    ),
    nnkPragma.newTree(nnkExprColonExpr.newTree(ident"emit", newLit(text))),
  )

const PluginHeader =
  currentSourcePath().parentDir().parentDir() / "logosdelivery_service_discovery.h"

emitAbiLayoutGuards(ServiceDiscoveryPlugin, "LdServiceDiscoveryPlugin", PluginHeader)

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

import std/[atomics, options]
import chronicles, chronos, chronos/threadsync, ffi
import waku/factory/waku, waku/node/waku_node, ./declare_lib

################################################################################
## Include different APIs, i.e. all procs with {.ffi.} pragma
include ./logos_delivery_api/node_api, ./logos_delivery_api/messaging_api

################################################################################
### Exported procs

proc logosdelivery_destroy(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)

  ffi.destroyFFIContext(ctx).isOkOr:
    let msg = "liblogosdelivery error: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  ## always need to invoke the callback although we don't retrieve value to the caller
  callback(RET_OK, nil, 0, userData)

  return RET_OK

# ### End of exported procs
# ################################################################################

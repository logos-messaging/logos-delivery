import std/[atomics, options]
import chronicles, chronos, chronos/threadsync, ffi
import waku/factory/waku, waku/node/waku_node, ./declare_lib

################################################################################
## Include different APIs, i.e. all procs with {.ffi.} pragma
include ./lmapi/node_api, ./lmapi/messaging_api

################################################################################
### Exported procs

proc lmapi_destroy(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkParams(ctx, callback, userData)

  ffi.destroyFFIContext(ctx).isOkOr:
    let msg = "liblmapi error: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  ## always need to invoke the callback although we don't retrieve value to the caller
  callback(RET_OK, nil, 0, userData)

  return RET_OK

# ### End of exported procs
# ################################################################################

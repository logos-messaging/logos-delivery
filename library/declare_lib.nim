import ffi
import waku/factory/waku

declareLibrary("waku")

proc set_event_callback(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.dynlib, exportc, cdecl.} =
  ctx[].eventCallback = cast[pointer](callback)
  ctx[].eventUserData = userData

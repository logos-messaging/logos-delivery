import ffi
import std/locks
import results
import logos_delivery

declareLibrary("logosdelivery")

var eventCallbackLock: Lock
initLock(eventCallbackLock)

template requireInitializedNode*(
    ctx: ptr FFIContext[LogosDelivery], opName: string, onError: untyped
) =
  if isNil(ctx):
    let errMsg {.inject.} = opName & " failed: invalid context"
    onError
  elif isNil(ctx.myLib) or isNil(ctx.myLib[]):
    let errMsg {.inject.} = opName & " failed: node is not initialized"
    onError

template requireMessaging*(
    ctx: ptr FFIContext[LogosDelivery], opName: string, onError: untyped
) =
  ## Use after `requireInitializedNode`. Fails if the node has no messaging client
  ## (a kernel-only / fleet node).
  ctx.myLib[].ensureMessaging().isOkOr:
    let errMsg {.inject.} = opName & " failed: " & error
    onError

template requireChannels*(
    ctx: ptr FFIContext[LogosDelivery], opName: string, onError: untyped
) =
  ## Use after `requireInitializedNode`. Fails if the node has no reliable channel
  ## manager (a kernel-only / fleet node).
  ctx.myLib[].ensureChannels().isOkOr:
    let errMsg {.inject.} = opName & " failed: " & error
    onError

proc logosdelivery_set_event_callback(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.dynlib, exportc, cdecl.} =
  if isNil(ctx):
    echo "error: invalid context in logosdelivery_set_event_callback"
    return

  # prevent race conditions that might happen due incorrect usage.
  eventCallbackLock.acquire()
  defer:
    eventCallbackLock.release()

  ctx[].eventCallback = cast[pointer](callback)
  ctx[].eventUserData = userData

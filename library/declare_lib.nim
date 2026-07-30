import ffi
import results
import logos_delivery

declareLibrary("logosdelivery", LogosDelivery)

template checkParams*(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) =
  ## Re-implements the `checkParams` helper dropped from nim-ffi in 0.3.0.
  if not ctx.isNil():
    ctx[].userData = userData
  if callback.isNil():
    return RET_MISSING_CALLBACK

template emitEvent*(eventName: string, body: untyped) =
  ## Enqueues `body`'s payload for nim-ffi's event thread to fan out to listeners.
  ## Callers are `{.async: (raises: []).}` broker listeners, and the payload
  ## builders infer an `Exception` effect, so nothing narrower than `Exception`
  ## compiles here. That also swallows `Defect`, which is why the handler only
  ## logs: a defect raised while rendering one event must not take the node down,
  ## and it cannot be re-raised without breaking the `raises: []` contract.
  try:
    dispatchFFIEvent(eventName):
      body
  except Exception as e:
    chronicles.error "failed to emit FFI event", event = eventName, err = e.msg

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

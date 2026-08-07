import ffi
import results
import logos_delivery

declareLibrary("logosdelivery", LogosDelivery, defaultABIFormat = "c")

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

template requireMessaging*(self: LogosDelivery, opName: string, onError: untyped) =
  ## Fails if the node has no messaging client (a kernel-only / fleet node).
  self.ensureMessaging().isOkOr:
    let errMsg {.inject.} = opName & " failed: " & error
    onError

template requireChannels*(self: LogosDelivery, opName: string, onError: untyped) =
  ## Fails if the node has no reliable channel manager (a kernel-only / fleet node).
  self.ensureChannels().isOkOr:
    let errMsg {.inject.} = opName & " failed: " & error
    onError

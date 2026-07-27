import ffi
import results
import logos_delivery

declareLibrary("logosdelivery", LogosDelivery)

template requireInitializedNode*(ld: LogosDelivery, opName: string, onError: untyped) =
  if ld.isNil():
    let errMsg {.inject.} = opName & " failed: node is not initialized"
    onError

template requireMessaging*(ld: LogosDelivery, opName: string, onError: untyped) =
  ## Use after `requireInitializedNode`. Fails if the node has no messaging client
  ## (a kernel-only / fleet node).
  ld.ensureMessaging().isOkOr:
    let errMsg {.inject.} = opName & " failed: " & error
    onError

template requireChannels*(ld: LogosDelivery, opName: string, onError: untyped) =
  ## Use after `requireInitializedNode`. Fails if the node has no reliable channel
  ## manager (a kernel-only / fleet node).
  ld.ensureChannels().isOkOr:
    let errMsg {.inject.} = opName & " failed: " & error
    onError

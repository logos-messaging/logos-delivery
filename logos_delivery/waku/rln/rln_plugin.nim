{.push raises: [].}

## Backend-agnostic RLN plugin surface.
##
## Node core refers to RLN backends only through these types: a mounted
## backend is an `RlnPlugin` record of closures, and the factory selects the
## backend to mount by walking `RlnPluginDescriptor`s. Concrete backend names
## appear only in each backend's own directory and at the composition root
## (the factory's descriptor list); nothing here enumerates them.
##
## Node core reaches the per-message operations (`validateProof`,
## `generateProof`) through the record as well.

import chronos, results

import
  logos_delivery/waku/common/error_handling,
  logos_delivery/waku/waku_core/message/message,
  ./types

export results

type
  RlnPlugin* = object
    ## Node core's handle on the mounted RLN backend. Closure fields may be
    ## nil when the backend has no such concept.
    name*: string ## for logs and metrics only, never for dispatch
    stop*: proc(): Future[void] {.gcsafe, raises: [].}
    isReady*: proc(): Future[bool] {.gcsafe, raises: [].}
    onProofRejected*: proc() {.gcsafe, raises: [].}
      ## Called when a publish was rejected as RLN-invalid, so the backend can
      ## refresh whatever the proof was built against. Nil for backends
      ## without such a concept.
    validateProof*: proc(
      message: WakuMessage
    ): Future[Result[ValidationResult, RlnError]] {.gcsafe, raises: [].}
      ## Verdict on a received message's proof. An error means the backend
      ## could not decide; the relay validator then ignores the message
      ## instead of rejecting it.
    generateProof*: proc(message: WakuMessage): Future[Result[seq[byte], RlnError]] {.
      gcsafe, raises: []
    .}
      ## Proof for an outgoing message, as the bytes its `proof` field carries.
      ## Each backend derives the epoch its own way.

  RlnCommonConf* = object
    ## Node-local settings shared by every backend. A backend's own
    ## parameters live in its own config module and are captured by its
    ## descriptor's closures at the composition root.
    onFatalErrorAction*: OnFatalErrorHandler
    disableValidation*: bool
      ## When true, published messages still get proofs attached, but
      ## received messages are not validated — they pass through unchecked.

  RlnPluginDescriptor* = object
    ## One mountable backend, as seen by the factory's selection walk.
    name*: string
    matches*: proc(): bool {.gcsafe, raises: [].}
      ## True when this backend's configuration source is present.
    mount*: proc(commonConf: RlnCommonConf): Future[Result[RlnPlugin, string]] {.
      gcsafe, raises: []
    .}

proc selectRlnPlugin*(
    descriptors: openArray[RlnPluginDescriptor]
): Result[Opt[RlnPluginDescriptor], string] =
  ## Picks the single backend whose configuration source is present. More
  ## than one match is a configuration error; none means RLN stays off.
  var selected = Opt.none(RlnPluginDescriptor)
  for descriptor in descriptors:
    if not descriptor.matches():
      continue
    if selected.isSome():
      return err(
        "two RLN backends requested: both '" & selected.get().name & "' and '" &
          descriptor.name & "' configuration sources are present"
      )
    selected = Opt.some(descriptor)
  return ok(selected)

{.pop.}

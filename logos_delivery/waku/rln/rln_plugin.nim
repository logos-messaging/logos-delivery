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

import logos_delivery/waku/waku_core/message/message, ./types

export results

type
  SpamHandler* =
    proc(wakuMessage: WakuMessage): void {.gcsafe, closure, raises: [Defect].}
    ## Called by the RLN relay validator for a message whose proof shows a
    ## rate-limit violation.

  RlnPlugin* = object
    ## Node core's handle on the mounted RLN backend. Closure fields may be
    ## nil when the backend has no such concept.
    name*: string ## for logs and metrics only, never for dispatch
    stop*: proc(): Future[void] {.gcsafe, raises: [].}
    isReady*: proc(): Future[bool] {.async: (raises: [CancelledError]), gcsafe.}
    onProofRejected*: proc() {.gcsafe, raises: [].}
      ## Called when a publish was rejected as RLN-invalid, so the backend can
      ## refresh whatever the proof was built against. Must not block: callers
      ## such as the send service loop do not wait for the refresh. Nil for
      ## backends without such a concept.
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
    onNodeStarted*: proc(): Future[void] {.async: (raises: [CancelledError]), gcsafe.}
      ## Called once the node has started. The backend handles its own
      ## failures; only cancellation reaches the caller. Nil for backends with
      ## nothing to do at that point.
    getEpochQuota*: proc(timestamp: uint64): Future[Result[EpochQuota, RlnError]] {.
      gcsafe, raises: []
    .}
      ## Budget snapshot for the epoch derived from `timestamp` (Unix seconds),
      ## so the epoch and the remaining budget cannot straddle an epoch
      ## boundary. The answer must count message ids spent before a restart:
      ## the backend that draws the ids owns that state and must persist it.
      ## Nil for backends that keep no budget.

  RlnCommonConf* = object
    ## Node-side RLN relay settings, independent of the mounted backend. A
    ## backend's own parameters live in its own config module and are
    ## captured by its descriptor's closures at the composition root.
    disableValidation*: bool
      ## When true, published messages still get proofs attached, but
      ## received messages are not validated — they pass through unchecked.

  RlnPluginDescriptor* = object
    ## One mountable backend, as seen by the factory's selection walk.
    name*: string
    matches*: proc(): bool {.gcsafe, raises: [].}
      ## True when this backend's configuration source is present.
    mount*: proc(): Future[Result[RlnPlugin, string]] {.gcsafe, raises: [].}

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

proc attachProof*(
    plugin: Opt[RlnPlugin], message: WakuMessage
): Future[Result[WakuMessage, RlnError]] {.async.} =
  ## Returns `message` carrying a proof from the mounted backend. A message
  ## that already has one is returned untouched, so a retry neither redraws a
  ## nonce nor changes the bytes. Without a backend that generates proofs the
  ## message passes through unproven.
  if message.proof.len > 0:
    return ok(message)

  let backend = plugin.valueOr:
    return ok(message)
  if backend.generateProof.isNil():
    return ok(message)

  var msgWithProof = message
  msgWithProof.proof = ?(await backend.generateProof(message))
  return ok(msgWithProof)

proc epochQuota*(
    plugin: Opt[RlnPlugin], timestamp: uint64
): Future[Result[EpochQuota, RlnError]] {.async.} =
  ## The mounted backend's budget snapshot for the epoch derived from
  ## `timestamp` (Unix seconds). NotReady without a backend, since one can
  ## mount later; Permanent when the backend keeps no budget.
  let backend = plugin.valueOr:
    return err(RlnError.notReady("no RLN backend is mounted"))
  if backend.getEpochQuota.isNil():
    return err(RlnError.permanent("the mounted RLN backend keeps no epoch budget"))
  return await backend.getEpochQuota(timestamp)

proc notifyProofRejected*(plugin: Opt[RlnPlugin]): bool =
  ## Tells the mounted backend that a publish was rejected as RLN-invalid, so
  ## it can refresh whatever proofs are built against. False when there is no
  ## backend or it has no such hook.
  let backend = plugin.valueOr:
    return false
  if backend.onProofRejected.isNil():
    return false
  backend.onProofRejected()
  return true

{.pop.}

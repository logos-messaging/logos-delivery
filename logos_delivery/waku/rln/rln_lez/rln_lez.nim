{.push raises: [].}

## `RlnInterface` backend over the external RLN module's FFI crossing
## (`./transport`). Each call maps the concept's typed surface onto the wire
## procs and decodes the module's reply dialects back into typed results; the
## conformance assert at the bottom is the compile-time firewall check.
##
## Ready to serve once the host has installed its RLN callbacks
## (`logosdelivery_rln_set_callbacks`); before that every call fails NotReady.

import std/json
import chronos, chronicles, results
import stew/byteutils
import ./types, ./transport, ./config
import ../rln_api

export types, config

logScope:
  topics = "waku rln lez"

type RlnLez* = ref object
  ## The typed calls below are the RlnInterface backend proper; the fields
  ## carry the node's own view of it: the membership scope it proves under
  ## and the cached membership verification the send path reads. The default
  ## zero state is valid — a scope-less instance can still serve typed calls.
  scope*: MembershipScope
  epochSizeSec*: uint64
  membershipVerified*: bool
    ## The membership check has passed once; `attachRlnProof` skips the
    ## registry read on later sends.

proc init*(T: type RlnLez): T =
  RlnLez()

proc init*(T: type RlnLez, scope: MembershipScope, epochSizeSec: uint64): T =
  RlnLez(scope: scope, epochSizeSec: epochSizeSec)

proc toRlnError(transportErr: string): RlnError =
  ## Transport-level failures never carry a wire error object: no callbacks
  ## installed yet is NotReady by the contract; timeouts and alloc failures
  ## are retryable.
  if transportErr == "RLN module not registered":
    RlnError.notReady(transportErr)
  else:
    RlnError.transient(transportErr)

proc start*(
    m: RlnLez, config: string
): Future[Result[void, RlnError]] {.async: (raises: [CancelledError]).} =
  ## `config` is the module's start config JSON (the node_factory shape:
  ## epoch_size_sec, registries).
  let response = (await rlnStart(config)).valueOr:
    return err(toRlnError(error))
  discard ?parseRlnResultEnvelope(response)
  return ok()

proc stop*(
    m: RlnLez
): Future[Result[void, RlnError]] {.async: (raises: [CancelledError]).} =
  let response = (await rlnStop()).valueOr:
    return err(toRlnError(error))
  discard ?parseRlnResultEnvelope(response)
  return ok()

proc registerMembership*(
    m: RlnLez, scope: MembershipScope, options: RegistryOptions
): Future[Result[MembershipState, RlnError]] {.async: (raises: [CancelledError]).} =
  var optionsJson = newJArray()
  for opt in options:
    optionsJson.add(%*{"key": opt.key, "value": opt.value})
  let response = (
    await rlnRegister(scope.registryId, scope.rlnIdentifier.toHex(), $optionsJson)
  ).valueOr:
    return err(toRlnError(error))
  return parseRlnMembershipState(response)

proc getMembershipState*(
    m: RlnLez, scope: MembershipScope
): Future[Result[MembershipState, RlnError]] {.async: (raises: [CancelledError]).} =
  let response = (
    await rlnGetMembershipState(scope.registryId, scope.rlnIdentifier.toHex())
  ).valueOr:
    return err(toRlnError(error))
  return parseRlnMembershipState(response)

proc getEpochQuota*(
    m: RlnLez, scope: MembershipScope, timestamp: uint64
): Future[Result[EpochQuota, RlnError]] {.async: (raises: [CancelledError]).} =
  let response = (
    await rlnGetEpochQuota(scope.registryId, scope.rlnIdentifier.toHex(), timestamp)
  ).valueOr:
    return err(toRlnError(error))
  return parseRlnEpochQuota(response)

proc generateProof*(
    m: RlnLez, scope: MembershipScope, signal: seq[byte], timestamp: uint64
): Future[Result[RateLimitProof, RlnError]] {.async: (raises: [CancelledError]).} =
  let response = (
    await rlnGenerateProof(
      scope.registryId, scope.rlnIdentifier.toHex(), signal.toHex(), timestamp
    )
  ).valueOr:
    return err(toRlnError(error))
  let blob = ?parseRlnGeneratedProof(response)
  if blob.len != RlnProofSize:
    return err(RlnError.transient(
      "proof_canonical is " & $blob.len & " bytes, expected " & $RlnProofSize
    ))
  # `proof` is the authoritative canonical serialization; the decoded
  # public-value view stays zeroed — the module recomputes it on verification.
  var proof = RateLimitProof()
  copyMem(addr proof.proof[0], unsafeAddr blob[0], RlnProofSize)
  return ok(proof)

proc validateProof*(
    m: RlnLez,
    scope: MembershipScope,
    signal: seq[byte],
    timestamp: uint64,
    proof: RateLimitProof,
): Future[Result[ValidationResult, RlnError]] {.async: (raises: [CancelledError]).} =
  let proofJson = $(%*{"proof": proof.proof.toHex()})
  let response = (
    await rlnValidateProof(
      scope.registryId, scope.rlnIdentifier.toHex(), signal.toHex(), timestamp,
      proofJson,
    )
  ).valueOr:
    return err(toRlnError(error))
  return parseRlnValidationResult(response)

static:
  doAssert RlnLez is RlnInterface

## Node bring-up over the backend, driven from node start — the module is only
## reachable then, once the host has installed its RLN callbacks. The instance
## itself is created at mount (protocol setup), which is local wiring only.

const
  RlnStartAttempts = 3
  RlnStartRetryDelay = 2.seconds

proc startModule*(
    w: RlnLez
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  ## Starts the external RLN module. epoch_size_sec must equal this node's
  ## epoch size so proof generators and validators derive the same epoch;
  ## listing the registry warms its valid-root window. NotReady/Transient
  ## failures are retried briefly (the module bridge may still be coming up);
  ## a Permanent failure is returned at once.
  w.membershipVerified = false
  let config =
    $(%*{"epoch_size_sec": w.epochSizeSec, "registries": [w.scope.registryId]})
  var lastErr: RlnError
  for attempt in 1 .. RlnStartAttempts:
    let res = await w.start(config)
    if res.isOk():
      return ok()
    lastErr = res.error
    if lastErr.kind notin {RlnErrorKind.NotReady, RlnErrorKind.Transient}:
      break
    if attempt < RlnStartAttempts:
      debug "RLN module start not ready, retrying", attempt = attempt, error = $lastErr
      await sleepAsync(RlnStartRetryDelay)
  return err($lastErr)

proc verifyMembership*(
    w: RlnLez
): Future[Result[MembershipStatus, string]] {.async: (raises: [CancelledError]).} =
  ## Reads the scope's membership state from the module. A usable membership
  ## (Active/GracePeriod) is cached in `membershipVerified` so later sends
  ## skip the registry read; a failed or non-usable check is not cached, so
  ## the next call retries.
  let state = (await w.getMembershipState(w.scope)).valueOr:
    return err($error)
  if state.status.isUsable():
    w.membershipVerified = true
  return ok(state.status)

{.pop.}

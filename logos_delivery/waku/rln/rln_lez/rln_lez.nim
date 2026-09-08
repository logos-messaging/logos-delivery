{.push raises: [].}

## `RlnInterface` backend over the external RLN module's FFI crossing
## (`./transport`). Each call maps the concept's typed surface onto the wire
## procs and decodes the module's reply dialects back into typed results; the
## conformance assert at the bottom is the compile-time firewall check.
##
## Ready to serve once the host has installed its RLN callbacks
## (`logosdelivery_rln_set_callbacks`); before that every call fails NotReady.

import std/json
import chronos, results
import stew/byteutils
import ./types, ./transport
import ../rln_api

export types

type RlnLez* = ref object

proc init*(T: type RlnLez): T =
  RlnLez()

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

{.pop.}

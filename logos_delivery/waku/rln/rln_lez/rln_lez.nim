{.push raises: [].}

## `RlnInterface` backend over the external RLN plugin (`./transport`).
## Implementation-agnostic: the library never names a membership or a registry,
## never configures the backend and never starts it — the host owns all of that
## and supplies whatever its implementation needs when it forwards a call.
## Calls fail NotReady until the host has installed its plugin
## (`logosdelivery_rln_set_plugin`).

import std/json
import chronos, chronicles, results
import stew/byteutils
import logos_delivery/waku/waku_core/message/message
from logos_delivery/waku/rln/rln_evm/proof import toRLNSignal
import ../types, ./transport
import ../rln_api, ../rln_plugin

export types

logScope:
  topics = "waku rln lez"

type RlnLez* = ref object
  ## The typed calls below are the RlnInterface backend proper. The single
  ## field is the node's cached view of whether it may send: the host's
  ## implementation knows which membership that refers to.
  membershipVerified*: bool
    ## The membership check has passed once; `attachRlnProof` skips the
    ## registry read on later sends.

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

proc getMembershipState*(
    m: RlnLez
): Future[Result[MembershipState, RlnError]] {.async: (raises: [CancelledError]).} =
  let response = (await rlnGetMembershipState()).valueOr:
    return err(toRlnError(error))
  return parseRlnMembershipState(response)

proc getEpochQuota*(
    m: RlnLez, timestamp: uint64
): Future[Result[EpochQuota, RlnError]] {.async: (raises: [CancelledError]).} =
  let response = (await rlnGetEpochQuota(timestamp)).valueOr:
    return err(toRlnError(error))
  return parseRlnEpochQuota(response)

proc generateProof*(
    m: RlnLez, signal: seq[byte], timestamp: uint64
): Future[Result[RateLimitProof, RlnError]] {.async: (raises: [CancelledError]).} =
  let response = (await rlnGenerateProof(signal.toHex(), timestamp)).valueOr:
    return err(toRlnError(error))
  let blob = ?parseRlnGeneratedProof(response)
  if blob.len != RlnProofSize:
    return err(
      RlnError.transient(
        "proof_canonical is " & $blob.len & " bytes, expected " & $RlnProofSize
      )
    )
  # `proof` is the authoritative canonical serialization; the decoded
  # public-value view stays zeroed — the module recomputes it on verification.
  var proof = RateLimitProof()
  copyMem(addr proof.proof[0], unsafeAddr blob[0], RlnProofSize)
  return ok(proof)

proc validateProof*(
    m: RlnLez, signal: seq[byte], timestamp: uint64, proof: RateLimitProof
): Future[Result[ValidationResult, RlnError]] {.async: (raises: [CancelledError]).} =
  let proofJson = $(%*{"proof": proof.proof.toHex()})
  let response = (await rlnValidateProof(signal.toHex(), timestamp, proofJson)).valueOr:
    return err(toRlnError(error))
  return parseRlnValidationResult(response)

static:
  doAssert RlnLez is RlnInterface

proc verifyMembership*(
    w: RlnLez
): Future[Result[MembershipStatus, string]] {.async: (raises: [CancelledError]).} =
  ## Reads the membership state from the host's implementation; a usable
  ## result (Active/GracePeriod) sets `membershipVerified`.
  let state = (await w.getMembershipState()).valueOr:
    return err($error)
  if state.status.isUsable():
    w.membershipVerified = true
  return ok(state.status)

proc toRlnPlugin*(lez: RlnLez): RlnPlugin =
  ## The node's handle on this backend (`node.rlnPlugin`). The host owns the
  ## backend's lifecycle, health and proof refresh, so those closures stay nil.
  proc validate(
      message: WakuMessage
  ): Future[Result[ValidationResult, RlnError]] {.async.} =
    ## Local checks, then the host's verdict over `./transport`.
    if message.timestamp < 0:
      trace "RLN validator reject", error = "Negative message timestamp"
      return ok(ValidationResult(verdict: ProofVerdict.Invalid))
    if message.proof.len == 0:
      trace "RLN validator reject", error = "Message has no RLN proof"
      return ok(ValidationResult(verdict: ProofVerdict.Invalid))
    let timestamp = uint64(message.timestamp div 1_000_000_000)

    let proofJson = $(%*{"proof": message.proof.toHex()})
    let response = (
      await rlnValidateProof(message.toRLNSignal().toHex(), timestamp, proofJson)
    ).valueOr:
      return err(toRlnError(error))
    return parseRlnValidationResult(response)

  proc generate(message: WakuMessage): Future[Result[seq[byte], RlnError]] {.async.} =
    ## The membership gate, then the host's proof over `./transport`. A passed
    ## gate is cached on `lez`, which `nodeStarted` below also sets.
    if message.timestamp <= 0:
      return err(RlnError.permanent("the message has not been timestamped"))
    let timestamp = uint64(message.timestamp div 1_000_000_000)

    if not lez.membershipVerified:
      let status = (await lez.verifyMembership()).valueOr:
        return err(RlnError.transient("could not verify the RLN membership: " & error))
      if not lez.membershipVerified:
        return err(RlnError.notReady("no usable RLN membership: " & $status))

    let response = (await rlnGenerateProof(message.toRLNSignal().toHex(), timestamp)).valueOr:
      return err(toRlnError(error))
    return parseRlnGeneratedProof(response)

  proc nodeStarted(): Future[void] {.async.} =
    ## Membership only gates sending, so verify it non-fatally: a validate-only
    ## node is legitimate, and a Pending membership can settle later. A pass is
    ## cached on `lez` so the send path skips the registry read; anything else
    ## is retried per send.
    let membershipRes =
      try:
        await lez.verifyMembership()
      except CancelledError:
        Result[MembershipStatus, string].err("cancelled")
    if membershipRes.isErr():
      notice "could not verify RLN membership at startup", error = membershipRes.error
    elif not membershipRes.get().isUsable():
      notice "node has no usable RLN membership; sends will fail until it is active",
        status = $membershipRes.get()
    else:
      info "RLN membership verified", status = $membershipRes.get()

  return RlnPlugin(
    name: "external",
    validateProof: validate,
    generateProof: generate,
    onNodeStarted: nodeStarted,
  )

proc rlnLezDescriptor*(): RlnPluginDescriptor =
  ## Selected when the host has installed its RLN plugin over the C ABI
  ## (`logosdelivery_rln_set_plugin`); the host owns the backend's parameters.
  proc present(): bool =
    rlnPluginRegistered()

  proc mount(commonConf: RlnCommonConf): Future[Result[RlnPlugin, string]] {.async.} =
    return ok(RlnLez.init().toRlnPlugin())

  return RlnPluginDescriptor(name: "external", matches: present, mount: mount)

{.pop.}

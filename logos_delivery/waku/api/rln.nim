## Waku layer API — RLN (Rate Limiting Nullifier) operations.
##
## Consumer-facing surface mirroring the RLN Module API spec
## (logos-lips `docs/anoncomms/raw/rln-api.md`).
{.push raises: [].}

import std/times
import results, chronos

import logos_delivery/waku/waku
import logos_delivery/waku/[node/waku_node, rln, rln/protocol_types, rln/nonce_manager]
import logos_delivery/waku/rln/api/types as rln_api_types

export rln_api_types

proc rlnRegister*(
    self: Waku, scope: MembershipScope, options: RegistryOptions
): Future[Result[MembershipState, string]] {.async.} =
  ## Membership registration through the API is not supported yet: the mounted
  ## RLN implementation registers its membership at mount time.
  return err("rlnRegister: registration through the API is not supported yet")

proc rlnMembershipState*(
    self: Waku, scope: MembershipScope
): Future[Result[MembershipState, string]] {.async.} =
  if self.node.rln.isNil():
    return err("rlnMembershipState: RLN not mounted")
  return err("rlnMembershipState: not supported by the mounted RLN implementation yet")

proc rlnEpochQuota*(
    self: Waku, scope: MembershipScope, timestamp: uint64
): Future[Result[EpochQuota, string]] {.async.} =
  ## Budget snapshot for the epoch derived from `timestamp` (Unix seconds).
  ## The mounted implementation has a single implicit membership, so `scope`
  ## does not select one yet, and spent budget is only tracked for the
  ## current epoch.
  if self.node.rln.isNil():
    return err("rlnEpochQuota: RLN not mounted")

  let rlnPeer = self.node.rln
  let limit = rlnPeer.groupManager.userMessageLimit.valueOr:
    return err("rlnEpochQuota: user message limit is not set")

  let rateLimit = uint64(limit)
  let epoch = rlnPeer.calcEpoch(timestamp.float64)
  let nm = rlnPeer.nonceManager
  let spent =
    if epoch != rlnPeer.getCurrentEpoch():
      0'u64
    elif getTime().toUnixFloat() - nm.lastNonceTime >= nm.epoch:
      0'u64
    else:
      min(nm.nextNonce, rateLimit)

  return ok(
    EpochQuota(
      epochIndex: fromEpoch(epoch), rateLimit: rateLimit, remaining: rateLimit - spent
    )
  )

proc rlnGenerateProof*(
    self: Waku, scope: MembershipScope, signal: seq[byte], timestamp: uint64
): Future[Result[seq[byte], string]] {.async.} =
  ## Generates a rate-limit proof over `signal` for the epoch derived from
  ## `timestamp` (Unix seconds). Returns the wire-encoded proof as carried in
  ## the message `proof` field.
  if self.node.rln.isNil():
    return err("rlnGenerateProof: RLN not mounted")

  return await self.node.rln.generateRLNProof(signal, timestamp.float64)

proc rlnValidateProof*(
    self: Waku,
    scope: MembershipScope,
    signal: seq[byte],
    timestamp: uint64,
    proof: seq[byte],
): Future[Result[ValidationResult, string]] {.async.} =
  ## Validates a wire-encoded rate-limit proof over `signal` and returns the
  ## verdict. `proof.epoch` must equal the epoch derived from `timestamp`
  ## (Unix seconds). Duplicate and rate-limit-violation detection stays in
  ## the relay validator (`validateMessageAndUpdateLog`), so this reports
  ## `Valid`/`Invalid` only.
  if self.node.rln.isNil():
    return err("rlnValidateProof: RLN not mounted")

  let decoded = protocol_types.RateLimitProof.init(proof).valueOr:
    return ok(ValidationResult(verdict: ProofVerdict.Invalid))

  if decoded.epoch != self.node.rln.calcEpoch(timestamp.float64):
    return ok(ValidationResult(verdict: ProofVerdict.Invalid))

  if not await self.node.rln.groupManager.validateRoot(decoded.merkleRoot):
    return ok(ValidationResult(verdict: ProofVerdict.Invalid))

  let valid = self.node.rln.groupManager.verifyProof(signal, decoded).valueOr:
    return err("rlnValidateProof: proof validation failed: " & $error)

  let verdict = if valid: ProofVerdict.Valid else: ProofVerdict.Invalid
  return ok(ValidationResult(verdict: verdict))

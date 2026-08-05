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
    self: Waku, scope: MembershipScope
): Future[Result[EpochQuota, string]] {.async.} =
  ## Snapshot of the current epoch budget. The mounted implementation has a
  ## single implicit membership, so `scope` does not select one yet.
  if self.node.rln.isNil():
    return err("rlnEpochQuota: RLN not mounted")

  let rlnPeer = self.node.rln
  let limit = rlnPeer.groupManager.userMessageLimit.valueOr:
    return err("rlnEpochQuota: user message limit is not set")

  let rateLimit = uint64(limit)
  let nm = rlnPeer.nonceManager
  let spent =
    if getTime().toUnixFloat() - nm.lastNonceTime >= nm.epoch:
      0'u64
    else:
      min(nm.nextNonce, rateLimit)

  return ok(
    EpochQuota(
      epochIndex: fromEpoch(rlnPeer.getCurrentEpoch()),
      rateLimit: rateLimit,
      remaining: rateLimit - spent,
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

proc rlnVerifyProof*(
    self: Waku, scope: MembershipScope, signal: seq[byte], proof: seq[byte]
): Future[Result[VerificationResult, string]] {.async.} =
  ## Verifies a wire-encoded rate-limit proof over `signal` and returns the
  ## verdict. Duplicate and rate-limit-violation detection stays in the relay
  ## validator (`validateMessageAndUpdateLog`), so this reports
  ## `Valid`/`Invalid` only.
  if self.node.rln.isNil():
    return err("rlnVerifyProof: RLN not mounted")

  let decoded = protocol_types.RateLimitProof.init(proof).valueOr:
    return ok(VerificationResult(verdict: ProofVerdict.Invalid))

  if not await self.node.rln.groupManager.validateRoot(decoded.merkleRoot):
    return ok(VerificationResult(verdict: ProofVerdict.Invalid))

  let valid = self.node.rln.groupManager.verifyProof(signal, decoded).valueOr:
    return err("rlnVerifyProof: proof verification failed: " & $error)

  let verdict = if valid: ProofVerdict.Valid else: ProofVerdict.Invalid
  return ok(VerificationResult(verdict: verdict))

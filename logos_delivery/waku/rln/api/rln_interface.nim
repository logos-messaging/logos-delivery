{.push raises: [].}

import chronos

import ./types

export chronos, types

## Client-facing surface of the RLN Module API (logos-lips
## `docs/anoncomms/raw/rln-api.md`): the subset of the module this node calls.
## Registry providers, credential generation and storage, proof crypto, the
## Merkle/root machinery and the nullifier log all live behind this boundary.
##
## Contract every implementation is held to:
## - failures are reported through the `Result`; the returned Future MUST NOT
##   fail except with `CancelledError` (enforced by the `Raising` future type)
## - any call made before the implementation can serve fails with `NotReady`
##   (there is no separate readiness probe)
## - an unsupported optional extension fails with `Permanent`
## - the implementation owns epoch selection and message-id allocation in
##   `generateProof`, and the double-signalling verdict in `verifyProof`

type RlnInterface* {.requiresInit.} = object
  ## Table of the six required functions. Constructed only by factories/
  ## implementations, which fill every field — a zero-initialized instance
  ## holds nil closures and must never exist.
  start*: proc(): Future[RlnApiResult[void]].Raising([CancelledError]) {.gcsafe.}
  stop*: proc(): Future[RlnApiResult[void]].Raising([CancelledError]) {.gcsafe.}
  register*: proc(
    scope: MembershipScope, options: RegistryOptions
  ): Future[RlnApiResult[MembershipState]].Raising([CancelledError]) {.gcsafe.}
    ## Generates the identity credential inside the implementation and submits
    ## the membership. Idempotent per scope while the membership is
    ## `Pending`/`Active`/`GracePeriod`; returns `Pending` on submission —
    ## confirmation is observed via `getMembershipState`.
  getMembershipState*: proc(
    scope: MembershipScope
  ): Future[RlnApiResult[MembershipState]].Raising([CancelledError]) {.gcsafe.}
  getEpochQuota*: proc(
    scope: MembershipScope
  ): Future[RlnApiResult[EpochQuota]].Raising([CancelledError]) {.gcsafe.}
  generateProof*: proc(
    scope: MembershipScope, signal: seq[byte], timestamp: uint64
  ): Future[RlnApiResult[RateLimitProof]].Raising([CancelledError]) {.gcsafe.}
    ## The implementation derives the epoch from `timestamp` (Unix seconds)
    ## and allocates the message id; a spent epoch budget fails with
    ## `BudgetExhausted`.
  verifyProof*: proc(
    scope: MembershipScope, signal: seq[byte], proof: RateLimitProof
  ): Future[RlnApiResult[VerificationResult]].Raising([CancelledError]) {.gcsafe.}
    ## Returns a verdict, including `Duplicate` and `RateLimitViolation`;
    ## an invalid proof is a verdict, not an error.

{.pop.}

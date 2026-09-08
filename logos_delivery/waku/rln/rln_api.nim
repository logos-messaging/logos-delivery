{.push raises: [].}

import chronos

import ./rln_lez/types

export chronos, types

## Client-facing surface of the RLN Module API. All types carried here
## (`RlnError`, `MembershipScope`, `MembershipState`, …) are the spec's own
## vocabulary — logos-lips `docs/anoncomms/raw/rln-api.md` — mirrored in
## `./rln_lez/types`, not defined by this repo.
##
## Implementation contract:
## - calls made before the implementation can serve fail with `NotReady`;
##   unsupported optional extensions fail with `Permanent`
## - only `validateProof` writes the nullifier log
## - `registerMembership` is idempotent while the scope's membership is
##   `Pending`/`Active`/`GracePeriod` and returns `Pending` on submission —
##   confirmation is observed via `getMembershipState`

type RlnInterface* = concept m
  start(m, config = string) is Future[Result[void, RlnError]]
  stop(m) is Future[Result[void, RlnError]]
  registerMembership(m, scope = MembershipScope, options = RegistryOptions) is
    Future[Result[MembershipState, RlnError]]
  getMembershipState(m, scope = MembershipScope) is
    Future[Result[MembershipState, RlnError]]
  getEpochQuota(m, scope = MembershipScope, timestamp = uint64) is
    Future[Result[EpochQuota, RlnError]]
  generateProof(m, scope = MembershipScope, signal = seq[byte], timestamp = uint64) is
    Future[Result[RateLimitProof, RlnError]]
  validateProof(
    m,
    scope = MembershipScope,
    signal = seq[byte],
    timestamp = uint64,
    proof = RateLimitProof,
  ) is Future[Result[ValidationResult, RlnError]]

{.pop.}

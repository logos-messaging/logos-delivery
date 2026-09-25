{.push raises: [].}

import chronos

import ./types

export chronos, types

## Client-facing surface of the RLN Module API.
##
## The surface is implementation-agnostic: no membership, registry or epoch
## size appears in it. Starting, configuring and registering the backend belong
## to whoever installs it.
##
## Implementation contract:
## - calls made before the implementation can serve fail with `NotReady`;
##   unsupported optional extensions fail with `Permanent`
## - only `validateProof` writes the nullifier log

type RlnInterface* = concept m
  getMembershipState(m) is Future[Result[MembershipState, RlnError]]
  getEpochQuota(m, timestamp = uint64) is Future[Result[EpochQuota, RlnError]]
  generateProof(m, signal = seq[byte], timestamp = uint64) is
    Future[Result[RateLimitProof, RlnError]]
  validateProof(m, signal = seq[byte], timestamp = uint64, proof = RateLimitProof) is
    Future[Result[ValidationResult, RlnError]]

{.pop.}

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
##   fail except with `CancelledError` — implementations use
##   `{.async: (raises: [CancelledError]).}`
## - any call made before the implementation can serve fails with `NotReady`
##   (there is no separate readiness probe)
## - an unsupported optional extension fails with `Permanent`
## - the epoch is derived from the consumer-supplied `timestamp` (Unix
##   seconds, `epoch_index = timestamp / epoch_size`); the implementation
##   owns message-id allocation in `generateProof` and the double-signalling
##   verdict in `validateProof`; `proof.epoch` must equal the epoch derived
##   from `timestamp`
## - only `validateProof` writes the nullifier log
## - `register` generates the identity credential internally and is
##   idempotent for the scope's registry while its membership is
##   `Pending`/`Active`/`GracePeriod`; it returns `Pending` on submission —
##   confirmation is observed via `getMembershipState`

type RlnInterface* = concept m
  start(m) is Future[RlnApiResult[void]]
  stop(m) is Future[RlnApiResult[void]]
  register(m, scope = MembershipScope, options = RegistryOptions) is
    Future[RlnApiResult[MembershipState]]
  getMembershipState(m, scope = MembershipScope) is Future[
    RlnApiResult[MembershipState]
  ]
  getEpochQuota(m, scope = MembershipScope, timestamp = uint64) is
    Future[RlnApiResult[EpochQuota]]
  generateProof(m, scope = MembershipScope, signal = seq[byte], timestamp = uint64) is
    Future[RlnApiResult[RateLimitProof]]
  validateProof(
    m,
    scope = MembershipScope,
    signal = seq[byte],
    timestamp = uint64,
    proof = RateLimitProof,
  ) is Future[RlnApiResult[ValidationResult]]

{.pop.}

## Epoch budget source for the rate limit manager.
##
## The budget is the RLN Module API's `EpochQuota` snapshot, so the epoch and
## the remaining budget cannot straddle an epoch boundary. The provider is a
## callback, keeping the manager free of any `Waku` dependency.

import std/times
import results, chronos
import logos_delivery/waku/rln/rln_api

export rln_api

type QuotaProvider* =
  proc(): Future[Opt[EpochQuota]] {.async: (raises: [CancelledError]), gcsafe.}
  ## `none` when RLN is not mounted — the signal to fall back to local
  ## counting over the wall clock.
  ## A cancel of the read is raised. It is not a missing quota.

proc wallClockEpochIndex*(epochPeriodSec: uint64): uint64 =
  ## Absolute epoch (`unixTime div epochPeriodSec`), the same derivation RLN
  ## uses, so independent nodes agree on the boundary.
  return uint64(getTime().toUnix()) div epochPeriodSec

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
  proc(timestamp: uint64): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.}
  ## The budget of the epoch of `timestamp` (Unix seconds).
  ## `none` when RLN is not mounted, or when the read failed.

type EpochSizeProvider* = proc(): Opt[uint64] {.gcsafe, raises: [].}
  ## The length of an RLN epoch in seconds, when the RLN backend states one.
  ## The epoch index of such a backend is `unixTime div` that length.

type Clock* = proc(): uint64 {.gcsafe, raises: [].} ## The time now, in Unix seconds.

proc wallClock*(): uint64 =
  return uint64(getTime().toUnix())

proc wallClockEpochIndex*(now, epochPeriodSec: uint64): uint64 =
  ## Absolute epoch (`unixTime div epochPeriodSec`), the same derivation RLN
  ## uses, so independent nodes agree on the boundary.
  return now div epochPeriodSec

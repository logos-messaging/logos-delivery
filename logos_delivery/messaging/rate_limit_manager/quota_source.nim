## Epoch + user-message-limit source for the rate limit manager.
##
## Both values are read through one provider call, so a read cannot pair a
## fresh epoch with a stale limit. The provider is a callback, keeping the
## manager free of any `Waku` dependency.

import std/times
import results

type
  EpochQuota* = object
    epochIndex*: uint64 ## Current epoch (`timestamp div` epoch length).
    userMessageLimit*: uint64 ## Messages the epoch grants.

  QuotaProvider* = proc(): Opt[EpochQuota] {.gcsafe, raises: [].}
    ## `none` when RLN is not mounted — the signal to fall back to the
    ## wall clock.

proc wallClockEpochIndex*(epochPeriodSec: uint64): uint64 =
  ## Absolute epoch (`unixTime div epochPeriodSec`), the same derivation RLN
  ## uses, so independent nodes agree on the boundary.
  return uint64(getTime().toUnix()) div epochPeriodSec

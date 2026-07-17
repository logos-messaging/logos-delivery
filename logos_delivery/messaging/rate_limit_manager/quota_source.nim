## Epoch + user-message-limit source for the rate limit manager.
##
## "Quota" is the tracking issues' word (#3838: "we should know our remaining
## quota") for what RLN expresses as an epoch's user message limit: each epoch
## grants `userMessageLimit` message ids (nonces), and the epoch rolling over
## refills the allowance.
##
## The manager rate-limits per epoch, but must not know *where* the epoch and
## the limit come from. With RLN mounted both are RLN's; without it, a
## wall-clock window and the configured limit stand in. Epoch and limit are
## read together, through one provider, so a read cannot straddle an epoch
## boundary and pair a fresh epoch with a stale limit. The provider is a
## callback so the manager stays free of any dependency on the `Waku` kernel —
## the RLN-backed provider is built one layer up, where the kernel handle is in
## scope. It returns `none` when RLN is not mounted, which is the signal to
## fall back to the wall clock.

import std/[options, times]

type
  EpochQuota* = object
    epochIndex*: uint64
      ## Current epoch as its numeric value (`timestamp div` the epoch length);
      ## the kernel's `Epoch` type is the same value serialized to 32 bytes.
    userMessageLimit*: uint64
      ## Message ids the epoch grants — the hard ceiling on admissions before
      ## the epoch rolls over.

  QuotaProvider* = proc(): Option[EpochQuota] {.gcsafe, raises: [].}
    ## The epoch and its user message limit, or `none` when RLN is not mounted.

proc wallClockEpochIndex*(epochPeriodSec: uint64): uint64 =
  ## Absolute wall-clock epoch: `unixTime div epochPeriodSec`. Absolute (not a
  ## sliding window anchored at first use) so it matches RLN's `calcEpoch`, and
  ## so two managers started at different moments agree on the boundary.
  ## `epochPeriodSec` is assumed positive; the manager only calls this when
  ## enforcing.
  uint64(getTime().toUnix()) div epochPeriodSec

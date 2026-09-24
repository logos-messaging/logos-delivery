## Configuration for the messaging rate limit manager.
##
## Kept separate from `rate_limit_manager` so `messaging_conf` can depend on
## `RateLimitConfig` without pulling in the manager itself.

type
  RateLimitError* {.pure.} = enum
    OverBudget

  RateLimitConfig* = object
    enabled*: bool
    epochPeriodSec*: uint64
      ## Epoch length in seconds. Shapes only the wall-clock fallback window;
      ## ignored once the RLN quota source supplies the period.
    messagesPerEpoch*: uint64
      ## Local cap on messages admitted per epoch. When RLN is mounted, RLN's
      ## remaining budget also gates admission, so the cap can only tighten it.
    approachedThresholdPercent*: uint64
      ## Share of the epoch's limit (0..100) that, once spent, reports the quota
      ## as approached. 0 selects `DefaultApproachedThresholdPercent`; 100 never
      ## reports approached, only exhausted.

const
  DefaultEpochPeriodSec* = 600'u64
  DefaultMessagesPerEpoch* = 1'u64
  DefaultApproachedThresholdPercent* = 80'u64

  DefaultRateLimitConfig* = RateLimitConfig(
    epochPeriodSec: DefaultEpochPeriodSec,
    messagesPerEpoch: DefaultMessagesPerEpoch,
    approachedThresholdPercent: DefaultApproachedThresholdPercent,
  ) ## Used when no rate-limit config is supplied; `enabled` defaults false.

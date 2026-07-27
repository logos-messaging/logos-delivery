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
      ## Local cap on messages admitted per epoch. When RLN is mounted the cap
      ## is clamped to RLN's limit

const
  DefaultEpochPeriodSec* = 600'u64
  DefaultMessagesPerEpoch* = 1'u64

  DefaultRateLimitConfig* = RateLimitConfig(
    epochPeriodSec: DefaultEpochPeriodSec, messagesPerEpoch: DefaultMessagesPerEpoch
  ) ## Used when no rate-limit config is supplied; `enabled` defaults false.

func isEnforcing*(config: RateLimitConfig): bool =
  ## Whether the config asks for actual rate limiting; a disabled or zeroed
  ## config admits everything.
  return config.enabled and config.epochPeriodSec > 0 and config.messagesPerEpoch > 0

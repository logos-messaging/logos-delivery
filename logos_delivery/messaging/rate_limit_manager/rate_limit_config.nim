## Configuration for the messaging rate limit manager.
##
## Field names follow the RELIABLE-CHANNEL-API spec's `RateLimitConfig`
## (`enabled`, `epochPeriodSec`): this is a messaging-API config object, so it
## uses the API spec's vocabulary rather than RLN's internal `RlnConf` names.
## `messagesPerEpoch` is the local cap; the spec leaves the actual limit to RLN,
## which the manager honours by clamping the cap to RLN's user message limit.
##
## Kept separate from the enforcement engine so the API config layer can depend
## on the vocabulary (`RateLimitConfig`) without pulling in the manager and its
## RLN quota seam.

type
  RateLimitError* {.pure.} = enum
    OverBudget

  RateLimitConfig* = object
    enabled*: bool ## spec: rate limiting opt-in; SHOULD be true when RLN active
    epochPeriodSec*: uint64
      ## Epoch length, in seconds (spec: the epoch size used by the RLN relay).
      ## Only shapes the wall-clock fallback window; when the RLN quota source is
      ## wired in it is ignored (the period is RLN's).
    messagesPerEpoch*: uint64
      ## Local cap on messages admitted per epoch. When RLN is mounted the
      ## effective limit is clamped to RLN's user message limit; config can only
      ## tighten it, never widen it.

const
  DefaultEpochPeriodSec* = 600'u64
  DefaultMessagesPerEpoch* = 1'u64

  DefaultRateLimitConfig* = RateLimitConfig(
    epochPeriodSec: DefaultEpochPeriodSec, messagesPerEpoch: DefaultMessagesPerEpoch
  ) ## Used when no rate-limit config is supplied; `enabled` defaults false.

func isEnforcing*(config: RateLimitConfig): bool =
  ## Whether the config asks for actual rate limiting. A disabled or zeroed
  ## configuration admits everything, so the manager can short-circuit.
  config.enabled and config.epochPeriodSec > 0 and config.messagesPerEpoch > 0

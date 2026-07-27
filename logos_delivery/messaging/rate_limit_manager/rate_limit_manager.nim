## Rate Limit Manager for the Messaging API.
##
## Rate-limits message transmissions against the per-epoch user message limit,
## rejecting admission once the epoch's budget is spent. The epoch rolling
## over refills the budget.
##
## The epoch and limit come from a `QuotaProvider` when RLN is mounted;
## otherwise a wall-clock window and the configured limit stand in. Parking and
## retrying over-budget messages is the send service's job — this module only
## answers whether one more transmission fits the current epoch.

import results, chronos

import ./rate_limit_config, ./quota_source

export rate_limit_config, quota_source

type RateLimitManager* = ref object
  config*: RateLimitConfig
  quotaProvider: QuotaProvider
    ## Nil or a `none` result selects the wall-clock fallback. Queried per
    ## admission so a late RLN mount upgrades automatically.
  currentEpochIndex*: uint64
  sentInCurrentEpoch*: uint64

proc new*(
    T: type RateLimitManager,
    config: RateLimitConfig,
    quotaProvider: QuotaProvider = nil,
): Result[T, string] =
  ## Rejects an enabled config with a zero epoch period: the wall-clock
  ## fallback derives the epoch as `unixTime div epochPeriodSec`.
  if config.enabled and config.epochPeriodSec == 0:
    return err("rate limit config: epochPeriodSec must be positive when enabled")

  return ok(
    T(
      config: config,
      quotaProvider: quotaProvider,
      currentEpochIndex: 0,
      sentInCurrentEpoch: 0,
    )
  )

proc currentQuota(self: RateLimitManager): Opt[EpochQuota] =
  if self.quotaProvider.isNil():
    return Opt.none(EpochQuota)
  return self.quotaProvider()

proc admit*(
    self: RateLimitManager, msg: seq[byte]
): Future[Result[void, RateLimitError]] {.async: (raises: []).} =
  ## Charges one message against the current epoch's limit, rolling the window
  ## first when the epoch has advanced. A disabled config admits everything.
  if not self.config.enabled:
    return ok()

  let quota = self.currentQuota()

  let epochIndex =
    if quota.isSome():
      quota.get().epochIndex
    else:
      wallClockEpochIndex(self.config.epochPeriodSec)

  # RLN can only tighten the configured cap, never widen it: exceeding RLN's
  # limit would fail later at proof generation.
  var limit = self.config.messagesPerEpoch
  if quota.isSome() and quota.get().userMessageLimit < limit:
    limit = quota.get().userMessageLimit

  if epochIndex != self.currentEpochIndex:
    self.currentEpochIndex = epochIndex
    self.sentInCurrentEpoch = 0

  if self.sentInCurrentEpoch >= limit:
    return err(RateLimitError.OverBudget)

  self.sentInCurrentEpoch.inc()
  return ok()

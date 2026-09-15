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

type EffectiveQuota = object ## The window and cap one admission is judged against.
  epochIndex: uint64
  epochPeriodSec: uint64 ## Zero when no period is known; the window never rolls.
  limit: uint64

proc effectiveQuota(self: RateLimitManager): EffectiveQuota =
  ## Resolves the quota source against the configured caps. Read in one place so
  ## an admission and the boundary reported alongside it cannot disagree.
  let quota = self.currentQuota()

  if quota.isSome():
    let q = quota.get()
    # RLN can only tighten the configured cap, never widen it: exceeding RLN's
    # limit would fail later at proof generation.
    return EffectiveQuota(
      epochIndex: q.epochIndex,
      epochPeriodSec:
        if q.epochPeriodSec > 0: q.epochPeriodSec else: self.config.epochPeriodSec,
      limit: min(q.userMessageLimit, self.config.messagesPerEpoch),
    )

  if self.config.epochPeriodSec == 0:
    return EffectiveQuota(
      epochIndex: 0, epochPeriodSec: 0, limit: self.config.messagesPerEpoch
    )

  return EffectiveQuota(
    epochIndex: wallClockEpochIndex(self.config.epochPeriodSec),
    epochPeriodSec: self.config.epochPeriodSec,
    limit: self.config.messagesPerEpoch,
  )

proc admit*(
    self: RateLimitManager, msg: seq[byte]
): Future[Result[void, RateLimitError]] {.async: (raises: []).} =
  ## Charges one message against the current epoch's limit, rolling the window
  ## first when the epoch has advanced. A disabled config admits everything.
  if not self.config.enabled:
    return ok()

  let quota = self.effectiveQuota()

  if quota.epochIndex != self.currentEpochIndex:
    self.currentEpochIndex = quota.epochIndex
    self.sentInCurrentEpoch = 0

  if self.sentInCurrentEpoch >= quota.limit:
    return err(RateLimitError.OverBudget)

  self.sentInCurrentEpoch.inc()
  return ok()

proc nextEpochStartUnixSec*(self: RateLimitManager): uint64 =
  ## Unix second the current epoch's budget refills at — the earliest an
  ## over-budget task can be admitted. Zero when no epoch period is known, so
  ## callers must treat it as "unknown" rather than as a time.
  ##
  ## Resolution is one boundary, not one message: a task released at the roll
  ## still queues behind any earlier-parked task competing for the same budget.
  if not self.config.enabled:
    return 0

  let quota = self.effectiveQuota()
  if quota.epochPeriodSec == 0:
    return 0

  return epochStartUnixSec(quota.epochIndex + 1, quota.epochPeriodSec)

## Rate Limit Manager for the Messaging API.
##
## Rate-limits message transmissions against the per-epoch budget, rejecting
## admission once the epoch's budget is spent. The epoch rolling over refills
## the budget.
##
## When RLN is mounted, the epoch and the remaining budget come from the RLN
## Module's `EpochQuota` via a `QuotaProvider`; otherwise a wall-clock window
## and locally counted admissions against the configured cap stand in. Parking and
## retrying over-budget messages is the send service's job — this module only
## answers whether one more transmission fits the current epoch, and how close
## the epoch is to running out (`quotaState`).

import results, chronos

import ./rate_limit_config, ./quota_source

export rate_limit_config, quota_source

type QuotaState* {.pure.} = enum
  Normal ## Below the approached threshold.
  Approached ## At or past the threshold, with budget left.
  Exhausted ## No budget left this epoch.

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
  ## Rejects an enabled config with a zero epoch period (the wall-clock
  ## fallback derives the epoch as `unixTime div epochPeriodSec`) or with an
  ## approached threshold above 100%.
  if config.enabled and config.epochPeriodSec == 0:
    return err("rate limit config: epochPeriodSec must be positive when enabled")
  if config.enabled and config.approachedThresholdPercent > 100:
    return err("rate limit config: approachedThresholdPercent must be at most 100")

  return ok(
    T(
      config: config,
      quotaProvider: quotaProvider,
      currentEpochIndex: 0,
      sentInCurrentEpoch: 0,
    )
  )

proc currentQuota(
    self: RateLimitManager
): Future[Opt[EpochQuota]] {.async: (raises: []).} =
  if self.quotaProvider.isNil():
    return Opt.none(EpochQuota)
  return await self.quotaProvider()

proc refreshEpoch(
    self: RateLimitManager
): Future[(uint64, Opt[EpochQuota])] {.async: (raises: []).} =
  ## Rolls the window when the epoch has advanced and returns the epoch's limit
  ## together with RLN's budget snapshot, if any.
  let quota = await self.currentQuota()

  let epochIndex =
    if quota.isSome():
      quota.get().epochIndex
    else:
      wallClockEpochIndex(self.config.epochPeriodSec)

  if epochIndex != self.currentEpochIndex:
    self.currentEpochIndex = epochIndex
    self.sentInCurrentEpoch = 0

  # RLN's remaining budget is authoritative: it also sees message ids spent
  # outside this manager. The local count still covers admissions whose proof
  # has not drawn a message id yet, so it is capped by RLN's rate limit too.
  var limit = self.config.messagesPerEpoch
  if quota.isSome():
    limit = min(limit, quota.get().rateLimit)

  return (limit, quota)

proc approachedAt(self: RateLimitManager, limit: uint64): uint64 =
  ## Sent count at which the quota is approached: ceil(limit * percent / 100),
  ## split so large RLN limits cannot overflow.
  let percent =
    if self.config.approachedThresholdPercent == 0:
      DefaultApproachedThresholdPercent
    else:
      self.config.approachedThresholdPercent
  return (limit div 100) * percent + ((limit mod 100) * percent + 99) div 100

proc stateOf(self: RateLimitManager, used, limit: uint64): QuotaState =
  if used >= limit:
    return QuotaState.Exhausted
  if used >= self.approachedAt(limit):
    return QuotaState.Approached
  return QuotaState.Normal

proc quotaState*(self: RateLimitManager): Future[QuotaState] {.async: (raises: []).} =
  ## Where the current epoch's budget stands: the tighter of the local count
  ## against the local cap and RLN's consumption against RLN's own limit. A
  ## disabled config is always `Normal`.
  if not self.config.enabled:
    return QuotaState.Normal

  let (limit, quota) = await self.refreshEpoch()
  var state = self.stateOf(self.sentInCurrentEpoch, limit)
  if quota.isSome():
    let q = quota.get()
    let rlnUsed = q.rateLimit - min(q.remaining, q.rateLimit)
    state = max(state, self.stateOf(rlnUsed, q.rateLimit))
  return state

proc admit*(
    self: RateLimitManager, msg: seq[byte]
): Future[Result[void, RateLimitError]] {.async: (raises: []).} =
  ## Charges one message against the current epoch's limit, rolling the window
  ## first when the epoch has advanced. A disabled config admits everything.
  if not self.config.enabled:
    return ok()

  let (limit, quota) = await self.refreshEpoch()
  if self.sentInCurrentEpoch >= limit or (quota.isSome() and quota.get().remaining == 0):
    return err(RateLimitError.OverBudget)

  self.sentInCurrentEpoch.inc()
  return ok()

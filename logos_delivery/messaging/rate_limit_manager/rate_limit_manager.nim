## Rate Limit Manager for the Messaging API.
##
## Rate-limits message transmissions against the per-epoch budget, rejecting
## admission once the epoch's budget is spent. The epoch rolling over refills
## the budget.
##
## `admit` and `quotaState` do not suspend, so `send` can refuse a message at once.
## They read the last budget that `refresh` got from the RLN Module's `EpochQuota`.
## Without RLN, a wall-clock window and the configured cap stand in.
## The manager limits sends whenever RLN gives a budget, also with a disabled config.

import results, chronos

import ./rate_limit_config, ./quota_source

export rate_limit_config, quota_source

const UnknownEpochRetryAfter* = chronos.seconds(1)
  ## `retryAfter` while the manager does not have the end of the RLN epoch.

type QuotaState* {.pure.} = enum
  Normal ## Below the approached threshold.
  Approached ## At or past the threshold, with budget left.
  Exhausted ## No budget left this epoch.

type RlnBudget = object ## The RLN budget of one epoch, as `refresh` last read it.
  epochIndex: uint64
  rateLimit: uint64
  spent: uint64 ## The message ids that RLN drew, also outside this manager.
  baseline: uint64
    ## The ids that RLN drew before the admissions in `sentInCurrentEpoch`.
    ## A restart in the epoch gives such ids.
  endTime: Opt[uint64]
    ## The first second of the next epoch.
    ## None when the RLN backend does not state its epoch length.
    ## The budget then refills when `refresh` reads the new epoch.
  indexKnown: bool
    ## False after `admit` saw the epoch end and before `refresh` read the new epoch.
    ## `epochIndex` is then the index of the ended epoch.

type RateLimitManager* = ref object
  config*: RateLimitConfig
  quotaProvider: QuotaProvider
    ## Nil or a `none` result selects the wall-clock fallback.
    ## `refresh` asks it again, so a late RLN mount upgrades automatically.
  epochSizeProvider: EpochSizeProvider ## Nil when no RLN backend states an epoch length.
  clock: Clock
  rln: Opt[RlnBudget]
  rollTime: uint64
    ## When `admit` last saw an RLN epoch end.
    ## `refresh` drops an answer that it asked for before this time.
  refreshHandle: Future[void].Raising([])
  currentEpochIndex*: uint64
  sentInCurrentEpoch*: uint64
  epochSerial: uint64
    ## Goes up each time `sentInCurrentEpoch` starts again.
    ## `release` gives back only a charge of the current count.

proc new*(
    T: type RateLimitManager,
    config: RateLimitConfig,
    quotaProvider: QuotaProvider = nil,
    clock: Clock = wallClock,
    epochSizeProvider: EpochSizeProvider = nil,
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
      epochSizeProvider: epochSizeProvider,
      clock: clock,
      currentEpochIndex: 0,
      sentInCurrentEpoch: 0,
    )
  )

proc startEpochCount(self: RateLimitManager) =
  self.sentInCurrentEpoch = 0
  self.epochSerial.inc()

proc applyQuota(self: RateLimitManager, quota: EpochQuota) =
  ## The admissions of the epoch stay counted, because a proof can come later.
  var budget = RlnBudget(
    epochIndex: quota.epochIndex,
    rateLimit: quota.rateLimit,
    spent: quota.rateLimit - min(quota.remaining, quota.rateLimit),
    indexKnown: true,
  )
  if not self.epochSizeProvider.isNil():
    let epochSizeSec = self.epochSizeProvider().get(0)
    if epochSizeSec > 0:
      budget.endTime = Opt.some((quota.epochIndex + 1) * epochSizeSec)
  if self.rln.isSome():
    let last = self.rln.get()
    if last.indexKnown and last.epochIndex == quota.epochIndex:
      budget.baseline = last.baseline
    elif last.indexKnown:
      self.startEpochCount()
      budget.baseline = budget.spent
    # Else `admit` started this epoch, and `sentInCurrentEpoch` counts each id of it.
  else:
    self.startEpochCount()
    budget.baseline = budget.spent
  self.currentEpochIndex = quota.epochIndex
  self.rln = Opt.some(budget)

proc refresh*(self: RateLimitManager) {.async: (raises: []).} =
  if self.quotaProvider.isNil():
    return
  let askedAt = self.clock()
  let quota = (await self.quotaProvider(askedAt)).valueOr:
    # A read can fail, so the manager keeps the last budget.
    return
  if quota.rateLimit == 0:
    # No usable membership.
    # The proof attach reports it.
    self.rln = Opt.none(RlnBudget)
    return
  if askedAt < self.rollTime:
    return
  self.applyQuota(quota)

proc requestRefresh(self: RateLimitManager) =
  if self.quotaProvider.isNil():
    return
  if not self.refreshHandle.isNil() and not self.refreshHandle.finished():
    return
  self.refreshHandle = self.refresh()

proc start*(self: RateLimitManager) =
  ## Reads the RLN budget, so `admit` counts the message ids from before a restart.
  self.requestRefresh()

proc stop*(self: RateLimitManager) {.async: (raises: []).} =
  if not self.refreshHandle.isNil():
    await self.refreshHandle
  self.refreshHandle = nil

proc rollEpoch(self: RateLimitManager) =
  let now = self.clock()
  if self.rln.isSome():
    let budget = self.rln.get()
    if budget.endTime.isSome() and now >= budget.endTime.get():
      self.rln =
        Opt.some(RlnBudget(epochIndex: budget.epochIndex, rateLimit: budget.rateLimit))
      self.rollTime = now
      self.startEpochCount()
    return
  if not self.config.enabled:
    return
  let epochIndex = wallClockEpochIndex(now, self.config.epochPeriodSec)
  if epochIndex != self.currentEpochIndex:
    self.currentEpochIndex = epochIndex
    self.startEpochCount()

func limited(self: RateLimitManager): bool =
  return self.config.enabled or self.rln.isSome()

func limit(self: RateLimitManager): uint64 =
  # RLN's remaining budget is authoritative: it also sees message ids spent
  # outside this manager. The local count still covers admissions whose proof
  # has not drawn a message id yet, so it is capped by RLN's rate limit too.
  if self.rln.isNone():
    return self.config.messagesPerEpoch
  if not self.config.enabled:
    return self.rln.get().rateLimit
  return min(self.config.messagesPerEpoch, self.rln.get().rateLimit)

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

proc currentState(self: RateLimitManager): QuotaState =
  if not self.limited():
    return QuotaState.Normal

  var state = self.stateOf(self.sentInCurrentEpoch, self.limit())
  if self.rln.isSome():
    # An admission draws its message id later, with its proof.
    # So RLN does not count the admissions that have no proof yet.
    let budget = self.rln.get()
    let used = max(budget.spent, budget.baseline + self.sentInCurrentEpoch)
    state = max(state, self.stateOf(used, budget.rateLimit))
  return state

proc quotaState*(self: RateLimitManager): QuotaState =
  ## Where the current epoch's budget stands: the tighter of the local count
  ## against the local cap and RLN's consumption against RLN's own limit.
  ## `Normal` while the manager does not limit sends.
  ## Each call starts a `refresh` in the background.
  self.rollEpoch()
  self.requestRefresh()
  return self.currentState()

proc admit*(self: RateLimitManager): Result[Opt[uint64], RateLimitError] =
  ## Charges one message against the current epoch's limit, rolling the window
  ## first when the epoch has advanced.
  ## It admits everything while the manager does not limit sends.
  ## Each call starts a `refresh` in the background.
  self.rollEpoch()
  self.requestRefresh()
  if not self.limited():
    return ok(Opt.none(uint64))

  if self.currentState() == QuotaState.Exhausted:
    return err(RateLimitError.OverBudget)

  self.sentInCurrentEpoch.inc()
  return ok(Opt.some(self.epochSerial))

proc release*(self: RateLimitManager, charge: Opt[uint64]) =
  ## Gives back `charge`, the result of an `admit` whose message drew no RLN message id.
  if charge == Opt.some(self.epochSerial) and self.sentInCurrentEpoch > 0:
    self.sentInCurrentEpoch.dec()

proc retryAfter*(self: RateLimitManager): Duration =
  let now = self.clock()
  if self.rln.isSome():
    let endTime = self.rln.get().endTime.valueOr:
      return UnknownEpochRetryAfter
    if endTime <= now:
      return UnknownEpochRetryAfter
    return chronos.seconds(int64(endTime - now))
  if not self.config.enabled:
    return ZeroDuration
  let period = self.config.epochPeriodSec
  return chronos.seconds(int64(period - now mod period))

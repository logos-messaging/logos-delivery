## Rate Limit Manager for the Messaging API.
##
## Rate-limits message transmissions against the per-epoch user message limit
## and rejects admission once it is spent, keeping the node within the quota
## that RLN-enforcing relays check. Each admission mirrors one RLN message id
## (nonce) draw; the epoch rolling over refills the allowance.
##
## The epoch and the limit come from a `QuotaProvider` when RLN is mounted
## (see `quota_source`); otherwise a wall-clock window and the configured limit
## stand in. Parking and retrying over-budget messages is the send service
## scheduler's job — this module only answers whether one more transmission
## fits the current epoch.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import results, chronos

import ./rate_limit_config, ./quota_source

export rate_limit_config, quota_source

type RateLimitManager* = ref object
  config*: RateLimitConfig
  quotaProvider: QuotaProvider
    ## Supplies the RLN epoch + user message limit. Nil, or a call returning
    ## `none`, selects the wall-clock fallback. Queried per admission so a node
    ## whose RLN mounts after construction upgrades automatically.
  currentEpochIndex*: uint64
  sentInCurrentEpoch*: uint64

proc new*(
    T: type RateLimitManager,
    config: RateLimitConfig,
    quotaProvider: QuotaProvider = nil,
): T =
  return T(
    config: config,
    quotaProvider: quotaProvider,
    currentEpochIndex: 0,
    sentInCurrentEpoch: 0,
  )

proc currentQuota(self: RateLimitManager): Opt[EpochQuota] =
  if self.quotaProvider.isNil():
    return Opt.none(EpochQuota)
  return self.quotaProvider()

proc admit*(
    self: RateLimitManager, msg: seq[byte]
): Future[Result[void, RateLimitError]] {.async: (raises: []).} =
  ## Charges one message against the current epoch's user message limit,
  ## rolling the window first when the epoch has advanced. A disabled or zeroed
  ## configuration admits everything.
  if not self.config.isEnforcing():
    return ok()

  let quota = self.currentQuota()

  let epochIndex =
    if quota.isSome():
      quota.get().epochIndex
    else:
      wallClockEpochIndex(self.config.epochPeriodSec)

  # RLN can only tighten the configured cap, never widen it: exceeding RLN's
  # user message limit would fail later at proof generation, once the epoch's
  # message ids are exhausted.
  var limit = self.config.messagesPerEpoch
  if quota.isSome() and quota.get().userMessageLimit < limit:
    limit = quota.get().userMessageLimit

  if epochIndex != self.currentEpochIndex:
    self.currentEpochIndex = epochIndex
    self.sentInCurrentEpoch = 0

  if self.sentInCurrentEpoch >= limit:
    return err(RateLimitError.OverBudget)

  inc self.sentInCurrentEpoch
  return ok()

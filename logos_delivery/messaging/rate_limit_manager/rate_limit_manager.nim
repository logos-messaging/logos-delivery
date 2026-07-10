## Rate Limit Manager for the Messaging API.
##
## Tracks messages sent per RLN epoch and rejects admission when the
## budget is exhausted, ensuring RLN compliance on enforcing relays.
##
## Budgeting is a lazily rolled fixed window: the first admission after
## `epochPeriodSec` has elapsed resets the counter. Parking and retrying
## of over-budget messages is owned by the send service scheduler; this
## module only answers whether one more transmission fits the current
## epoch's budget.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/times
import results, chronos

type
  RateLimitError* {.pure.} = enum
    OverBudget

  RateLimitConfig* = object
    enabled*: bool ## spec: rate limiting opt-in; SHOULD be true when RLN active
    epochPeriodSec*: int
    messagesPerEpoch*: int

  RateLimitManager* = ref object
    config*: RateLimitConfig
    currentEpochStart*: Time
    sentInCurrentEpoch*: int

const
  DefaultEpochPeriodSec* = 600
  DefaultMessagesPerEpoch* = 1

  DefaultRateLimitConfig* = RateLimitConfig(
    epochPeriodSec: DefaultEpochPeriodSec, messagesPerEpoch: DefaultMessagesPerEpoch
  ) ## Used when no rate-limit config is supplied; `enabled` defaults false.

proc new*(T: type RateLimitManager, config: RateLimitConfig): T =
  return T(config: config, currentEpochStart: getTime(), sentInCurrentEpoch: 0)

proc resetEpoch*(self: RateLimitManager) =
  self.currentEpochStart = getTime()
  self.sentInCurrentEpoch = 0

proc admit*(
    self: RateLimitManager, msg: seq[byte]
): Future[Result[void, RateLimitError]] {.async: (raises: []).} =
  ## Charges one message against the current epoch's budget, rolling the
  ## window first when `epochPeriodSec` has elapsed. A disabled or
  ## non-positive configuration admits everything.
  if not self.config.enabled or self.config.epochPeriodSec <= 0 or
      self.config.messagesPerEpoch <= 0:
    return ok()

  if getTime() - self.currentEpochStart >=
      initDuration(seconds = self.config.epochPeriodSec):
    self.resetEpoch()

  if self.sentInCurrentEpoch >= self.config.messagesPerEpoch:
    return err(RateLimitError.OverBudget)

  inc self.sentInCurrentEpoch
  return ok()

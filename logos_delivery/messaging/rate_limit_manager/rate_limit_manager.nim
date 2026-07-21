## Rate Limit Manager for the Messaging API.
##
## Tracks messages sent per RLN epoch and rejects admission when the
## limit is approached, ensuring RLN compliance on enforcing relays.
##
## For the skeleton this is a pass-through: every call is admitted.
## Real per-epoch budgeting will use `queue`, `currentEpochStart`,
## `sentInCurrentEpoch`, and `resetEpoch` to park messages and admit
## them as the epoch rolls over.
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
    queue*: seq[seq[byte]]
    currentEpochStart*: Time
    sentInCurrentEpoch*: int

const
  DefaultEpochPeriodSec* = 600
  DefaultMessagesPerEpoch* = 1

  DefaultRateLimitConfig* = RateLimitConfig(
    epochPeriodSec: DefaultEpochPeriodSec, messagesPerEpoch: DefaultMessagesPerEpoch
  ) ## Used when no rate-limit config is supplied; `enabled` defaults false.

proc new*(T: type RateLimitManager, config: RateLimitConfig): T =
  return
    T(config: config, queue: @[], currentEpochStart: getTime(), sentInCurrentEpoch: 0)

proc admit*(
    self: RateLimitManager, msg: seq[byte]
): Future[Result[void, RateLimitError]] {.async: (raises: []).} =
  ## Skeleton behaviour: admits immediately. Real per-epoch budgeting
  ## will consult `config`, `sentInCurrentEpoch`, and the elapsed
  ## `epochPeriodSec` window before admitting or parking `msg`.
  return ok()

proc dequeueReady*(self: RateLimitManager): seq[seq[byte]] =
  ## Returns the set of queued messages that may be dispatched now
  ## without exceeding the configured rate limit.
  discard

proc resetEpoch*(self: RateLimitManager) =
  self.currentEpochStart = getTime()
  self.sentInCurrentEpoch = 0

## Rate Limit Manager for the Reliable Channel API.
##
## Tracks messages sent per RLN epoch and delays dispatch when the
## limit is approached, ensuring RLN compliance on enforcing relays.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/times
import sds/message

export message

const
  DefaultEpochPeriodSec* = 600
  DefaultMessagesPerEpoch* = 1

type
  RateLimitConfig* = object
    epochPeriodSec*: int
    messagesPerEpoch*: int

  RateLimitManager* = ref object
    config*: RateLimitConfig
    queue*: seq[SdsMessage]
    currentEpochStart*: Time
    sentInCurrentEpoch*: int

proc new*(T: type RateLimitManager, config: RateLimitConfig): T =
  return T(config: config, queue: @[], currentEpochStart: getTime(), sentInCurrentEpoch: 0)

proc enqueue*(mgr: RateLimitManager, msg: SdsMessage) =
  ## Append an SDS message to the pending dispatch queue.
  mgr.queue.add(msg)

proc dequeueReady*(mgr: RateLimitManager): seq[SdsMessage] =
  ## Returns the set of queued messages that may be dispatched now
  ## without exceeding the configured rate limit. Advances epoch
  ## bookkeeping as needed.
  discard

proc resetEpoch*(mgr: RateLimitManager) =
  mgr.currentEpochStart = getTime()
  mgr.sentInCurrentEpoch = 0

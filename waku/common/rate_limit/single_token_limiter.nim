## This module add usage check helpers for simple rate limiting with the use of TokenBucket.

{.push raises: [].}

import std/[options], chronos/timer, libp2p/stream/connection, libp2p/utility

import std/times except TimeInterval, Duration

import chronos/ratelimit as token_bucket

import ./[setting, service_metrics]
export token_bucket, setting, service_metrics

proc newTokenBucket*(
    setting: Option[RateLimitSetting],
    replenishMode: static[ReplenishMode] = ReplenishMode.Continuous,
    startTime: Moment = Moment.now(),
): Option[TokenBucket] =
  if setting.isNone():
    return none[TokenBucket]()

  if setting.get().isUnlimited():
    return none[TokenBucket]()

  return some(
    TokenBucket.new(
      capacity = setting.get().volume,
      fillDuration = setting.get().period,
      startTime = startTime,
      mode = replenishMode,
    )
  )

proc checkUsage(
    t: var TokenBucket, proto: string, now = Moment.now()
): bool {.raises: [].} =
  if not t.tryConsume(1, now):
    return false

  return true

proc checkUsage(
    t: var Option[TokenBucket], proto: string, now = Moment.now()
): bool {.raises: [].} =
  if t.isNone():
    return true

  var tokenBucket = t.get()
  return checkUsage(tokenBucket, proto, now)

template checkUsageLimit*(
    t: var Option[TokenBucket] | var TokenBucket,
    proto: string,
    conn: Connection,
    bodyWithinLimit, bodyRejected: untyped,
) =
  if t.checkUsage(proto):
    let requestStartTime = Moment.now()
    waku_service_requests.inc(labelValues = [proto, "served"])

    bodyWithinLimit

    let requestDuration = Moment.now() - requestStartTime
    waku_service_request_handling_duration_seconds.observe(
      requestDuration.milliseconds.float / 1000, labelValues = [proto]
    )
  else:
    waku_service_requests.inc(labelValues = [proto, "rejected"])
    bodyRejected

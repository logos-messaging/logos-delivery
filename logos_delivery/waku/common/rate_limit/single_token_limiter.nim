## This module add usage check helpers for simple rate limiting with the use of TokenBucket.

{.push raises: [].}

import results, chronos/timer, libp2p/stream/connection, libp2p/utility

import std/times except TimeInterval, Duration

import chronos/ratelimit as token_bucket

import ./[setting, service_metrics]
export token_bucket, setting, service_metrics

proc newTokenBucket*(
    setting: Opt[RateLimitSetting],
    replenishMode: static[ReplenishMode] = ReplenishMode.Continuous,
    startTime: Moment = Moment.now(),
): Opt[TokenBucket] =
  if setting.isNone():
    return Opt.none(TokenBucket)

  if setting.get().isUnlimited():
    return Opt.none(TokenBucket)

  return Opt.some(
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
    t: var Opt[TokenBucket], proto: string, now = Moment.now()
): bool {.raises: [].} =
  if t.isNone():
    return true

  var tokenBucket = t.get()
  return checkUsage(tokenBucket, proto, now)

template checkUsageLimit*(
    t: var Opt[TokenBucket] | var TokenBucket,
    proto: string,
    conn: Connection,
    bodyWithinLimit, bodyRejected: untyped,
) =
  if t.checkUsage(proto):
    let requestStartTime = Moment.now()
    logos_delivery_service_requests.inc(labelValues = [proto, "served"])

    bodyWithinLimit

    let requestDuration = Moment.now() - requestStartTime
    logos_delivery_service_request_handling_duration_seconds.observe(
      requestDuration.milliseconds.float / 1000, labelValues = [proto]
    )
  else:
    logos_delivery_service_requests.inc(labelValues = [proto, "rejected"])
    bodyRejected

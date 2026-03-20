## RequestRateLimiter
##
## RequestRateLimiter is a general service protection mechanism.
## While applies an overall rate limit, it also ensure fair usage among peers.
##
## This is reached by reject peers that are constantly over using the service while allowing others to use it
## within the global limit set.
## Punished peers will also be recovered after a certain time period if not violating the limit.
##
## This is reached by calculating a ratio of the global limit and applying it to each peer.
## This ratio is applied to the allowed tokens within a ratio * the global time period.
## The allowed tokens for peers are limited to 75% of ratio * global token volume.
##
## This needs to be taken into account when setting the global limit for the specific service type and use cases.

{.push raises: [].}

import
  std/[options, math],
  chronicles,
  chronos/timer,
  libp2p/stream/connection,
  libp2p/utility

import std/times except TimeInterval, Duration, seconds, minutes

import ./[single_token_limiter, service_metrics, timed_map]

export token_bucket, setting, service_metrics

logScope:
  topics = "waku ratelimit"

const PER_PEER_ALLOWED_PERCENT_OF_VOLUME = 0.75
const UNLIMITED_RATIO = 0
const UNLIMITED_TIMEOUT = 0.seconds
const MILISECONDS_RATIO = 10
const SECONDS_RATIO = 3
const MINUTES_RATIO = 2

type RequestRateLimiter* = ref object of RootObj
  tokenBucket: TokenBucket
  setting*: Option[RateLimitSetting]
  mainBucketSetting: RateLimitSetting
  ratio: int
  peerBucketSetting*: RateLimitSetting
  peerUsage: TimedMap[PeerId, TokenBucket]
  checkUsageImpl: proc(
    t: var RequestRateLimiter, proto: string, conn: Connection, now: Moment
  ): bool {.gcsafe, raises: [].}

proc newMainTokenBucket(
    setting: RateLimitSetting, ratio: int, startTime: Moment
): TokenBucket =
  ## RequestRateLimiter's global bucket should keep the *rate* of the configured
  ## setting while allowing a larger burst window. We achieve this by scaling
  ## both capacity and fillDuration by the same ratio.
  ##
  ## This matches previous behavior where unused tokens could effectively
  ## accumulate across multiple periods.
  let burstCapacity = setting.volume * ratio
  var bucket = TokenBucket.new(
    capacity = burstCapacity,
    fillDuration = setting.period * ratio,
    startTime = startTime,
    mode = Continuous,
  )

  # Start with the configured volume (not the burst capacity) so that the
  # initial burst behavior matches the raw setting, while still allowing
  # accumulation up to `burstCapacity` over time.
  let excess = burstCapacity - setting.volume
  if excess > 0:
    discard bucket.tryConsume(excess, startTime)

  return bucket

proc mgetOrPut(
    requestRateLimiter: var RequestRateLimiter, peerId: PeerId, now: Moment
): var TokenBucket =
  let bucketForNew = newTokenBucket(
    some(requestRateLimiter.peerBucketSetting), Discrete, now
  ).valueOr:
    raiseAssert "This branch is not allowed to be reached as it will not be called if the setting is None."

  return requestRateLimiter.peerUsage.mgetOrPut(peerId, bucketForNew)

proc checkUsageUnlimited(
    t: var RequestRateLimiter, proto: string, conn: Connection, now: Moment
): bool {.gcsafe, raises: [].} =
  true

proc checkUsageLimited(
    t: var RequestRateLimiter, proto: string, conn: Connection, now: Moment
): bool {.gcsafe, raises: [].} =
  # Lazy-init the main bucket using the first observed request time. This makes
  # refill behavior deterministic under tests where `now` is controlled.
  if isNil(t.tokenBucket):
    t.tokenBucket = newMainTokenBucket(t.mainBucketSetting, t.ratio, now)

  let peerBucket = t.mgetOrPut(conn.peerId, now)
  ## check requesting peer's usage is not over the calculated ratio and let that peer go which not requested much/or this time...
  if not peerBucket.tryConsume(1, now):
    trace "peer usage limit reached", peer = conn.peerId
    return false

  # Ok if the peer can consume, check the overall budget we have left
  if not t.tokenBucket.tryConsume(1, now):
    return false

  return true

proc checkUsage*(
    t: var RequestRateLimiter, proto: string, conn: Connection, now = Moment.now()
): bool {.raises: [].} =
  t.checkUsageImpl(t, proto, conn, now)

template checkUsageLimit*(
    t: var RequestRateLimiter,
    proto: string,
    conn: Connection,
    bodyWithinLimit, bodyRejected: untyped,
) =
  if t.checkUsage(proto, conn):
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

# TODO: review these ratio assumptions! Debatable!
func calcPeriodRatio(settingOpt: Option[RateLimitSetting]): int =
  settingOpt.withValue(setting):
    if setting.isUnlimited():
      return UNLIMITED_RATIO

    if setting.period <= 1.seconds:
      return MILISECONDS_RATIO

    if setting.period <= 1.minutes:
      return SECONDS_RATIO

    return MINUTES_RATIO
  do:
    # when setting is none
    return UNLIMITED_RATIO

# calculates peer cache items timeout
# effectively if a peer does not issue any requests for this amount of time will be forgotten.
func calcCacheTimeout(settingOpt: Option[RateLimitSetting], ratio: int): Duration =
  settingOpt.withValue(setting):
    if setting.isUnlimited():
      return UNLIMITED_TIMEOUT

    # CacheTimout for peers is double the replensih period for peers
    return setting.period * ratio * 2
  do:
    # when setting is none
    return UNLIMITED_TIMEOUT

func calcPeerTokenSetting(
    setting: Option[RateLimitSetting], ratio: int
): RateLimitSetting =
  let s = setting.valueOr:
    return (0, 0.minutes)

  let peerVolume =
    trunc((s.volume * ratio).float * PER_PEER_ALLOWED_PERCENT_OF_VOLUME).int
  let peerPeriod = s.period * ratio

  return (peerVolume, peerPeriod)

proc newRequestRateLimiter*(setting: Option[RateLimitSetting]): RequestRateLimiter =
  let ratio = calcPeriodRatio(setting)
  let isLimited = setting.isSome() and not setting.get().isUnlimited()
  let mainBucketSetting =
    if isLimited:
      setting.get()
    else:
      (0, 0.minutes)

  return RequestRateLimiter(
    tokenBucket: nil,
    setting: setting,
    mainBucketSetting: mainBucketSetting,
    ratio: ratio,
    peerBucketSetting: calcPeerTokenSetting(setting, ratio),
    peerUsage: init(TimedMap[PeerId, TokenBucket], calcCacheTimeout(setting, ratio)),
    checkUsageImpl: (if isLimited: checkUsageLimited else: checkUsageUnlimited),
  )

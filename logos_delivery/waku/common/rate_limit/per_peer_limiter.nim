## PerPeerRateLimiter
##
## With this class one can easily track usage of a service per PeerId
## Rate limit is applied separately by each peer upon first use. Also time period is counted distinct per peer.
## It will use compensating replenish mode for peers to balance the load and allow fair usage of a service.

{.push raises: [].}

import std/[options, tables], libp2p/stream/connection

import ./[single_token_limiter, service_metrics], ../../utils/tableutils

export token_bucket, setting, service_metrics

type PerPeerRateLimiter* = ref object of RootObj
  setting*: Option[RateLimitSetting]
  peerBucket: Table[PeerId, Option[TokenBucket]]

proc mgetOrPut(
    perPeerRateLimiter: var PerPeerRateLimiter, peerId: PeerId
): var Option[TokenBucket] =
  return perPeerRateLimiter.peerBucket.mgetOrPut(
    peerId, newTokenBucket(perPeerRateLimiter.setting, ReplenishMode.Continuous)
  )

template checkUsageLimit*(
    t: var PerPeerRateLimiter,
    proto: string,
    conn: Connection,
    bodyWithinLimit, bodyRejected: untyped,
) =
  checkUsageLimit(t.mgetOrPut(conn.peerId), proto, conn, bodyWithinLimit, bodyRejected)

proc unregister*(perPeerRateLimiter: var PerPeerRateLimiter, peerId: PeerId) =
  perPeerRateLimiter.peerBucket.del(peerId)

proc unregister*(perPeerRateLimiter: var PerPeerRateLimiter, peerIds: seq[PeerId]) =
  perPeerRateLimiter.peerBucket.keepItIf(key notin peerIds)

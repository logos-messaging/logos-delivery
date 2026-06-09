#                Chronos Test Suite
#            (c) Copyright 2022-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.used.}

import testutils/unittests
import chronos, libp2p/stream/connection
import std/options

import ../../logos_delivery/waku/common/rate_limit/request_limiter
import ../../logos_delivery/waku/common/rate_limit/timed_map

let proto = "ProtocolDescriptor"

let conn1 = Connection(peerId: PeerId.random().tryGet())
let conn2 = Connection(peerId: PeerId.random().tryGet())
let conn3 = Connection(peerId: PeerId.random().tryGet())

suite "RequestRateLimiter":
  test "RequestRateLimiter Allow up to main bucket":
    # keep limits low for easier calculation of ratios
    let rateLimit: RateLimitSetting = (4, 2.minutes)
    var limiter = newRequestRateLimiter(some(rateLimit))
    # per peer tokens will be 6 / 4min
    # as ratio is 2 in this case but max tokens are main tokens*ratio . 0.75
    # notice meanwhile we have 8 global tokens over 2 period (4 mins) in sum
    # See: waku/common/rate_limit/request_limiter.nim #func calcPeriodRatio

    let now = Moment.now()
    # with first use we register the peer also and start its timer
    check limiter.checkUsage(proto, conn2, now) == true
    for i in 0 ..< 3:
      check limiter.checkUsage(proto, conn1, now) == true

    check limiter.checkUsage(proto, conn2, now + 3.minutes) == true
    for i in 0 ..< 3:
      check limiter.checkUsage(proto, conn1, now + 3.minutes) == true

    # conn1 reached the 75% of the main bucket over 2 periods of time
    check limiter.checkUsage(proto, conn1, now + 3.minutes) == false

    # conn2 has not used its tokens while we have 1 more tokens left in the main bucket
    check limiter.checkUsage(proto, conn2, now + 3.minutes) == true

  test "RequestRateLimiter Restrict overusing peer":
    # keep limits low for easier calculation of ratios
    let rateLimit: RateLimitSetting = (10, 2.minutes)
    var limiter = newRequestRateLimiter(some(rateLimit))
    # per peer tokens will be 15 / 4min
    # as ratio is 2 in this case but max tokens are main tokens*ratio . 0.75
    # notice meanwhile we have 20 tokens over 2 period (4 mins) in sum
    # See: waku/common/rate_limit/request_limiter.nim #func calcPeriodRatio

    let now = Moment.now()
    # with first use we register the peer also and start its timer
    for i in 0 ..< 10:
      check limiter.checkUsage(proto, conn1, now) == true

    # run out of main tokens but still used one more token from the peer's bucket
    check limiter.checkUsage(proto, conn1, now) == false

    for i in 0 ..< 4:
      check limiter.checkUsage(proto, conn1, now + 3.minutes) == true

    # conn1 reached the 75% of the main bucket over 2 periods of time
    check limiter.checkUsage(proto, conn1, now + 3.minutes) == false

    check limiter.checkUsage(proto, conn2, now + 3.minutes) == true
    check limiter.checkUsage(proto, conn2, now + 3.minutes) == true
    check limiter.checkUsage(proto, conn3, now + 3.minutes) == true
    check limiter.checkUsage(proto, conn2, now + 3.minutes) == true
    check limiter.checkUsage(proto, conn3, now + 3.minutes) == true

    # conn1 gets replenished as the ratio was 2 giving twice as long replenish period than the main bucket
    # see waku/common/rate_limit/request_limiter.nim #func calcPeriodRatio and calcPeerTokenSetting
    check limiter.checkUsage(proto, conn1, now + 4.minutes) == true
    # requests of other peers can also go
    check limiter.checkUsage(proto, conn2, now + 4100.milliseconds) == true
    check limiter.checkUsage(proto, conn3, now + 5.minutes) == true

  test "RequestRateLimiter lowest possible volume":
    # keep limits low for easier calculation of ratios
    let rateLimit: RateLimitSetting = (1, 1.seconds)
    var limiter = newRequestRateLimiter(some(rateLimit))

    let now = Moment.now()
    # with first use we register the peer also and start its timer
    check limiter.checkUsage(proto, conn1, now + 500.milliseconds) == true

    # run out of main tokens but still used one more token from the peer's bucket
    check limiter.checkUsage(proto, conn1, now + 800.milliseconds) == false
    check limiter.checkUsage(proto, conn1, now + 1499.milliseconds) == false
    check limiter.checkUsage(proto, conn1, now + 1501.milliseconds) == true

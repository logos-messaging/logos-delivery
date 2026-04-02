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
import std/[options, tables]

import ../../waku/common/rate_limit/request_limiter
import ../../waku/common/rate_limit/timed_map

let proto = "ProtocolDescriptor"

let conn1 = Connection(peerId: PeerId.random().tryGet())
let conn2 = Connection(peerId: PeerId.random().tryGet())
let conn3 = Connection(peerId: PeerId.random().tryGet())

suite "RateLimitSetting":
  test "Parse rate limit setting - ok":
    let test1 = "10/2m"
    let test2 = "  store : 10  /1h"
    let test2b = "storeV3:        12  /1s"
    let test3 = "LIGHTPUSH: 10/ 1m"
    let test4 = "px:10/2 s "
    let test5 = "filter:42/66ms"

    let expU = UnlimitedRateLimit
    let exp1: RateLimitSetting = (10, 2.minutes)
    let exp2: RateLimitSetting = (10, 1.hours)
    let exp2b: RateLimitSetting = (12, 1.seconds)
    let exp3: RateLimitSetting = (10, 1.minutes)
    let exp4: RateLimitSetting = (10, 2.seconds)
    let exp5: RateLimitSetting = (42, 66.milliseconds)

    let res1 = ProtocolRateLimitSettings.parse(@[test1])
    let res2 = ProtocolRateLimitSettings.parse(@[test2])
    let res2b = ProtocolRateLimitSettings.parse(@[test2b])
    let res3 = ProtocolRateLimitSettings.parse(@[test3])
    let res4 = ProtocolRateLimitSettings.parse(@[test4])
    let res5 = ProtocolRateLimitSettings.parse(@[test5])

    check:
      res1.isOk()
      res1.get() == {GLOBAL: exp1, FILTER: FilterDefaultPerPeerRateLimit}.toTable()
      res2.isOk()
      res2.get() ==
        {GLOBAL: expU, FILTER: FilterDefaultPerPeerRateLimit, STOREV3: exp2}.toTable()
      res2b.isOk()
      res2b.get() ==
        {GLOBAL: expU, FILTER: FilterDefaultPerPeerRateLimit, STOREV3: exp2b}.toTable()
      res3.isOk()
      res3.get() ==
        {GLOBAL: expU, FILTER: FilterDefaultPerPeerRateLimit, LIGHTPUSH: exp3}.toTable()
      res4.isOk()
      res4.get() ==
        {GLOBAL: expU, FILTER: FilterDefaultPerPeerRateLimit, PEEREXCHG: exp4}.toTable()
      res5.isOk()
      res5.get() == {GLOBAL: expU, FILTER: exp5}.toTable()

  test "Parse rate limit setting - err":
    let test1 = "10/2d"
    let test2 = "  stre : 10  /1h"
    let test2b = "storev3:        12 1s"
    let test3 = "somethingelse: 10/ 1m"
    let test4 = ":px:10/2 s "
    let test5 = "filter:p42/66ms"

    let res1 = ProtocolRateLimitSettings.parse(@[test1])
    let res2 = ProtocolRateLimitSettings.parse(@[test2])
    let res2b = ProtocolRateLimitSettings.parse(@[test2b])
    let res3 = ProtocolRateLimitSettings.parse(@[test3])
    let res4 = ProtocolRateLimitSettings.parse(@[test4])
    let res5 = ProtocolRateLimitSettings.parse(@[test5])

    check:
      res1.isErr()
      res2.isErr()
      res2b.isErr()
      res3.isErr()
      res4.isErr()
      res5.isErr()

  test "Parse rate limit setting - complex":
    let expU = UnlimitedRateLimit

    let test1 = @["lightpush:2/2ms", "10/2m", " store: 3/3s"]
    let exp1 = {
      GLOBAL: (10, 2.minutes),
      FILTER: FilterDefaultPerPeerRateLimit,
      LIGHTPUSH: (2, 2.milliseconds),
      STOREV3: (3, 3.seconds),
    }.toTable()

    let res1 = ProtocolRateLimitSettings.parse(test1)

    check:
      res1.isOk()
      res1.get() == exp1
      res1.get().getSetting(PEEREXCHG) == (10, 2.minutes)
      res1.get().getSetting(STOREV3) == (3, 3.seconds)
      res1.get().getSetting(LIGHTPUSH) == (2, 2.milliseconds)

    let test2 = @["lightpush:2/2ms", " store: 3/3s", "px:10/10h", "filter:4/42ms"]
    let exp2 = {
      GLOBAL: expU,
      LIGHTPUSH: (2, 2.milliseconds),
      STOREV3: (3, 3.seconds),
      FILTER: (4, 42.milliseconds),
      PEEREXCHG: (10, 10.hours),
    }.toTable()

    let res2 = ProtocolRateLimitSettings.parse(test2)

    check:
      res2.isOk()
      res2.get() == exp2

    let test3 = @["store:3/3s", "storev3:4/42ms", "storev3:5/5s", "storev3:6/6s"]
    let exp3 = {
      GLOBAL: expU, FILTER: FilterDefaultPerPeerRateLimit, STOREV3: (6, 6.seconds)
    }.toTable()

    let res3 = ProtocolRateLimitSettings.parse(test3)

    check:
      res3.isOk()
      res3.get() == exp3
      res3.get().getSetting(LIGHTPUSH) == expU

    let test4 = newSeq[string](0)
    let exp4 = {GLOBAL: expU, FILTER: FilterDefaultPerPeerRateLimit}.toTable()

    let res4 = ProtocolRateLimitSettings.parse(test4)

    check:
      res4.isOk()
      res4.get() == exp4
      res3.get().getSetting(LIGHTPUSH) == expU

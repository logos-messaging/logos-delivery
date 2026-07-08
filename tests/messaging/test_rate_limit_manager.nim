{.used.}

import chronos, testutils/unittests, stew/byteutils

import logos_delivery/messaging/rate_limit_manager/rate_limit_manager

suite "RateLimitManager - admission":
  asyncTest "admit is a pass-through when disabled":
    let rl = RateLimitManager.new(
      RateLimitConfig(enabled: false, epochPeriodSec: 600, messagesPerEpoch: 1)
    )
    for _ in 0 ..< 10:
      let res = await rl.admit("payload".toBytes())
      check res.isOk()

  asyncTest "admit is a pass-through in the skeleton even when enabled":
    ## Documents the current skeleton behaviour: per-epoch enforcement is
    ## not wired yet, so every call is admitted regardless of the
    ## configured budget. This test flips to red as soon as real
    ## enforcement lands, at which point it should be replaced with
    ## budget-boundary assertions.
    let rl = RateLimitManager.new(
      RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1)
    )
    check (await rl.admit("first".toBytes())).isOk()
    check (await rl.admit("second".toBytes())).isOk()

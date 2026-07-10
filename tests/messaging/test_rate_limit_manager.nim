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

  asyncTest "admits up to the budget then rejects with OverBudget":
    let rl = RateLimitManager.new(
      RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 3)
    )
    for i in 0 ..< 3:
      check (await rl.admit(("msg" & $i).toBytes())).isOk()
    let res = await rl.admit("over".toBytes())
    check:
      res.isErr()
      res.error == RateLimitError.OverBudget

  asyncTest "budget frees when the epoch rolls over":
    let rl = RateLimitManager.new(
      RateLimitConfig(enabled: true, epochPeriodSec: 1, messagesPerEpoch: 1)
    )
    check (await rl.admit("first".toBytes())).isOk()
    check (await rl.admit("second".toBytes())).isErr()
    await sleepAsync(1100.milliseconds)
    check (await rl.admit("third".toBytes())).isOk()
    check (await rl.admit("fourth".toBytes())).isErr()

  asyncTest "resetEpoch forces a fresh budget":
    let rl = RateLimitManager.new(
      RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1)
    )
    check (await rl.admit("first".toBytes())).isOk()
    check (await rl.admit("second".toBytes())).isErr()
    rl.resetEpoch()
    check (await rl.admit("third".toBytes())).isOk()

  asyncTest "non-positive budget or period is treated as disabled":
    let zeroBudget = RateLimitManager.new(
      RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 0)
    )
    check (await zeroBudget.admit("a".toBytes())).isOk()

    let zeroPeriod = RateLimitManager.new(
      RateLimitConfig(enabled: true, epochPeriodSec: 0, messagesPerEpoch: 1)
    )
    check (await zeroPeriod.admit("a".toBytes())).isOk()
    check (await zeroPeriod.admit("b".toBytes())).isOk()

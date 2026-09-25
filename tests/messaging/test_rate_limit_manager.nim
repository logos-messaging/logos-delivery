{.used.}

import results, chronos, testutils/unittests, stew/byteutils

import logos_delivery/messaging/rate_limit_manager/rate_limit_manager

proc fixedQuota(epochIndex, rateLimit: uint64): QuotaProvider =
  ## A quota source pinned to one epoch with its budget untouched, so
  ## limit-boundary tests don't touch the wall clock.
  return proc(): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
    return Opt.some(
      EpochQuota(epochIndex: epochIndex, rateLimit: rateLimit, remaining: rateLimit)
    )

suite "RateLimitManager - admission":
  asyncTest "admit is a pass-through when disabled":
    let rl = RateLimitManager
      .new(RateLimitConfig(enabled: false, epochPeriodSec: 600, messagesPerEpoch: 1))
      .expect("RateLimitManager.new")
    for _ in 0 ..< 10:
      check (await rl.admit("payload".toBytes())).isOk()

  asyncTest "a zero cap admits nothing":
    let rl = RateLimitManager
      .new(RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 0))
      .expect("RateLimitManager.new")
    let res = await rl.admit("a".toBytes())
    check:
      res.isErr()
      res.error == RateLimitError.OverBudget

  test "construction validates the epoch period only when enabled":
    check:
      RateLimitManager
        .new(RateLimitConfig(enabled: true, epochPeriodSec: 0, messagesPerEpoch: 1))
        .isErr()
      RateLimitManager.new(RateLimitConfig()).isOk()

  asyncTest "admits up to the message limit then rejects with OverBudget":
    ## Fixed-epoch quota so the window cannot roll mid-test.
    let rl = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 3),
        fixedQuota(epochIndex = 42, rateLimit = 100),
      )
      .expect("RateLimitManager.new")
    for i in 0 ..< 3:
      check (await rl.admit(("msg" & $i).toBytes())).isOk()
    let res = await rl.admit("over".toBytes())
    check:
      res.isErr()
      res.error == RateLimitError.OverBudget

  asyncTest "budget refills when the epoch rolls over":
    ## Drive the roll through the provider — no sleeps, no flake.
    var epoch = 1'u64
    let rl = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
        proc(): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
          return Opt.some(EpochQuota(epochIndex: epoch, rateLimit: 100, remaining: 100)),
      )
      .expect("RateLimitManager.new")
    check (await rl.admit("first".toBytes())).isOk()
    check (await rl.admit("second".toBytes())).isErr()
    epoch = 2
    check (await rl.admit("third".toBytes())).isOk()
    check (await rl.admit("fourth".toBytes())).isErr()

  asyncTest "RLN rate limit clamps a looser configured cap":
    ## config cap 5, RLN grants 2 — the lower RLN limit wins.
    let rl = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 5),
        fixedQuota(epochIndex = 7, rateLimit = 2),
      )
      .expect("RateLimitManager.new")
    check (await rl.admit("a".toBytes())).isOk()
    check (await rl.admit("b".toBytes())).isOk()
    check (await rl.admit("c".toBytes())).isErr()

  asyncTest "config cap can tighten below the RLN limit":
    ## config cap 1, RLN grants 100 — the config cap wins.
    let rl = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
        fixedQuota(epochIndex = 7, rateLimit = 100),
      )
      .expect("RateLimitManager.new")
    check (await rl.admit("a".toBytes())).isOk()
    check (await rl.admit("b".toBytes())).isErr()

  asyncTest "falls back to the wall-clock window when no quota source is set":
    ## No provider: rate limiting still enforces within a single wall-clock epoch.
    let rl = RateLimitManager
      .new(RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1))
      .expect("RateLimitManager.new")
    check (await rl.admit("first".toBytes())).isOk()
    check (await rl.admit("second".toBytes())).isErr()

  asyncTest "RLN's remaining budget drives admission":
    ## The local count has room; RLN reports the rest of the epoch's budget as
    ## spent outside this manager, so admission stops.
    var remaining = 2'u64
    let rl = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 10),
        proc(): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
          return
            Opt.some(EpochQuota(epochIndex: 7, rateLimit: 10, remaining: remaining)),
      )
      .expect("RateLimitManager.new")
    check (await rl.admit("a".toBytes())).isOk()
    remaining = 0
    let res = await rl.admit("b".toBytes())
    check:
      res.isErr()
      res.error == RateLimitError.OverBudget
      rl.sentInCurrentEpoch == 1'u64

  asyncTest "falls back to local counting when RLN reports no quota":
    let rl = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
        proc(): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
          return Opt.none(EpochQuota),
      )
      .expect("RateLimitManager.new")
    check (await rl.admit("first".toBytes())).isOk()
    check (await rl.admit("second".toBytes())).isErr()

proc approachedManager(
    messagesPerEpoch: uint64,
    approachedThresholdPercent: uint64,
    userMessageLimit: uint64 = 1_000,
): RateLimitManager =
  return RateLimitManager
    .new(
      RateLimitConfig(
        enabled: true,
        epochPeriodSec: 600,
        messagesPerEpoch: messagesPerEpoch,
        approachedThresholdPercent: approachedThresholdPercent,
      ),
      fixedQuota(epochIndex = 9, rateLimit = userMessageLimit),
    )
    .expect("RateLimitManager.new")

proc spend(rl: RateLimitManager, n: int) {.async.} =
  for i in 0 ..< n:
    doAssert (await rl.admit(("m" & $i).toBytes())).isOk()

suite "RateLimitManager - quota state":
  test "the default config carries the default approached threshold":
    check DefaultRateLimitConfig.approachedThresholdPercent ==
      DefaultApproachedThresholdPercent

  asyncTest "a disabled manager always reports Normal":
    let rl = RateLimitManager
      .new(RateLimitConfig(enabled: false, messagesPerEpoch: 0))
      .expect("RateLimitManager.new")
    check (await rl.quotaState()) == QuotaState.Normal

  test "a threshold above 100 percent is rejected when enabled":
    check:
      RateLimitManager
        .new(
          RateLimitConfig(
            enabled: true,
            epochPeriodSec: 600,
            messagesPerEpoch: 1,
            approachedThresholdPercent: 101,
          )
        )
        .isErr()
      RateLimitManager.new(RateLimitConfig(approachedThresholdPercent: 101)).isOk()

  asyncTest "Normal below the threshold, Approached at it, Exhausted at the limit":
    ## 10 per epoch at 80% -> approached from the 8th message.
    let rl = approachedManager(messagesPerEpoch = 10, approachedThresholdPercent = 80)
    check (await rl.quotaState()) == QuotaState.Normal
    await rl.spend(7)
    check (await rl.quotaState()) == QuotaState.Normal
    await rl.spend(1)
    check (await rl.quotaState()) == QuotaState.Approached
    await rl.spend(1)
    check (await rl.quotaState()) == QuotaState.Approached
    await rl.spend(1)
    check:
      (await rl.quotaState()) == QuotaState.Exhausted
      (await rl.admit("over".toBytes())).isErr()

  asyncTest "querying the state charges no budget":
    let rl = approachedManager(messagesPerEpoch = 2, approachedThresholdPercent = 50)
    for _ in 0 ..< 5:
      discard await rl.quotaState()
    check rl.sentInCurrentEpoch == 0'u64

  asyncTest "an unset threshold falls back to the default":
    ## 0 selects DefaultApproachedThresholdPercent (80): 10 -> approached at 8.
    let rl = approachedManager(messagesPerEpoch = 10, approachedThresholdPercent = 0)
    await rl.spend(7)
    check (await rl.quotaState()) == QuotaState.Normal
    await rl.spend(1)
    check (await rl.quotaState()) == QuotaState.Approached

  asyncTest "a custom threshold moves the approached boundary":
    let rl = approachedManager(messagesPerEpoch = 10, approachedThresholdPercent = 30)
    await rl.spend(2)
    check (await rl.quotaState()) == QuotaState.Normal
    await rl.spend(1)
    check (await rl.quotaState()) == QuotaState.Approached

  asyncTest "a fractional boundary rounds up":
    ## 3 per epoch at 50% -> 1.5, approached from the 2nd message.
    let rl = approachedManager(messagesPerEpoch = 3, approachedThresholdPercent = 50)
    await rl.spend(1)
    check (await rl.quotaState()) == QuotaState.Normal
    await rl.spend(1)
    check (await rl.quotaState()) == QuotaState.Approached

  asyncTest "a 100 percent threshold goes straight from Normal to Exhausted":
    let rl = approachedManager(messagesPerEpoch = 4, approachedThresholdPercent = 100)
    await rl.spend(3)
    check (await rl.quotaState()) == QuotaState.Normal
    await rl.spend(1)
    check (await rl.quotaState()) == QuotaState.Exhausted

  asyncTest "a 1 percent threshold is approached after the first message":
    let rl = approachedManager(messagesPerEpoch = 10, approachedThresholdPercent = 1)
    check (await rl.quotaState()) == QuotaState.Normal
    await rl.spend(1)
    check (await rl.quotaState()) == QuotaState.Approached

  asyncTest "a single-message budget skips Approached":
    let rl = approachedManager(messagesPerEpoch = 1, approachedThresholdPercent = 80)
    check (await rl.quotaState()) == QuotaState.Normal
    await rl.spend(1)
    check (await rl.quotaState()) == QuotaState.Exhausted

  asyncTest "a zero cap is Exhausted from the start":
    let rl = approachedManager(messagesPerEpoch = 0, approachedThresholdPercent = 80)
    check (await rl.quotaState()) == QuotaState.Exhausted

  asyncTest "the threshold follows the RLN-clamped limit":
    ## config 100, RLN grants 5 at 80% -> approached from the 4th message.
    let rl = approachedManager(
      messagesPerEpoch = 100, approachedThresholdPercent = 80, userMessageLimit = 5
    )
    await rl.spend(3)
    check (await rl.quotaState()) == QuotaState.Normal
    await rl.spend(1)
    check (await rl.quotaState()) == QuotaState.Approached

  asyncTest "a huge RLN limit does not overflow the threshold":
    let rl = approachedManager(
      messagesPerEpoch = high(uint64),
      approachedThresholdPercent = 80,
      userMessageLimit = high(uint64),
    )
    ## 80% of 2^64-1 is exactly 14757395258967641292. The first query settles
    ## the epoch so the roll does not reset the forced count.
    discard await rl.quotaState()
    rl.sentInCurrentEpoch = 14757395258967641292'u64
    check (await rl.quotaState()) == QuotaState.Approached
    rl.sentInCurrentEpoch = 14757395258967641291'u64
    check (await rl.quotaState()) == QuotaState.Normal

  asyncTest "an epoch roll resets Approached and Exhausted to Normal":
    var epoch = 1'u64
    let rl = RateLimitManager
      .new(
        RateLimitConfig(
          enabled: true,
          epochPeriodSec: 600,
          messagesPerEpoch: 2,
          approachedThresholdPercent: 50,
        ),
        proc(): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
          return Opt.some(EpochQuota(epochIndex: epoch, rateLimit: 100, remaining: 100)),
      )
      .expect("RateLimitManager.new")
    await rl.spend(1)
    check (await rl.quotaState()) == QuotaState.Approached
    epoch = 2
    check (await rl.quotaState()) == QuotaState.Normal
    await rl.spend(2)
    check (await rl.quotaState()) == QuotaState.Exhausted
    epoch = 3
    check (await rl.quotaState()) == QuotaState.Normal

  asyncTest "RLN usage is measured against RLN's limit, not the local cap":
    ## Local cap 10, nothing admitted locally; RLN 100 with 90 left. Both
    ## budgets have room, so the state stays Normal and admission goes on.
    var remaining = 90'u64
    let rl = RateLimitManager
      .new(
        RateLimitConfig(
          enabled: true,
          epochPeriodSec: 600,
          messagesPerEpoch: 10,
          approachedThresholdPercent: 80,
        ),
        proc(): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
          return
            Opt.some(EpochQuota(epochIndex: 4, rateLimit: 100, remaining: remaining)),
      )
      .expect("RateLimitManager.new")
    check:
      (await rl.quotaState()) == QuotaState.Normal
      (await rl.admit("a".toBytes())).isOk()

    ## RLN past its own threshold (80 of 100 used) is Approached even though
    ## the local count is still low.
    remaining = 20
    check (await rl.quotaState()) == QuotaState.Approached

    remaining = 0
    check (await rl.quotaState()) == QuotaState.Exhausted

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

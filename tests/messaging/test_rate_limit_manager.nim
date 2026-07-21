{.used.}

import results, chronos, testutils/unittests, stew/byteutils

import logos_delivery/messaging/rate_limit_manager/rate_limit_manager

proc fixedQuota(epochIndex, userMessageLimit: uint64): QuotaProvider =
  ## A quota source pinned to one epoch — the epoch never rolls on its own, so
  ## limit-boundary tests are deterministic without touching the wall clock.
  return proc(): Opt[EpochQuota] {.gcsafe, raises: [].} =
    Opt.some(EpochQuota(epochIndex: epochIndex, userMessageLimit: userMessageLimit))

suite "RateLimitManager - admission":
  asyncTest "admit is a pass-through when disabled":
    let rl = RateLimitManager.new(
      RateLimitConfig(enabled: false, epochPeriodSec: 600, messagesPerEpoch: 1)
    )
    for _ in 0 ..< 10:
      check (await rl.admit("payload".toBytes())).isOk()

  asyncTest "zeroed limit or epoch period is treated as disabled":
    let zeroLimit = RateLimitManager.new(
      RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 0)
    )
    check (await zeroLimit.admit("a".toBytes())).isOk()

    let zeroEpoch = RateLimitManager.new(
      RateLimitConfig(enabled: true, epochPeriodSec: 0, messagesPerEpoch: 1)
    )
    check (await zeroEpoch.admit("a".toBytes())).isOk()
    check (await zeroEpoch.admit("b".toBytes())).isOk()

  asyncTest "admits up to the message limit then rejects with OverBudget":
    ## Fixed-epoch quota so the window cannot roll mid-test.
    let rl = RateLimitManager.new(
      RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 3),
      fixedQuota(epochIndex = 42, userMessageLimit = 100),
    )
    for i in 0 ..< 3:
      check (await rl.admit(("msg" & $i).toBytes())).isOk()
    let res = await rl.admit("over".toBytes())
    check:
      res.isErr()
      res.error == RateLimitError.OverBudget

  asyncTest "allowance refills when the epoch rolls over":
    ## Drive the roll through the provider — no sleeps, no flake.
    var epoch = 1'u64
    let rl = RateLimitManager.new(
      RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
      proc(): Opt[EpochQuota] {.gcsafe, raises: [].} =
        Opt.some(EpochQuota(epochIndex: epoch, userMessageLimit: 100)),
    )
    check (await rl.admit("first".toBytes())).isOk()
    check (await rl.admit("second".toBytes())).isErr()
    epoch = 2
    check (await rl.admit("third".toBytes())).isOk()
    check (await rl.admit("fourth".toBytes())).isErr()

  asyncTest "RLN user message limit clamps a looser configured cap":
    ## config cap 5, RLN grants 2 — the third admission must reject, since
    ## exceeding RLN's limit would fail at proof generation anyway.
    let rl = RateLimitManager.new(
      RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 5),
      fixedQuota(epochIndex = 7, userMessageLimit = 2),
    )
    check (await rl.admit("a".toBytes())).isOk()
    check (await rl.admit("b".toBytes())).isOk()
    check (await rl.admit("c".toBytes())).isErr()

  asyncTest "config cap can tighten below the RLN limit":
    ## config cap 1, RLN grants 100 — the config cap wins.
    let rl = RateLimitManager.new(
      RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
      fixedQuota(epochIndex = 7, userMessageLimit = 100),
    )
    check (await rl.admit("a".toBytes())).isOk()
    check (await rl.admit("b".toBytes())).isErr()

  asyncTest "falls back to the wall-clock window when no quota source is set":
    ## No provider: rate limiting still enforces within a single wall-clock epoch.
    let rl = RateLimitManager.new(
      RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1)
    )
    check (await rl.admit("first".toBytes())).isOk()
    check (await rl.admit("second".toBytes())).isErr()

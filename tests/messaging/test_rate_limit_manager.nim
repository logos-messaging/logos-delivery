{.used.}

import results, chronos, testutils/unittests

import logos_delivery/messaging/rate_limit_manager/rate_limit_manager

proc fixedQuota(epochIndex, rateLimit: uint64): QuotaProvider =
  ## A quota source pinned to one epoch with its budget untouched, so
  ## limit-boundary tests don't touch the wall clock.
  return proc(
      timestamp: uint64
  ): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
    return Opt.some(
      EpochQuota(epochIndex: epochIndex, rateLimit: rateLimit, remaining: rateLimit)
    )

suite "RateLimitManager - admission":
  asyncTest "admit is a pass-through when disabled":
    let rl = RateLimitManager
      .new(RateLimitConfig(enabled: false, epochPeriodSec: 600, messagesPerEpoch: 1))
      .expect("RateLimitManager.new")
    for _ in 0 ..< 10:
      check rl.admit().isOk()

  asyncTest "a zero cap admits nothing":
    let rl = RateLimitManager
      .new(RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 0))
      .expect("RateLimitManager.new")
    let res = rl.admit()
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
      check rl.admit().isOk()
    let res = rl.admit()
    check:
      res.isErr()
      res.error == RateLimitError.OverBudget

  asyncTest "budget refills when the epoch rolls over":
    ## Drive the roll through the provider — no sleeps, no flake.
    var epoch = 1'u64
    let rl = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
        proc(
            timestamp: uint64
        ): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
          return Opt.some(EpochQuota(epochIndex: epoch, rateLimit: 100, remaining: 100)),
      )
      .expect("RateLimitManager.new")
    check rl.admit().isOk()
    check rl.admit().isErr()
    epoch = 2
    check rl.admit().isOk()
    check rl.admit().isErr()

  asyncTest "RLN rate limit clamps a looser configured cap":
    ## config cap 5, RLN grants 2 — the lower RLN limit wins.
    let rl = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 5),
        fixedQuota(epochIndex = 7, rateLimit = 2),
      )
      .expect("RateLimitManager.new")
    check rl.admit().isOk()
    check rl.admit().isOk()
    check rl.admit().isErr()

  asyncTest "config cap can tighten below the RLN limit":
    ## config cap 1, RLN grants 100 — the config cap wins.
    let rl = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
        fixedQuota(epochIndex = 7, rateLimit = 100),
      )
      .expect("RateLimitManager.new")
    check rl.admit().isOk()
    check rl.admit().isErr()

  asyncTest "falls back to the wall-clock window when no quota source is set":
    ## No provider: rate limiting still enforces within a single wall-clock epoch.
    let rl = RateLimitManager
      .new(RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1))
      .expect("RateLimitManager.new")
    check rl.admit().isOk()
    check rl.admit().isErr()

  asyncTest "RLN's remaining budget drives admission":
    ## The local count has room; RLN reports the rest of the epoch's budget as
    ## spent outside this manager, so admission stops.
    var remaining = 2'u64
    let rl = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 10),
        proc(
            timestamp: uint64
        ): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
          return
            Opt.some(EpochQuota(epochIndex: 7, rateLimit: 10, remaining: remaining)),
      )
      .expect("RateLimitManager.new")
    check rl.admit().isOk()
    remaining = 0
    let res = rl.admit()
    check:
      res.isErr()
      res.error == RateLimitError.OverBudget
      rl.sentInCurrentEpoch == 1'u64

  asyncTest "falls back to local counting when RLN reports no quota":
    let rl = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
        proc(
            timestamp: uint64
        ): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
          return Opt.none(EpochQuota),
      )
      .expect("RateLimitManager.new")
    check rl.admit().isOk()
    check rl.admit().isErr()

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
    doAssert rl.admit().isOk()

suite "RateLimitManager - quota state":
  test "the default config carries the default approached threshold":
    check DefaultRateLimitConfig.approachedThresholdPercent ==
      DefaultApproachedThresholdPercent

  asyncTest "a disabled manager always reports Normal":
    let rl = RateLimitManager
      .new(RateLimitConfig(enabled: false, messagesPerEpoch: 0))
      .expect("RateLimitManager.new")
    check rl.quotaState() == QuotaState.Normal

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
    check rl.quotaState() == QuotaState.Normal
    await rl.spend(7)
    check rl.quotaState() == QuotaState.Normal
    await rl.spend(1)
    check rl.quotaState() == QuotaState.Approached
    await rl.spend(1)
    check rl.quotaState() == QuotaState.Approached
    await rl.spend(1)
    check:
      rl.quotaState() == QuotaState.Exhausted
      rl.admit().isErr()

  asyncTest "querying the state charges no budget":
    let rl = approachedManager(messagesPerEpoch = 2, approachedThresholdPercent = 50)
    for _ in 0 ..< 5:
      discard rl.quotaState()
    check rl.sentInCurrentEpoch == 0'u64

  asyncTest "an unset threshold falls back to the default":
    ## 0 selects DefaultApproachedThresholdPercent (80): 10 -> approached at 8.
    let rl = approachedManager(messagesPerEpoch = 10, approachedThresholdPercent = 0)
    await rl.spend(7)
    check rl.quotaState() == QuotaState.Normal
    await rl.spend(1)
    check rl.quotaState() == QuotaState.Approached

  asyncTest "a custom threshold moves the approached boundary":
    let rl = approachedManager(messagesPerEpoch = 10, approachedThresholdPercent = 30)
    await rl.spend(2)
    check rl.quotaState() == QuotaState.Normal
    await rl.spend(1)
    check rl.quotaState() == QuotaState.Approached

  asyncTest "a fractional boundary rounds up":
    ## 3 per epoch at 50% -> 1.5, approached from the 2nd message.
    let rl = approachedManager(messagesPerEpoch = 3, approachedThresholdPercent = 50)
    await rl.spend(1)
    check rl.quotaState() == QuotaState.Normal
    await rl.spend(1)
    check rl.quotaState() == QuotaState.Approached

  asyncTest "a 100 percent threshold goes straight from Normal to Exhausted":
    let rl = approachedManager(messagesPerEpoch = 4, approachedThresholdPercent = 100)
    await rl.spend(3)
    check rl.quotaState() == QuotaState.Normal
    await rl.spend(1)
    check rl.quotaState() == QuotaState.Exhausted

  asyncTest "a 1 percent threshold is approached after the first message":
    let rl = approachedManager(messagesPerEpoch = 10, approachedThresholdPercent = 1)
    check rl.quotaState() == QuotaState.Normal
    await rl.spend(1)
    check rl.quotaState() == QuotaState.Approached

  asyncTest "a single-message budget skips Approached":
    let rl = approachedManager(messagesPerEpoch = 1, approachedThresholdPercent = 80)
    check rl.quotaState() == QuotaState.Normal
    await rl.spend(1)
    check rl.quotaState() == QuotaState.Exhausted

  asyncTest "a zero cap is Exhausted from the start":
    let rl = approachedManager(messagesPerEpoch = 0, approachedThresholdPercent = 80)
    check rl.quotaState() == QuotaState.Exhausted

  asyncTest "the threshold follows the RLN-clamped limit":
    ## config 100, RLN grants 5 at 80% -> approached from the 4th message.
    let rl = approachedManager(
      messagesPerEpoch = 100, approachedThresholdPercent = 80, userMessageLimit = 5
    )
    await rl.spend(3)
    check rl.quotaState() == QuotaState.Normal
    await rl.spend(1)
    check rl.quotaState() == QuotaState.Approached

  asyncTest "a huge RLN limit does not overflow the threshold":
    let rl = approachedManager(
      messagesPerEpoch = high(uint64),
      approachedThresholdPercent = 80,
      userMessageLimit = high(uint64),
    )
    ## 80% of 2^64-1 is exactly 14757395258967641292. The first query settles
    ## the epoch so the roll does not reset the forced count.
    discard rl.quotaState()
    rl.sentInCurrentEpoch = 14757395258967641292'u64
    check rl.quotaState() == QuotaState.Approached
    rl.sentInCurrentEpoch = 14757395258967641291'u64
    check rl.quotaState() == QuotaState.Normal

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
        proc(
            timestamp: uint64
        ): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
          return Opt.some(EpochQuota(epochIndex: epoch, rateLimit: 100, remaining: 100)),
      )
      .expect("RateLimitManager.new")
    await rl.spend(1)
    check rl.quotaState() == QuotaState.Approached
    epoch = 2
    check rl.quotaState() == QuotaState.Normal
    await rl.spend(2)
    check rl.quotaState() == QuotaState.Exhausted
    epoch = 3
    check rl.quotaState() == QuotaState.Normal

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
        proc(
            timestamp: uint64
        ): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
          return
            Opt.some(EpochQuota(epochIndex: 4, rateLimit: 100, remaining: remaining)),
      )
      .expect("RateLimitManager.new")
    check:
      rl.quotaState() == QuotaState.Normal
      rl.admit().isOk()

    ## RLN past its own threshold (80 of 100 used) is Approached even though
    ## the local count is still low.
    remaining = 20
    check rl.quotaState() == QuotaState.Approached

    remaining = 0
    check rl.quotaState() == QuotaState.Exhausted

const EpochPeriodSec = 600'u64

type FakeRln = ref object
  ## An RLN budget source with epochs of `EpochPeriodSec`.
  ## It is also the clock that the manager reads.
  now: uint64
  rateLimit: uint64
  spent: uint64 ## The message ids that RLN drew in the epoch of `now`.
  calls: int
  noEpochSize: bool ## The backend does not state its epoch length.
  fails: bool ## The read of the budget fails.

proc provider(rln: FakeRln): QuotaProvider =
  return proc(
      timestamp: uint64
  ): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
    inc rln.calls
    if rln.fails:
      return Opt.none(EpochQuota)
    let epochIndex = timestamp div EpochPeriodSec
    let spent = if epochIndex == rln.now div EpochPeriodSec: rln.spent else: 0'u64
    return Opt.some(
      EpochQuota(
        epochIndex: epochIndex,
        rateLimit: rln.rateLimit,
        remaining: rln.rateLimit - spent,
      )
    )

proc clock(rln: FakeRln): Clock =
  return proc(): uint64 {.gcsafe, raises: [].} =
    rln.now

proc epochSize(rln: FakeRln): EpochSizeProvider =
  return proc(): Opt[uint64] {.gcsafe, raises: [].} =
    if rln.noEpochSize:
      return Opt.none(uint64)
    return Opt.some(EpochPeriodSec)

proc rlnManager(rln: FakeRln, config = RateLimitConfig()): RateLimitManager =
  return RateLimitManager
    .new(config, rln.provider(), rln.clock(), rln.epochSize())
    .expect("RateLimitManager.new")

suite "RateLimitManager RLN budget":
  asyncTest "the RLN budget limits sends when the config is disabled":
    ## The messaging client gives each node this manager.
    ## A node with RLN must refuse a send over the RLN budget with no rate-limit config.
    let rln = FakeRln(now: 10 * EpochPeriodSec, rateLimit: 2)
    let rl = rlnManager(rln)
    check:
      rl.admit().isOk()
      rl.admit().isOk()
      rl.admit().error == RateLimitError.OverBudget
      rl.quotaState() == QuotaState.Exhausted

  asyncTest "a budget with a zero rate limit does not limit sends":
    ## RLN reports a zero rate limit for a node with no usable membership.
    ## The proof attach reports that fault, so the manager must not refuse the send.
    let rln = FakeRln(now: 10 * EpochPeriodSec, rateLimit: 0)
    let rl = rlnManager(rln)
    for _ in 0 ..< 3:
      check rl.admit().isOk()
    check rl.quotaState() == QuotaState.Normal

  asyncTest "retryAfter is the time to the end of the RLN epoch":
    ## The RLN backend states its epoch length.
    ## Each epoch starts at a multiple of that length.
    let rln = FakeRln(now: 10 * EpochPeriodSec + 123, rateLimit: 1)
    let rl = rlnManager(rln)
    check:
      rl.admit().isOk()
      rl.admit().isErr()
      rl.retryAfter() == chronos.seconds(int64(EpochPeriodSec - 123))
    rln.now += 100
    check rl.retryAfter() == chronos.seconds(int64(EpochPeriodSec - 223))

  asyncTest "a budget with no epoch end refills when RLN reports the new epoch":
    ## An RLN backend can state no epoch length.
    ## The manager then cannot tell when the budget refills.
    let rln = FakeRln(now: 10 * EpochPeriodSec, rateLimit: 1, noEpochSize: true)
    let rl = rlnManager(rln)
    check:
      rl.admit().isOk()
      rl.admit().isErr()
      rl.retryAfter() == UnknownEpochRetryAfter

    # `admit` reads the budget of the new epoch before it charges.
    rln.now = 11 * EpochPeriodSec
    check:
      rl.admit().isOk()
      rl.admit().isErr()

  asyncTest "the budget refills at the end of the epoch with no answer from RLN":
    ## `send` cannot wait for RLN.
    ## After the end of the epoch, `admit` must pass before a new budget comes.
    let rln = FakeRln(now: 10 * EpochPeriodSec, rateLimit: 1)
    var answers = true
    let rl = RateLimitManager
      .new(
        RateLimitConfig(),
        proc(
            timestamp: uint64
        ): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
          if not answers:
            # An answer that never comes.
            await Future[void].Raising([]).init(
              "no-rln-answer", {FutureFlag.OwnCancelSchedule}
            )
          return await rln.provider()(timestamp),
        rln.clock(),
        rln.epochSize(),
      )
      .expect("RateLimitManager.new")
    check:
      rl.admit().isOk()
      rl.admit().isErr()

    answers = false
    rln.now = 11 * EpochPeriodSec - 1
    check rl.admit().isErr()
    rln.now = 11 * EpochPeriodSec
    check:
      rl.admit().isOk()
      rl.admit().isErr()

  asyncTest "the message ids that RLN drew before the start count":
    ## After a restart, the manager has no count of its own.
    ## The first budget from RLN gives the ids that the node drew before.
    let rln = FakeRln(now: 10 * EpochPeriodSec, rateLimit: 3, spent: 3)
    let rl = rlnManager(rln)
    rl.start()
    await rl.stop()
    check rln.calls > 0 # `start` read the budget, before any `admit`
    check:
      rl.sentInCurrentEpoch == 0'u64
      rl.quotaState() == QuotaState.Exhausted
      rl.admit().isErr()

  asyncTest "admissions with no proof yet count with the ids from before the start":
    ## An admission draws its RLN message id later, with its proof.
    ## So the budget from RLN does not count the admissions that have no proof yet.
    let rln = FakeRln(now: 10 * EpochPeriodSec, rateLimit: 100, spent: 95)
    let rl = rlnManager(rln)
    rl.start()
    await rl.stop()
    for _ in 0 ..< 5:
      check rl.admit().isOk()
    check:
      rln.spent == 95'u64 # no admission drew an id
      rl.admit().isErr()
      rl.quotaState() == QuotaState.Exhausted

    rln.spent = 100
    check rl.admit().isErr()
    rln.now = 11 * EpochPeriodSec
    rln.spent = 0
    for _ in 0 ..< 100:
      check rl.admit().isOk()
    check rl.admit().isErr()

  asyncTest "release gives back the charge of one admission":
    ## A proof that fails draws no RLN message id.
    let rln = FakeRln(now: 10 * EpochPeriodSec, rateLimit: 1)
    let rl = rlnManager(rln)
    let charge = rl.admit().expect("admit")
    check rl.admit().isErr()
    rl.release(charge)
    let second = rl.admit().expect("admit after the release")
    check rl.admit().isErr()

    # A charge of an epoch that ended gives nothing back to the new epoch.
    rln.now = 11 * EpochPeriodSec
    check rl.admit().isOk()
    rl.release(second)
    check rl.admit().isErr()

  asyncTest "a budget read that fails keeps the last budget":
    ## One read that fails must not turn the limit off.
    let rln = FakeRln(now: 10 * EpochPeriodSec, rateLimit: 2)
    let rl = rlnManager(rln)
    check rl.admit().isOk()
    rln.fails = true
    check:
      rl.admit().isOk()
      rl.admit().isErr()
      rl.quotaState() == QuotaState.Exhausted

  asyncTest "retryAfter of the wall-clock window is the time to its end":
    let now = 10 * EpochPeriodSec + 590
    let rl = RateLimitManager
      .new(
        RateLimitConfig(
          enabled: true, epochPeriodSec: EpochPeriodSec, messagesPerEpoch: 1
        ),
        clock = proc(): uint64 {.gcsafe, raises: [].} =
          now,
      )
      .expect("RateLimitManager.new")
    check:
      rl.admit().isOk()
      rl.admit().isErr()
      rl.retryAfter() == chronos.seconds(10)

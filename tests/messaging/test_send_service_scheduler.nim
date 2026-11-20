{.used.}

import std/[importutils, sequtils]
import chronos, testutils/unittests, results, stew/byteutils

import
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service {.all.}, send_processor, delivery_task]
import ../testlib/[futures, testasync, wakunodeconf]

privateAccess(SendService) # the tests read `attempts`

## Coverage for the rate-limit seam of the send service: `enqueue` charges a
## task exactly once however many attempts it takes, and refuses a task over
## budget with `RateLimited` instead of queueing it. A fake processor scripts the
## delivery outcome. Each service ticks each 10 minutes, so the tests start each
## next attempt with `retryNow`.

type FakeSendProcessor = ref object of BaseSendProcessor
  calls: int
  script: seq[DeliveryState]
    ## State to stamp on the task per invocation; the last entry repeats.

method process(self: FakeSendProcessor, task: DeliveryTask): Future[void] {.async.} =
  let outcome = self.script[min(self.calls, self.script.high)]
  inc self.calls
  task.state = outcome
  if outcome == DeliveryState.SuccessfullyPropagated and
      task.firstPropagatedTime.isNone():
    task.firstPropagatedTime = Opt.some(Moment.now())

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

proc fixedEpochQuota(
    epoch: ref uint64, rateLimit: uint64, remaining: ref uint64 = nil
): QuotaProvider =
  ## Quota pinned to whatever `epoch` (and `remaining`, when given) holds, so a
  ## test rolls the epoch or spends RLN budget by writing through the ref.
  ## Without `remaining` the epoch's budget is reported untouched.
  return proc(
      timestamp: uint64
  ): Future[Opt[EpochQuota]] {.async: (raises: [CancelledError]), gcsafe.} =
    let left = if remaining.isNil(): rateLimit else: remaining[]
    return
      Opt.some(EpochQuota(epochIndex: epoch[], rateLimit: rateLimit, remaining: left))

suite "SendService - rate-limit scheduling":
  var waku {.threadvar.}: Waku
  var started {.threadvar.}: seq[SendService]

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")
    started = @[]

  asyncTeardown:
    for service in started:
      await service.stopSendService()
    ## The node is never started, so stop is best-effort cleanup.
    discard await waku.stop()

  proc buildTask(
      payload: string,
      timestamp: Timestamp = getNowInNanosecondTime(),
      ephemeral = false,
  ): DeliveryTask =
    ## Built directly rather than via `DeliveryTask.new`, which needs a broker
    ## provider only registered once the node starts. The message is from now,
    ## so it is inside the delivery window.
    let msg = WakuMessage(
      contentTopic: "/test/1/scheduler/proto",
      payload: payload.toBytes(),
      timestamp: timestamp,
      ephemeral: ephemeral,
    )
    let pubsubTopic = PubsubTopic("/waku/2/rs/3/0")
    return DeliveryTask(
      pubsubTopic: pubsubTopic,
      msg: msg,
      msgHash: computeMessageHash(pubsubTopic, msg),
      state: DeliveryState.Entry,
    )

  proc waitAttempts(
      service: SendService, count: int, timeout = FUTURE_TIMEOUT_MEDIUM
  ): Future[bool] {.async.} =
    ## Completes with true when `count` attempts ended, or with false after
    ## `timeout`. It is the bool form of `checkUntilTimeoutCustom`, so a check can
    ## also wait for an attempt that must not come.
    let deadline = Moment.now() + timeout
    while service.attempts < count:
      if Moment.now() > deadline:
        return false
      await sleepAsync(chronos.milliseconds(5))
    return true

  proc startOnce(service: SendService) =
    if service notin started:
      service.startSendService()
      started.add(service)

  proc sendNow(service: SendService, task: DeliveryTask) {.async.} =
    ## Queues `task`, starts the service if needed, and waits for the end of the
    ## first attempt of the task.
    let before = service.attempts
    let res = service.enqueue(task)
    check:
      res.isOk()
      res.get() == task.msgHash
    service.startOnce()
    check await service.waitAttempts(before + 1)

  proc refusedSend(
      service: SendService, task: DeliveryTask
  ): Future[SendError] {.async.} =
    ## Sends `task`, which the service must refuse, and returns why. A refused
    ## task is never queued, so no attempt starts for it.
    let before = service.attempts
    let res = service.enqueue(task)
    check res.isErr()
    service.startOnce()
    check:
      not await service.waitAttempts(before + 1, FUTURE_TIMEOUT_SHORT)
      not service.isQueued(task)
      task.state == DeliveryState.Entry
    return res.errorOr(SendError.init(SendErrorKind.NotStarted, "send accepted"))

  proc retryAndWait(service: SendService, attempts: int) {.async.} =
    ## Starts the next attempt of each waiting task, and waits for `attempts`
    ## attempts to end. Each service of this file ticks each 10 minutes, so only
    ## the waiting tasks try. With zero, it checks that no attempt starts.
    let before = service.attempts
    service.retryNow()
    if attempts == 0:
      check not await service.waitAttempts(before + 1, FUTURE_TIMEOUT_SHORT)
    else:
      check await service.waitAttempts(before + attempts)

  proc listenErrors(
      brokerCtx: BrokerContext,
      errors: ref seq[MessageErrorEvent],
      seen: AsyncEvent = nil,
  ) =
    discard MessageErrorEvent
      .listen(
        brokerCtx,
        proc(evt: MessageErrorEvent) {.async: (raises: []).} =
          errors[].add(evt)
          if not seen.isNil():
            seen.fire()
        ,
      )
      .expect("listen MessageErrorEvent")

  asyncTest "a task is charged once even when delivery takes several rounds":
    ## First round fails to propagate, second succeeds. The retry must not draw a
    ## second slot: `send` charged the budget and set `firstAdmittedTime`.
    let epoch = new uint64
    epoch[] = 5'u64
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 3),
        fixedEpochQuota(epoch, rateLimit = 100),
      )
      .expect("RateLimitManager.new")
    let processor = FakeSendProcessor(
      script: @[DeliveryState.NextRoundRetry, DeliveryState.SuccessfullyPropagated]
    )
    let service = SendService
      .new(false, waku, manager, processor, retryInterval = chronos.minutes(10))
      .expect("SendService.new")

    let task = buildTask("hi")
    await service.sendNow(task)
    check:
      manager.sentInCurrentEpoch == 1'u64
      task.firstAdmittedTime.isSome()
      task.state == DeliveryState.NextRoundRetry

    await service.retryAndWait(1)
    check:
      manager.sentInCurrentEpoch == 1'u64 # not re-charged on retry
      processor.calls == 2
      task.state == DeliveryState.SuccessfullyPropagated

  asyncTest "an over-budget send is refused as RateLimited, with no event":
    ## Budget of one per epoch. The second send is refused at once with the time
    ## to the next epoch; once the epoch rolls, a new send of it is accepted.
    let epoch = new uint64
    epoch[] = 1'u64
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
        fixedEpochQuota(epoch, rateLimit = 100),
      )
      .expect("RateLimitManager.new")
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let service = SendService
      .new(false, waku, manager, processor, retryInterval = chronos.minutes(10))
      .expect("SendService.new")

    let errors = new seq[MessageErrorEvent]
    listenErrors(waku.brokerCtx, errors)
    defer:
      await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

    let first = buildTask("one")
    await service.sendNow(first)
    check:
      first.state == DeliveryState.SuccessfullyPropagated
      manager.sentInCurrentEpoch == 1'u64

    let second = buildTask("two")
    let refusal = await service.refusedSend(second)
    check:
      refusal.kind == SendErrorKind.RateLimited
      refusal.retryAfter > ZeroDuration
      refusal.retryAfter <= chronos.seconds(600)
      second.firstAdmittedTime.isNone()
      manager.sentInCurrentEpoch == 1'u64
      processor.calls == 1
      errors[].len == 0 # the caller gets the error, so no event follows

    # The epoch rolls: the budget refills and the same message is accepted.
    epoch[] = 2'u64
    await service.sendNow(second)
    check:
      second.firstAdmittedTime.isSome()
      second.state == DeliveryState.SuccessfullyPropagated
      manager.sentInCurrentEpoch == 1'u64

  asyncTest "RLN's spent budget refuses a send until the epoch rolls":
    ## The local cap has room, but RLN reports the epoch's budget spent, so the
    ## send is refused; the roll refills RLN's budget and a new send goes out.
    let epoch = new uint64
    epoch[] = 1'u64
    let remaining = new uint64
    remaining[] = 0'u64
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 10),
        fixedEpochQuota(epoch, rateLimit = 10, remaining),
      )
      .expect("RateLimitManager.new")
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let service = SendService
      .new(false, waku, manager, processor, retryInterval = chronos.minutes(10))
      .expect("SendService.new")

    let task = buildTask("one")
    let refusal = await service.refusedSend(task)
    check:
      refusal.kind == SendErrorKind.RateLimited
      refusal.retryAfter > ZeroDuration
      task.firstAdmittedTime.isNone()
      processor.calls == 0

    epoch[] = 2'u64
    remaining[] = 10'u64
    await service.sendNow(task)
    check:
      task.firstAdmittedTime.isSome()
      task.state == DeliveryState.SuccessfullyPropagated

  proc approachedService(
      epoch: ref uint64, messagesPerEpoch: uint64, processor: FakeSendProcessor
  ): (SendService, RateLimitManager) =
    ## 50% threshold, so half the budget spent is Approached.
    let manager = RateLimitManager
      .new(
        RateLimitConfig(
          enabled: true,
          epochPeriodSec: 600,
          messagesPerEpoch: messagesPerEpoch,
          approachedThresholdPercent: 50,
        ),
        fixedEpochQuota(epoch, rateLimit = 100),
      )
      .expect("RateLimitManager.new")
    let service = SendService
      .new(false, waku, manager, processor, retryInterval = chronos.minutes(10))
      .expect("SendService.new")
    return (service, manager)

  asyncTest "an ephemeral message is refused when the quota is approached":
    let epoch = new uint64
    epoch[] = 1'u64
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let (service, manager) = approachedService(epoch, 4, processor)

    let errors = new seq[MessageErrorEvent]
    listenErrors(waku.brokerCtx, errors)
    defer:
      await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

    await service.sendNow(buildTask("one"))
    await service.sendNow(buildTask("two"))
    check manager.quotaState() == QuotaState.Approached
    let callsBefore = processor.calls

    let eph = buildTask("eph", ephemeral = true)
    let refusal = await service.refusedSend(eph)
    check:
      refusal.kind == SendErrorKind.RateLimited
      refusal.retryAfter > ZeroDuration
      eph.firstAdmittedTime.isNone() # no slot, so no RLN proof either
      manager.sentInCurrentEpoch == 2'u64
      processor.calls == callsBefore
      errors[].len == 0

  asyncTest "an ephemeral message is refused when the quota is exhausted":
    let epoch = new uint64
    epoch[] = 1'u64
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let (service, manager) = approachedService(epoch, 1, processor)

    await service.sendNow(buildTask("one"))
    check manager.quotaState() == QuotaState.Exhausted
    let callsBefore = processor.calls

    let eph = buildTask("eph", ephemeral = true)
    let refusal = await service.refusedSend(eph)
    check:
      refusal.kind == SendErrorKind.RateLimited
      refusal.retryAfter > ZeroDuration
      eph.firstAdmittedTime.isNone()
      processor.calls == callsBefore
      manager.sentInCurrentEpoch == 1'u64

  asyncTest "an ephemeral message below the threshold is charged and sent":
    let epoch = new uint64
    epoch[] = 1'u64
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let (service, manager) = approachedService(epoch, 4, processor)

    let eph = buildTask("eph", ephemeral = true)
    await service.sendNow(eph)
    check:
      eph.state == DeliveryState.SuccessfullyPropagated
      eph.firstAdmittedTime.isSome()
      manager.sentInCurrentEpoch == 1'u64

  asyncTest "a durable message is still admitted when the quota is approached":
    let epoch = new uint64
    epoch[] = 1'u64
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let (service, manager) = approachedService(epoch, 4, processor)

    await service.sendNow(buildTask("a"))
    await service.sendNow(buildTask("b"))
    check manager.quotaState() == QuotaState.Approached

    let durable = buildTask("c")
    await service.sendNow(durable)
    check:
      durable.state == DeliveryState.SuccessfullyPropagated
      manager.sentInCurrentEpoch == 3'u64

  asyncTest "a task past the delivery window of its timestamp fails; a fresh one stays":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let processor = FakeSendProcessor(script: @[DeliveryState.NextRoundRetry])
    let service = SendService
      .new(false, waku, manager, processor, retryInterval = chronos.minutes(10))
      .expect("SendService.new")

    let errors = new seq[MessageErrorEvent]
    let errorSeen = newAsyncEvent()
    listenErrors(waku.brokerCtx, errors, errorSeen)
    defer:
      await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

    let now = getNowInNanosecondTime()
    let stale = buildTask("stale", now - 60_000_000_000)
    let fresh = buildTask("fresh", now)
    # The window is checked before each attempt, so the stale task fails with
    # no attempt.
    check (service.enqueue(stale)).isOk()
    service.startOnce()
    check await errorSeen.wait().withTimeout(FUTURE_TIMEOUT_MEDIUM)
    await service.sendNow(fresh)
    check:
      processor.calls == 1
      stale.state == DeliveryState.FailedToDeliver
      errors[].mapIt(it.messageHash) == @[stale.msgHash.to0xHex()]
      errors[].mapIt(it.kind) == @[MessageErrorKind.NotPropagated]
      fresh.state == DeliveryState.NextRoundRetry
      service.isQueued(fresh)
      not service.isQueued(stale)

  asyncTest "a send beyond the send queue limit is refused with no event":
    let epoch = new uint64
    epoch[] = 1'u64
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 10),
        fixedEpochQuota(epoch, rateLimit = 100),
      )
      .expect("RateLimitManager.new")
    let processor = FakeSendProcessor(script: @[DeliveryState.NextRoundRetry])
    let service = SendService
      .new(
        false,
        waku,
        manager,
        processor,
        maxSendsInFlight = 2,
        retryInterval = chronos.minutes(10),
      )
      .expect("SendService.new")

    let errors = new seq[MessageErrorEvent]
    listenErrors(waku.brokerCtx, errors)
    defer:
      await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

    await service.sendNow(buildTask("one"))
    await service.sendNow(buildTask("two"))
    check:
      service.isFull()
      errors[].len == 0

    let rejected = buildTask("three")
    let refusal = await service.refusedSend(rejected)
    check:
      refusal.kind == SendErrorKind.QueueFull
      refusal.desc == "send queue full, retry later"
      errors[].len == 0 # the caller gets the error, so no event follows
      manager.sentInCurrentEpoch == 2'u64 # a refused send spends no budget
      processor.calls == 2

  asyncTest "a propagated task past the validation window fails; a fresh one stays":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let service = SendService
      .new(
        true,
        waku,
        manager,
        processor,
        maxValidationAge = chronos.seconds(30),
        retryInterval = chronos.minutes(10),
      )
      .expect("SendService.new")

    let errors = new seq[MessageErrorEvent]
    let errorSeen = newAsyncEvent()
    listenErrors(waku.brokerCtx, errors, errorSeen)
    defer:
      await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

    let expired = buildTask("one")
    let fresh = buildTask("two")
    # The task already waited for a Store confirmation longer than the window.
    expired.storeValidationWaited = chronos.seconds(60)
    await service.sendNow(expired)
    await service.sendNow(fresh)
    check:
      expired.state == DeliveryState.FailedToDeliver
      fresh.state == DeliveryState.SuccessfullyPropagated
      await errorSeen.wait().withTimeout(chronos.seconds(1))
      errors[].mapIt(it.messageHash) == @[expired.msgHash.to0xHex()]
      errors[].mapIt(it.kind) == @[MessageErrorKind.NotStored]

  asyncTest "with reliability off a propagated task is evicted without MessageError":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let service = SendService
      .new(
        false,
        waku,
        manager,
        processor,
        maxSendsInFlight = 1,
        maxValidationAge = chronos.seconds(30),
        retryInterval = chronos.minutes(10),
      )
      .expect("SendService.new")

    let errors = new seq[MessageErrorEvent]
    listenErrors(waku.brokerCtx, errors)
    defer:
      await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

    # The send queue holds one task, so `isFull` tells whether it holds the task.
    let task = buildTask("one")
    await service.sendNow(task)
    check:
      task.state == DeliveryState.SuccessfullyPropagated
      errors[].len == 0
      not service.isFull() # the service removed the task

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

## Coverage for the rate-limit seam of the send service: a task is charged
## exactly once however many attempts it takes, and an over-budget task is
## parked then released when the epoch rolls. A fake processor scripts the
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
  return proc(): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
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
      id, payload: string,
      timestamp: Timestamp = getNowInNanosecondTime(),
      ephemeral = false,
  ): DeliveryTask =
    ## Built directly rather than via `DeliveryTask.new`, which needs a broker
    ## provider only registered once the node starts. The message is from now,
    ## so a task that parks for budget is not too old.
    let msg = WakuMessage(
      contentTopic: "/test/1/scheduler/proto",
      payload: payload.toBytes(),
      timestamp: timestamp,
      ephemeral: ephemeral,
    )
    let pubsubTopic = PubsubTopic("/waku/2/rs/3/0")
    return DeliveryTask(
      requestId: RequestId(id),
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

  proc sendNow(service: SendService, task: DeliveryTask) {.async.} =
    ## Queues `task`, starts the service if needed, and waits for the end of the
    ## first attempt of the task.
    let before = service.attempts
    check service.enqueue(task).isOk()
    if service notin started:
      service.startSendService()
      started.add(service)
    check await service.waitAttempts(before + 1)

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

  asyncTest "a task is charged once even when delivery takes several rounds":
    ## First round fails to propagate, second succeeds. The retry must not draw a
    ## second slot: `firstAdmittedTime` guards re-admission.
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

    let task = buildTask("charge-once", "hi")
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

  asyncTest "an over-budget task is parked, then released when the epoch rolls":
    ## Budget of one per epoch. The second send is parked until the epoch rolls,
    ## then admitted and delivered.
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

    let first = buildTask("in-budget", "one")
    await service.sendNow(first)
    check:
      first.state == DeliveryState.SuccessfullyPropagated
      manager.sentInCurrentEpoch == 1'u64

    let second = buildTask("over-budget", "two")
    await service.sendNow(second)
    check:
      second.state == DeliveryState.NextRoundRetry # parked
      second.firstAdmittedTime.isNone() # never admitted
    let callsWhenParked = processor.calls

    # Same epoch: still over budget, so the parked task is not handed to the
    # processor.
    await service.retryAndWait(1)
    check:
      second.state == DeliveryState.NextRoundRetry
      second.firstAdmittedTime.isNone()
      processor.calls == callsWhenParked

    # Epoch rolls: budget refills, the parked task is admitted and delivered.
    epoch[] = 2'u64
    await service.retryAndWait(1)
    check:
      second.firstAdmittedTime.isSome()
      second.state == DeliveryState.SuccessfullyPropagated

  asyncTest "RLN's remaining budget parks a send until the epoch rolls":
    ## The local cap has room, but RLN reports the epoch's budget spent, so the
    ## task parks; the roll refills RLN's budget and releases it.
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

    let task = buildTask("rln-spent", "one")
    await service.sendNow(task)
    check:
      task.state == DeliveryState.NextRoundRetry
      task.firstAdmittedTime.isNone()
      processor.calls == 0

    await service.retryAndWait(1)
    check:
      task.firstAdmittedTime.isNone()
      processor.calls == 0

    epoch[] = 2'u64
    remaining[] = 10'u64
    await service.retryAndWait(1)
    check:
      task.firstAdmittedTime.isSome()
      task.state == DeliveryState.SuccessfullyPropagated

  asyncTest "a task parked for budget reports itself queued, exactly once":
    ## The park branch is re-entered every retry round; the event must not be.
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

    var queued: seq[MessageQueuedEvent]
    discard MessageQueuedEvent
      .listen(
        waku.brokerCtx,
        proc(evt: MessageQueuedEvent) {.async: (raises: []).} =
          queued.add(evt),
      )
      .expect("listen MessageQueuedEvent")

    ## Spends the epoch's single slot; admitted, so it reports nothing.
    await service.sendNow(buildTask("queued-in-budget", "one"))
    check queued.len == 0

    let second = buildTask("queued-over-budget", "two")
    await service.sendNow(second)
    check:
      queued.len == 1
      queued[0].requestId == second.requestId
      queued[0].messageHash == second.msgHash.to0xHex()

    ## Still over budget: the task parks again, the event does not repeat.
    await service.retryAndWait(1)
    check queued.len == 1

    ## Released by the roll, and delivery emits no further queued event.
    epoch[] = 2'u64
    await service.retryAndWait(1)
    check:
      second.state == DeliveryState.SuccessfullyPropagated
      queued.len == 1

    await MessageQueuedEvent.dropAllListeners(waku.brokerCtx)

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

  asyncTest "an ephemeral message is dropped when the quota is approached":
    let epoch = new uint64
    epoch[] = 1'u64
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let (service, manager) = approachedService(epoch, 4, processor)

    var errors: seq[MessageErrorEvent]
    discard MessageErrorEvent
      .listen(
        waku.brokerCtx,
        proc(evt: MessageErrorEvent) {.async: (raises: []).} =
          errors.add(evt),
      )
      .expect("listen MessageErrorEvent")
    var queued: seq[MessageQueuedEvent]
    discard MessageQueuedEvent
      .listen(
        waku.brokerCtx,
        proc(evt: MessageQueuedEvent) {.async: (raises: []).} =
          queued.add(evt),
      )
      .expect("listen MessageQueuedEvent")

    await service.sendNow(buildTask("durable-1", "one"))
    await service.sendNow(buildTask("durable-2", "two"))
    check (await manager.quotaState()) == QuotaState.Approached
    let callsBefore = processor.calls

    let eph = buildTask("ephemeral-approached", "eph", ephemeral = true)
    await service.sendNow(eph)
    check:
      eph.state == DeliveryState.FailedToDeliver
      eph.firstAdmittedTime.isNone() # no slot, so no RLN proof either
      manager.sentInCurrentEpoch == 2'u64
      processor.calls == callsBefore
      queued.len == 0
      errors.mapIt(it.requestId) == @[eph.requestId]
      errors.mapIt(it.messageHash) == @[eph.msgHash.to0xHex()]

    ## It is not parked, so no later attempt gives it to the processor.
    await service.retryAndWait(0)
    check processor.calls == callsBefore

    await MessageErrorEvent.dropAllListeners(waku.brokerCtx)
    await MessageQueuedEvent.dropAllListeners(waku.brokerCtx)

  asyncTest "an ephemeral message is dropped, not parked, when the quota is exhausted":
    let epoch = new uint64
    epoch[] = 1'u64
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let (service, manager) = approachedService(epoch, 1, processor)

    var errors: seq[MessageErrorEvent]
    discard MessageErrorEvent
      .listen(
        waku.brokerCtx,
        proc(evt: MessageErrorEvent) {.async: (raises: []).} =
          errors.add(evt),
      )
      .expect("listen MessageErrorEvent")

    await service.sendNow(buildTask("durable-spends", "one"))
    check (await manager.quotaState()) == QuotaState.Exhausted
    let callsBefore = processor.calls

    let eph = buildTask("ephemeral-exhausted", "eph", ephemeral = true)
    await service.sendNow(eph)
    check:
      eph.state == DeliveryState.FailedToDeliver
      eph.firstAdmittedTime.isNone()
      errors.len == 1

    ## Budget refills, but the dropped message stays dropped.
    epoch[] = 2'u64
    await service.retryAndWait(0)
    check:
      processor.calls == callsBefore
      (await manager.quotaState()) == QuotaState.Normal
      manager.sentInCurrentEpoch == 0'u64

    await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

  asyncTest "an ephemeral message below the threshold is charged and sent":
    let epoch = new uint64
    epoch[] = 1'u64
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let (service, manager) = approachedService(epoch, 4, processor)

    let eph = buildTask("ephemeral-normal", "eph", ephemeral = true)
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

    await service.sendNow(buildTask("durable-a", "a"))
    await service.sendNow(buildTask("durable-b", "b"))
    check (await manager.quotaState()) == QuotaState.Approached

    let durable = buildTask("durable-approached", "c")
    await service.sendNow(durable)
    check:
      durable.state == DeliveryState.SuccessfullyPropagated
      manager.sentInCurrentEpoch == 3'u64

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

  asyncTest "a parked task past the max parked age fails; admitted and fresh ones stay":
    let epoch = new uint64
    epoch[] = 1'u64
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
        fixedEpochQuota(epoch, rateLimit = 100),
      )
      .expect("RateLimitManager.new")
    let processor = FakeSendProcessor(
      script: @[DeliveryState.NextRoundRetry, DeliveryState.SuccessfullyPropagated]
    )
    let service = SendService
      .new(
        false,
        waku,
        manager,
        processor,
        maxParkedAge = chronos.seconds(30),
        retryInterval = chronos.minutes(10),
      )
      .expect("SendService.new")

    let errors = new seq[MessageErrorEvent]
    listenErrors(waku.brokerCtx, errors)

    ## Admitted, still retrying, with a timestamp far older than the limit.
    let admitted = buildTask("admitted-old", "one", 1_700_000_000_000_000_000)
    await service.sendNow(admitted)
    let now = getNowInNanosecondTime()
    let stale = buildTask("parked-stale", "two", now - 60_000_000_000)
    let fresh = buildTask("parked-fresh", "three", now)
    await service.sendNow(stale)
    await service.sendNow(fresh)
    check:
      admitted.firstAdmittedTime.isSome()
      stale.firstAdmittedTime.isNone()
      fresh.firstAdmittedTime.isNone()
      stale.state == DeliveryState.FailedToDeliver
      errors[].mapIt(it.requestId) == @[stale.requestId]
      admitted.state == DeliveryState.NextRoundRetry
      fresh.state == DeliveryState.NextRoundRetry

    ## The fresh parked task is still released when the epoch rolls.
    epoch[] = 2'u64
    await service.retryAndWait(2)
    check:
      fresh.firstAdmittedTime.isSome()
      fresh.state == DeliveryState.SuccessfullyPropagated

    await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

  asyncTest "a send beyond the send queue limit is refused with no event":
    let epoch = new uint64
    epoch[] = 1'u64
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
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
        sendQueueCapacity = 2,
        retryInterval = chronos.minutes(10),
      )
      .expect("SendService.new")

    let errors = new seq[MessageErrorEvent]
    listenErrors(waku.brokerCtx, errors)

    await service.sendNow(buildTask("cap-admitted", "one"))
    await service.sendNow(buildTask("cap-parked", "two"))
    check:
      service.isFull()
      errors[].len == 0

    let rejected = buildTask("cap-rejected", "three")
    check service.enqueue(rejected).errorOr("accepted") == "Send queue full, retry later"
    check:
      errors[].len == 0 # the caller gets the error, so no event follows
      rejected.state == DeliveryState.Entry # never scheduled
      processor.calls == 1

    await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

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

    let expired = buildTask("validation-expired", "one")
    let fresh = buildTask("validation-fresh", "two")
    # The task already waited for a Store confirmation longer than the window.
    expired.storeValidationWaited = chronos.seconds(60)
    await service.sendNow(expired)
    await service.sendNow(fresh)
    check:
      expired.state == DeliveryState.FailedToDeliver
      fresh.state == DeliveryState.SuccessfullyPropagated
      await errorSeen.wait().withTimeout(chronos.seconds(1))
      errors[].mapIt(it.requestId) == @[expired.requestId]

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
        sendQueueCapacity = 1,
        maxValidationAge = chronos.seconds(30),
        retryInterval = chronos.minutes(10),
      )
      .expect("SendService.new")

    let errors = new seq[MessageErrorEvent]
    listenErrors(waku.brokerCtx, errors)
    defer:
      await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

    # The send queue holds one task, so `isFull` tells whether it holds the task.
    let task = buildTask("reliability-off", "one")
    await service.sendNow(task)
    check:
      task.state == DeliveryState.SuccessfullyPropagated
      errors[].len == 0
      not service.isFull() # the service removed the task

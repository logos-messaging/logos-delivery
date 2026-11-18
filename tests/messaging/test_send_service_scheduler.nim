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
## task exactly once however many attempts it takes, and it refuses an
## over-budget task with no event. A fake processor scripts the delivery
## outcome. Each service ticks each 10 minutes, so the tests start each next
## attempt with `retryNow`.

proc refusedAs(res: Result[void, SendError], kind: SendErrorKind): bool =
  return res.isErr() and res.error.kind == kind

type FakeSendProcessor = ref object of BaseSendProcessor
  ## Returns one trigger of `script` for each attempt, and the last entry repeats.
  ## With `noPeer`, it refuses each attempt before it starts.
  calls: int
  script: seq[Trigger]
  noPeer: bool

method checkBeforeAttempt(
    self: FakeSendProcessor, task: DeliveryTask
): Result[void, StepReport] {.gcsafe, raises: [].} =
  if self.noPeer:
    return err(StepReport.init(Trigger.NoLightpushPeer))
  return ok()

method attempt(
    self: FakeSendProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  let trigger = self.script[min(self.calls, self.script.high)]
  inc self.calls
  return StepReport.init(trigger)

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

proc epochRef(index: uint64): ref uint64 =
  let epoch = new uint64
  epoch[] = index
  return epoch

suite "SendService - rate-limit admission":
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
    ## provider only registered once the node starts. The id in the content
    ## topic gives each task its own hash.
    let msg = WakuMessage(
      contentTopic: "/test/1/" & id & "/proto",
      payload: payload.toBytes(),
      timestamp: timestamp,
      ephemeral: ephemeral,
    )
    let pubsubTopic = PubsubTopic("/waku/2/rs/3/0")
    return DeliveryTask(
      pubsubTopic: pubsubTopic,
      msg: msg,
      msgHash: computeMessageHash(pubsubTopic, msg),
      state: DeliveryState.Initial,
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

  proc newManager(
      epoch: ref uint64,
      messagesPerEpoch: uint64,
      rateLimit = 100'u64,
      remaining: ref uint64 = nil,
      approachedThresholdPercent = 0'u64,
  ): RateLimitManager =
    return RateLimitManager
      .new(
        RateLimitConfig(
          enabled: true,
          epochPeriodSec: 600,
          messagesPerEpoch: messagesPerEpoch,
          approachedThresholdPercent: approachedThresholdPercent,
        ),
        fixedEpochQuota(epoch, rateLimit, remaining),
      )
      .expect("RateLimitManager.new")

  proc newService(
      manager: RateLimitManager,
      processor: FakeSendProcessor,
      reliability = false,
      maxSendsInFlight = MaxSendsInFlight,
      maxValidationAge = StoreValidationWindow,
  ): SendService =
    return SendService
      .new(
        reliability,
        waku,
        manager,
        SendProcessors(lightpush: processor),
        maxSendsInFlight = maxSendsInFlight,
        maxValidationAge = maxValidationAge,
        retryInterval = chronos.minutes(10),
      )
      .expect("SendService.new")

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
    ## First round fails to propagate, second succeeds. The retry must not take a
    ## second charge.
    let manager = newManager(epochRef(5), messagesPerEpoch = 3)
    let processor =
      FakeSendProcessor(script: @[Trigger.ServiceUnavailable, Trigger.Published])
    let service = newService(manager, processor)

    let task = buildTask("charge-once", "hi")
    check service.enqueue(task).isOk()
    check:
      manager.sentInCurrentEpoch == 1'u64 # `enqueue` took the charge
      task.charged
    service.startSendService()
    started.add(service)
    check await service.waitAttempts(1)
    check task.state == DeliveryState.NextRoundRetry

    await service.retryAndWait(1)
    check:
      manager.sentInCurrentEpoch == 1'u64 # not charged again on the retry
      processor.calls == 2
      task.state == DeliveryState.Propagated

  asyncTest "a task that made no attempt gives its charge back":
    ## The message used no RLN message id, so the next send must not be refused.
    let manager = newManager(epochRef(5), messagesPerEpoch = 1)
    let processor = FakeSendProcessor(script: @[Trigger.Published], noPeer: true)
    let service = newService(manager, processor)
    service.maxDeliveryTime = chronos.milliseconds(1)

    let task = buildTask("charge-back", "hi")
    await service.sendNow(task)
    check:
      task.state == DeliveryState.NextRoundRetry
      manager.sentInCurrentEpoch == 1'u64

    # After the delivery window, the next round ends the task with no attempt.
    await sleepAsync(chronos.milliseconds(5))
    service.retryNow()
    checkUntilTimeout:
      task.state == DeliveryState.NotPropagated
    check:
      processor.calls == 0
      manager.sentInCurrentEpoch == 0'u64
      manager.quotaState() == QuotaState.Normal

  asyncTest "a send over the budget is refused with RateLimited and no event":
    ## An app needs the refusal as the result of `send`, with the time to wait.
    let epoch = epochRef(1)
    let manager = newManager(epoch, messagesPerEpoch = 1)
    let processor = FakeSendProcessor(script: @[Trigger.Published])
    let service = newService(manager, processor)
    let errors = new seq[MessageErrorEvent]
    listenErrors(waku.brokerCtx, errors)
    defer:
      await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

    let first = buildTask("in-budget", "one")
    await service.sendNow(first)
    check:
      first.state == DeliveryState.Propagated
      manager.sentInCurrentEpoch == 1'u64

    let second = buildTask("over-budget", "two")
    let refused = service.enqueue(second)
    check refused.refusedAs(SendErrorKind.RateLimited)
    if refused.isErr():
      check:
        refused.error.retryAfter == manager.retryAfter()
        refused.error.retryAfter > ZeroDuration
    check:
      not second.charged # no charge
      second.state == DeliveryState.Initial # never scheduled
      manager.sentInCurrentEpoch == 1'u64

    # No attempt and no event comes for the refused task.
    await service.retryAndWait(0)
    check:
      processor.calls == 1
      errors[].len == 0

    # The epoch rolls: the budget refills, and the same message is accepted.
    epoch[] = 2'u64
    await service.sendNow(second)
    check:
      manager.sentInCurrentEpoch == 1'u64 # the first charge of the new epoch
      second.state == DeliveryState.Propagated

  asyncTest "RLN's spent budget refuses a send until the epoch rolls":
    ## The local cap has room, but RLN reports the epoch's budget spent.
    let epoch = epochRef(1)
    let remaining = new uint64
    remaining[] = 0'u64
    let manager =
      newManager(epoch, messagesPerEpoch = 10, rateLimit = 10, remaining = remaining)
    let processor = FakeSendProcessor(script: @[Trigger.Published])
    let service = newService(manager, processor)

    let task = buildTask("rln-spent", "one")
    check:
      service.enqueue(task).refusedAs(SendErrorKind.RateLimited)
      manager.sentInCurrentEpoch == 0'u64

    epoch[] = 2'u64
    remaining[] = 10'u64
    await service.sendNow(task)
    check:
      task.state == DeliveryState.Propagated
      processor.calls == 1

  asyncTest "an ephemeral message is refused when the quota is approached":
    ## An ephemeral message must not use the budget left for durable messages.
    let processor = FakeSendProcessor(script: @[Trigger.Published])
    # A threshold of 50%, so half the budget spent is Approached.
    let manager =
      newManager(epochRef(1), messagesPerEpoch = 4, approachedThresholdPercent = 50)
    let service = newService(manager, processor)
    let errors = new seq[MessageErrorEvent]
    listenErrors(waku.brokerCtx, errors)
    defer:
      await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

    await service.sendNow(buildTask("durable-1", "one"))
    await service.sendNow(buildTask("durable-2", "two"))
    check manager.quotaState() == QuotaState.Approached
    let callsBefore = processor.calls

    let eph = buildTask("ephemeral-approached", "eph", ephemeral = true)
    check:
      service.enqueue(eph).refusedAs(SendErrorKind.RateLimited)
      not eph.charged # no charge, so no RLN proof either
      manager.sentInCurrentEpoch == 2'u64

    await service.retryAndWait(0)
    check:
      processor.calls == callsBefore
      errors[].len == 0

  asyncTest "an ephemeral message is refused when the quota is exhausted":
    let processor = FakeSendProcessor(script: @[Trigger.Published])
    let manager =
      newManager(epochRef(1), messagesPerEpoch = 1, approachedThresholdPercent = 50)
    let service = newService(manager, processor)

    await service.sendNow(buildTask("durable-spends", "one"))
    check manager.quotaState() == QuotaState.Exhausted

    let eph = buildTask("ephemeral-exhausted", "eph", ephemeral = true)
    check:
      service.enqueue(eph).refusedAs(SendErrorKind.RateLimited)
      manager.sentInCurrentEpoch == 1'u64

  asyncTest "an ephemeral message below the threshold is charged and sent":
    let processor = FakeSendProcessor(script: @[Trigger.Published])
    let manager =
      newManager(epochRef(1), messagesPerEpoch = 4, approachedThresholdPercent = 50)
    let service = newService(manager, processor)

    let eph = buildTask("ephemeral-normal", "eph", ephemeral = true)
    await service.sendNow(eph)
    check:
      eph.state == DeliveryState.Propagated
      eph.charged
      manager.sentInCurrentEpoch == 1'u64

  asyncTest "a durable message is still admitted when the quota is approached":
    let processor = FakeSendProcessor(script: @[Trigger.Published])
    let manager =
      newManager(epochRef(1), messagesPerEpoch = 4, approachedThresholdPercent = 50)
    let service = newService(manager, processor)

    await service.sendNow(buildTask("durable-a", "a"))
    await service.sendNow(buildTask("durable-b", "b"))
    check manager.quotaState() == QuotaState.Approached

    let durable = buildTask("durable-approached", "c")
    await service.sendNow(durable)
    check:
      durable.state == DeliveryState.Propagated
      manager.sentInCurrentEpoch == 3'u64

  asyncTest "a send over MaxSendsInFlight is refused with no event and no charge":
    let manager = newManager(epochRef(1), messagesPerEpoch = 5)
    let processor = FakeSendProcessor(script: @[Trigger.ServiceUnavailable])
    let service = newService(manager, processor, maxSendsInFlight = 2)

    let errors = new seq[MessageErrorEvent]
    listenErrors(waku.brokerCtx, errors)
    defer:
      await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

    await service.sendNow(buildTask("cap-first", "one"))
    await service.sendNow(buildTask("cap-second", "two"))
    check:
      service.isFull()
      errors[].len == 0

    let rejected = buildTask("cap-rejected", "three")
    check service.enqueue(rejected).refusedAs(SendErrorKind.QueueFull)
    check:
      errors[].len == 0 # the caller gets the error, so no event follows
      rejected.state == DeliveryState.Initial # never scheduled
      not rejected.charged # a refused message takes no charge
      manager.sentInCurrentEpoch == 2'u64
      processor.calls == 2

  asyncTest "a propagated task past the validation window fails; a fresh one stays":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let processor = FakeSendProcessor(script: @[Trigger.Published])
    let service = newService(
      manager, processor, reliability = true, maxValidationAge = chronos.seconds(30)
    )

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
      expired.state == DeliveryState.NotStored
      fresh.state == DeliveryState.AwaitingStore
      await errorSeen.wait().withTimeout(chronos.seconds(1))
      errors[].mapIt(it.messageHash) == @[expired.msgHash.to0xHex()]

  asyncTest "with reliability off a propagated task is evicted without MessageError":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let processor = FakeSendProcessor(script: @[Trigger.Published])
    let service = newService(
      manager, processor, maxSendsInFlight = 1, maxValidationAge = chronos.seconds(30)
    )

    let errors = new seq[MessageErrorEvent]
    listenErrors(waku.brokerCtx, errors)
    defer:
      await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

    # The send queue holds one task, so `isFull` tells whether it holds the task.
    let task = buildTask("reliability-off", "one")
    await service.sendNow(task)
    check:
      task.state == DeliveryState.Propagated
      errors[].len == 0
      not service.isFull() # the service removed the task

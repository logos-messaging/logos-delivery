{.used.}

import std/[importutils, sequtils, tables]
import chronos, testutils/unittests, results, stew/byteutils

import
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/rln/[rln_api, rln_plugin],
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service {.all.}, send_processor, delivery_task]
import ../testlib/[futures, testasync, wakunodeconf]

## Tests of the `deliver` of each task. A scripted processor stalls, fails or
## completes each task, and records what runs at the same time.

const PollInterval = chronos.milliseconds(5)
  ## The poll interval of `checkUntilTimeoutCustom` in this file.

const FastRetryInterval = chronos.milliseconds(10)
  ## The `retryInterval` of most tests, so a parked task retries soon.

type ScriptedProcessor = ref object of BaseSendProcessor
  ## The first call parks a task. A retry of a `stalled` task waits for its reply,
  ## a `raising` task raises, and other retries propagate the task.
  stalled: seq[string]
  raising: seq[string]
  replies: Table[string, Future[void]] ## the reply of the last stalled retry
  started: Table[string, AsyncEvent] ## fired at the first retry
  seen: seq[string] ## the order of the first calls
  running: int ## the retry calls that run now
  cancelled: seq[string]

proc startedEvent(self: ScriptedProcessor, id: string): AsyncEvent =
  if id notin self.started:
    self.started[id] = newAsyncEvent()
  return self.started.getOrDefault(id)

proc retryStarted(self: ScriptedProcessor, id: string): Future[void] =
  ## Completes when the first retry of `id` starts. Each call returns a new future.
  return self.startedEvent(id).wait()

method process(self: ScriptedProcessor, task: DeliveryTask): Future[void] {.async.} =
  let id = $task.requestId
  if id notin self.seen:
    self.seen.add(id)
    task.state = DeliveryState.NextRoundRetry
    return

  inc self.running
  defer:
    dec self.running
  self.startedEvent(id).fire()

  if id in self.raising:
    raise newException(ValueError, "scripted failure for " & id)
  if id in self.stalled:
    let reply = newFuture[void]("send-loop-reply")
    self.replies[id] = reply
    try:
      await reply
    except CancelledError as exc:
      self.cancelled.add(id)
      raise exc
  else:
    # Suspend, so the sends overlap.
    await sleepAsync(ZeroDuration)

  task.state = DeliveryState.SuccessfullyPropagated
  if task.firstPropagatedTime.isNone():
    task.firstPropagatedTime = Opt.some(Moment.now())

proc newScripted(
    stalled: seq[string] = @[], raising: seq[string] = @[]
): ScriptedProcessor =
  return ScriptedProcessor(stalled: stalled, raising: raising)

type FakePropagatingProcessor = ref object of BaseSendProcessor
  ## Propagates each task at once.
  calls: int

method isValidProcessor(
    self: FakePropagatingProcessor, task: DeliveryTask
): bool {.gcsafe.} =
  return true

method sendImpl(
    self: FakePropagatingProcessor, task: DeliveryTask
): Future[void] {.async.} =
  self.calls.inc()
  task.state = DeliveryState.SuccessfullyPropagated
  if task.firstPropagatedTime.isNone():
    task.firstPropagatedTime = Opt.some(Moment.now())

type OrderProcessor = ref object of BaseSendProcessor
  ## Parks each task at its first call and propagates it at the next one.
  ## `calls` holds the request ids in call order.
  calls: seq[string]

method process(self: OrderProcessor, task: DeliveryTask): Future[void] {.async.} =
  let id = $task.requestId
  task.state =
    if id in self.calls:
      DeliveryState.SuccessfullyPropagated
    else:
      DeliveryState.NextRoundRetry
  if task.state == DeliveryState.SuccessfullyPropagated and
      task.firstPropagatedTime.isNone():
    task.firstPropagatedTime = Opt.some(Moment.now())
  self.calls.add(id)

type HandOffProcessor = ref object of BaseSendProcessor
  ## Overrides `sendImpl`, so the base chain runs. The first call parks the task
  ## for a retry. Each later call hands it to the fallback processor, as the mix
  ## processor does for `Preferred`.
  calls: int

method isValidProcessor(self: HandOffProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: HandOffProcessor, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  task.state =
    if self.calls == 1: DeliveryState.NextRoundRetry else: DeliveryState.FallbackRetry

type StallingProcessor = ref object of BaseSendProcessor
  ## Overrides `sendImpl`, which the chain calls on each link. Each call waits on
  ## a new reply in `replies`, then propagates the task.
  replies: seq[Future[void]]

method isValidProcessor(self: StallingProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: StallingProcessor, task: DeliveryTask): Future[void] {.async.} =
  let reply = newFuture[void]("stalling-reply")
  self.replies.add(reply)
  await reply
  task.state = DeliveryState.SuccessfullyPropagated
  if task.firstPropagatedTime.isNone():
    task.firstPropagatedTime = Opt.some(Moment.now())

type RaisingProcessor = ref object of BaseSendProcessor
  calls: int

method isValidProcessor(self: RaisingProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: RaisingProcessor, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  raise newException(ValueError, "scripted fallback failure")

type OutcomeLog = ref object
  ## The request ids of the propagation and error events, in order.
  brokerCtx: BrokerContext
  propagated: seq[RequestId]
  errors: seq[RequestId]
  propagatedCount: EventCounter
  propagatedListener: MessagePropagatedEventListener
  errorListener: MessageErrorEventListener

proc waitPropagated(log: OutcomeLog, count: int): Future[void] =
  ## Completes when the log holds `count` propagation events. Each call returns a
  ## new future.
  return log.propagatedCount.waitCount(count)

proc newOutcomeLog(brokerCtx: BrokerContext): OutcomeLog =
  let log = OutcomeLog(brokerCtx: brokerCtx, propagatedCount: EventCounter())
  log.propagatedListener = MessagePropagatedEvent
    .listen(
      brokerCtx,
      proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
        log.propagated.add(event.requestId)
        log.propagatedCount.inc(),
    )
    .expect("listen propagated")
  log.errorListener = MessageErrorEvent
    .listen(
      brokerCtx,
      proc(event: MessageErrorEvent) {.async: (raises: []).} =
        log.errors.add(event.requestId),
    )
    .expect("listen error")
  return log

proc teardown(log: OutcomeLog) {.async.} =
  await MessagePropagatedEvent.dropListener(log.brokerCtx, log.propagatedListener)
  await MessageErrorEvent.dropListener(log.brokerCtx, log.errorListener)

type FakeQuotaProvider = ref object
  ## A quota provider whose reads wait for `reply` and never raise a cancel.
  reply: Future[void]
  calls: EventCounter ## the quota reads that started

proc newFakeQuotaProvider(): FakeQuotaProvider =
  return FakeQuotaProvider(reply: newFuture[void]("quota-reply"), calls: EventCounter())

proc waitCalls(quota: FakeQuotaProvider, count: int): Future[void] =
  ## Completes when `count` quota reads started. Each call returns a new future.
  return quota.calls.waitCount(count)

proc provider(quota: FakeQuotaProvider): QuotaProvider =
  return proc(): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
    quota.calls.inc()
    try:
      await quota.reply
    except CatchableError:
      discard
    return Opt.none(EpochQuota)

type SendOnErrorHook = ref object
  ## A listener that sends a new message at each error. It starts `timer` at the
  ## first error and stops when the timer ends or after `limit`.
  limit: Duration
  firstErrorAt: Moment
  timer: Future[void] ## a `sleepAsync(ZeroDuration)` from the first error
  stoppedByTimer: bool
  stoppedAt: Moment
  results: seq[Result[RequestId, string]]
  done: Future[void]

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

proc fixedEpochQuota(epoch: ref uint64, userMessageLimit: uint64): QuotaProvider =
  ## `epoch` is a ref so the test can roll the epoch without taking the
  ## address of a local.
  return proc(): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
    return Opt.some(
      EpochQuota(
        epochIndex: epoch[], rateLimit: userMessageLimit, remaining: userMessageLimit
      )
    )

suite "SendService - deliver":
  var waku {.threadvar.}: Waku
  var log {.threadvar.}: OutcomeLog

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")
    log = newOutcomeLog(waku.brokerCtx)

  asyncTeardown:
    await log.teardown()
    discard await waku.stop()

  proc buildTask(
      id: string, timestamp: Timestamp = getNowInNanosecondTime(), ephemeral = false
  ): DeliveryTask =
    ## A message from now, so a task that parks for budget is not too old.
    let msg = WakuMessage(
      contentTopic: "/test/1/send-loop/proto",
      payload: id.toBytes(),
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

  proc newService(
      processor: BaseSendProcessor,
      interval = FastRetryInterval,
      sendQueueCapacity = DefaultSendQueueCapacity,
      manager =
        RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new"),
  ): SendService =
    return SendService
      .new(
        false,
        waku,
        manager,
        processor,
        sendQueueCapacity = sendQueueCapacity,
        retryInterval = interval,
      )
      .expect("SendService.new")

  proc fakeQuotaService(
      processor: BaseSendProcessor,
      quota: FakeQuotaProvider,
      interval = FastRetryInterval,
  ): SendService =
    ## A service whose quota reads wait for the reply of `quota`, so its
    ## admissions wait too.
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 100),
        quota.provider(),
      )
      .expect("RateLimitManager.new")
    return SendService
      .new(false, waku, manager, processor, retryInterval = interval)
      .expect("SendService.new")

  proc names(prefix: string, count: int): seq[string] =
    return (0 ..< count).toSeq().mapIt(prefix & $it)

  proc admitted(processor: ScriptedProcessor, task: DeliveryTask): DeliveryTask =
    ## Marks the task as charged, and its first call as done, so its first call
    ## is a retry.
    task.firstAdmittedTime = Opt.some(Moment.now())
    processor.seen.add($task.requestId)
    return task

  asyncTest "a send that ends is reported while another send still waits":
    let processor = newScripted(stalled = @["slow"])
    let service = newService(processor)
    let slow = buildTask("slow")
    let fast = buildTask("fast")
    check:
      service.enqueue(slow).isOk()
      service.enqueue(fast).isOk()

    service.startSendService()
    defer:
      await service.stopSendService()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      log.propagated == @[fast.requestId]
      processor.running == 1 # the retry of `slow` still waits for its reply

  asyncTest "at most MaxSendsInFlight sends run at the same time":
    ## The retries of all tasks are due at the same tick. `MaxSendsInFlight` of
    ## them run, and a slot that a send frees goes to the next send.
    let ids = names("r", MaxSendsInFlight + 2)
    let processor = newScripted(stalled = ids)
    let service = newService(processor)
    for id in ids:
      check service.enqueue(buildTask(id)).isOk()

    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      processor.running == MaxSendsInFlight
    check not await processor.retryStarted(ids[^1]).withTimeout(FUTURE_TIMEOUT_SHORT)
    check:
      processor.running == MaxSendsInFlight
      ids.filterIt(processor.startedEvent(it).isSet()).len == MaxSendsInFlight

    # A new send waits for a slot too.
    check service.enqueue(buildTask("fresh")).isOk()
    check not await processor.retryStarted("fresh").withTimeout(FUTURE_TIMEOUT_SHORT)
    check "fresh" notin processor.seen

    let first = ids.filterIt(processor.startedEvent(it).isSet())[0]
    processor.replies[first].complete()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      ids.filterIt(processor.startedEvent(it).isSet()).len == MaxSendsInFlight + 1
    check processor.running == MaxSendsInFlight

  asyncTest "a send queue of one slot runs one send at a time":
    let processor = newScripted(stalled = @["a", "b"])
    let service = SendService
      .new(
        false,
        waku,
        RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new"),
        processor,
        retryInterval = FastRetryInterval,
        maxSendsInFlight = 1,
      )
      .expect("SendService.new")
    check:
      service.enqueue(buildTask("a")).isOk()
      service.enqueue(buildTask("b")).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    check await processor.retryStarted("a").withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check not await processor.retryStarted("b").withTimeout(FUTURE_TIMEOUT_SHORT)
    processor.replies["a"].complete()
    check await processor.retryStarted("b").withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)

  asyncTest "a retry with its charge and its proof sends while a new task waits in admission":
    ## The proof of the new task waits for `reply`. The retry already has its
    ## charge and its proof, so it does not wait for that admission.
    let reply = newFuture[void]("proof-reply")
    let proofCalls = new int
    proc generate(message: WakuMessage): Future[Result[seq[byte], RlnError]] {.async.} =
      proofCalls[].inc()
      await reply
      return ok(@[4'u8, 5, 6])

    waku.node.rlnPlugin = Opt.some(RlnPlugin(name: "fake", generateProof: generate))
    let processor = newScripted()
    let service = newService(processor)
    let proven = processor.admitted(buildTask("proven-retry"))
    proven.msg.proof = @[1'u8, 2, 3]
    check:
      service.enqueue(buildTask("fresh")).isOk()
      service.enqueue(buildTask("fresh-2")).isOk() # waits for the admission of `fresh`
      service.enqueue(proven).isOk()

    service.startSendService()
    defer:
      await service.stopSendService()
    check await processor.retryStarted("proven-retry").withTimeout(
      FUTURE_TIMEOUT_MEDIUM
    )
    check:
      proofCalls[] == 1 # the admission of `fresh` still waits for its proof
      "fresh" notin processor.seen
      "fresh-2" notin processor.seen

  asyncTest "one admission runs at a time":
    ## The quota read of the first admission waits for the reply of the fake
    ## provider. A task added meanwhile waits for that admission to end.
    let quota = newFakeQuotaProvider()
    let processor = newScripted()
    let service = fakeQuotaService(processor, quota, interval = chronos.minutes(10))

    check service.enqueue(buildTask("first")).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    check await quota.waitCalls(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)

    check service.enqueue(buildTask("second")).isOk()
    check not await quota.waitCalls(2).withTimeout(FUTURE_TIMEOUT_SHORT)
    check processor.seen.len == 0

    quota.reply.complete()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      processor.seen == @["first", "second"]
    check quota.calls.value == 2

  asyncTest "a task over the epoch budget parks before the processor":
    ## With a budget of one per epoch, the first task gets the budget, and the
    ## second parks before the processor.
    let epoch = new uint64
    epoch[] = 1'u64
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
        fixedEpochQuota(epoch, userMessageLimit = 100),
      )
      .expect("RateLimitManager.new")
    let processor = newScripted()
    let service = SendService
      .new(false, waku, manager, processor, retryInterval = chronos.minutes(10))
      .expect("SendService.new")

    let first = buildTask("in-budget")
    let second = buildTask("over-budget")
    check:
      service.enqueue(first).isOk()
      service.enqueue(second).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      processor.seen == @["in-budget"] and second.state == DeliveryState.NextRoundRetry
    check:
      first.firstAdmittedTime.isSome()
      second.firstAdmittedTime.isNone()
      manager.sentInCurrentEpoch == 1'u64

    service.retryNow()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      log.propagated == @[first.requestId]
      second.state == DeliveryState.NextRoundRetry
      manager.sentInCurrentEpoch == 1'u64

  asyncTest "parked tasks get the epoch budget in the order that they parked":
    ## With a budget of one per epoch, `spent` takes the budget, and `first` then
    ## `second` park. The test drives the ticks itself: a timer tick between the
    ## park of `first` and the park of `second` would park `first` again behind
    ## `second`. At the first tick the retry read of `first` rolls the epoch, but
    ## the roll lands only after both read, so both park again. The next tick
    ## wakes them in park order, and `first` gets the budget.
    privateAccess(SendService)
    let epoch = new uint64
    epoch[] = 1'u64
    let rollAtNextRead = new bool
    let quota = proc(): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
      if rollAtNextRead[]:
        rollAtNextRead[] = false
        callSoon(
          proc(udata: pointer) {.gcsafe, raises: [].} =
            epoch[] = epoch[] + 1
        )
      return Opt.some(EpochQuota(epochIndex: epoch[], rateLimit: 100, remaining: 100))
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1), quota
      )
      .expect("RateLimitManager.new")
    let service = newService(
      FakePropagatingProcessor(), interval = chronos.minutes(10), manager = manager
    )
    let spent = buildTask("spent")
    let first = buildTask("first")
    let second = buildTask("second")

    check service.enqueue(spent).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check service.enqueue(first).isOk()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      first.state == DeliveryState.NextRoundRetry
    check service.enqueue(second).isOk()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      second.state == DeliveryState.NextRoundRetry
    check service.attempts == 3

    rollAtNextRead[] = true
    service.retryNow()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      service.attempts == 5 # both read in epoch 1 and parked again
      epoch[] == 2'u64 # the roll landed after their reads
    check log.propagated == @[spent.requestId]

    service.retryNow()
    check await log.waitPropagated(2).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      log.propagated == @[spent.requestId, first.requestId]
      second.state == DeliveryState.NextRoundRetry

  asyncTest "a restart starts the tasks in queue order":
    let ids = names("q", 8)
    let processor = OrderProcessor()
    let service = newService(processor, interval = chronos.minutes(10))
    for id in ids:
      check service.enqueue(buildTask(id)).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      processor.calls.len == ids.len # each first call parks its task

    await service.stopSendService()
    service.startSendService()
    check await log.waitPropagated(ids.len).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check processor.calls[ids.len ..^ 1] == ids

  asyncTest "a task waits for the next tick of retryLoop before its next attempt":
    let processor = newScripted()
    let service = newService(processor, interval = chronos.minutes(10))
    check service.enqueue(buildTask("waits")).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      processor.seen == @["waits"] # parked by the first call
    check not await processor.retryStarted("waits").withTimeout(FUTURE_TIMEOUT_SHORT)

    service.retryNow()
    check await processor.retryStarted("waits").withTimeout(FUTURE_TIMEOUT_MEDIUM)

  asyncTest "a send that raises leaves the task for its next attempt":
    let processor = newScripted(raising = @["boom"])
    let service = newService(processor, interval = chronos.minutes(10))
    let boom = processor.admitted(buildTask("boom"))
    let fine = processor.admitted(buildTask("fine"))
    check:
      service.enqueue(boom).isOk()
      service.enqueue(fine).isOk()

    service.startSendService()
    defer:
      await service.stopSendService()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      log.propagated == @[fine.requestId]
      boom.state == DeliveryState.NextRoundRetry
      log.errors.len == 0

    processor.raising = @[]
    service.retryNow()
    check await log.waitPropagated(2).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check log.propagated == @[fine.requestId, boom.requestId]

  asyncTest "a raise in a fallback processor leaves the task for its next attempt":
    ## An exception ends `process` before it moves `FallbackRetry` to
    ## `NextRoundRetry`,
    ## so `sendUntilPropagated` moves it.
    let handOff = HandOffProcessor()
    let raising = RaisingProcessor()
    handOff.chain(raising)
    let service = newService(handOff, interval = chronos.minutes(10))
    let task = buildTask("fallback-raise")
    check service.enqueue(task).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      handOff.calls == 1 and task.state == DeliveryState.NextRoundRetry

    service.retryNow() # the fallback processor gets the task and raises
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      raising.calls == 1 and task.state == DeliveryState.NextRoundRetry

    service.retryNow()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      raising.calls == 2
    check log.errors.len == 0

  asyncTest "a listener that sends inside its handler adds one task, and the service sends it":
    ## The listener runs inside `emit`, in the `deliver` of the first task.
    let processor = FakePropagatingProcessor()
    let service = newService(processor)
    let first = buildTask("first")
    let second = buildTask("second")
    let results = new seq[Result[RequestId, string]]
    let listener = MessagePropagatedEvent
      .listen(
        waku.brokerCtx,
        proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
          if event.requestId == first.requestId:
            results[].add(service.enqueue(second))
        ,
      )
      .expect("listen")
    defer:
      await MessagePropagatedEvent.dropListener(waku.brokerCtx, listener)

    check service.enqueue(first).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    check await log.waitPropagated(2).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      results[].len == 1
      results[].allIt(it.isOk())
      processor.calls == 2
      log.propagated == @[first.requestId, second.requestId]

  asyncTest "the event loop runs while a listener sends at each error":
    ## The budget is 0, so each admission drops its ephemeral message with no
    ## suspension, and the listener sends a new message at each error. The timer
    ## of the first error ends before the listener reaches its limit only when the
    ## service returns to the event loop between the sends.
    let manager = RateLimitManager
      .new(RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 0))
      .expect("RateLimitManager.new")
    let service = SendService
      .new(false, waku, manager, FakePropagatingProcessor())
      .expect("SendService.new")
    let hook = SendOnErrorHook(
      limit: chronos.seconds(1), done: newFuture[void]("send-on-error-done")
    )
    let listener = MessageErrorEvent
      .listen(
        waku.brokerCtx,
        proc(event: MessageErrorEvent) {.async: (raises: []).} =
          if hook.done.finished():
            return
          let now = Moment.now()
          if hook.timer.isNil():
            hook.firstErrorAt = now
            hook.timer = sleepAsync(ZeroDuration)
          elif hook.timer.finished() or now - hook.firstErrorAt > hook.limit:
            hook.stoppedByTimer = hook.timer.finished()
            hook.stoppedAt = now
            hook.done.complete()
            return
          hook.results.add(
            service.enqueue(
              buildTask("on-error-" & $hook.results.len, ephemeral = true)
            )
          ),
      )
      .expect("listen")
    defer:
      await MessageErrorEvent.dropListener(waku.brokerCtx, listener)

    check service.enqueue(buildTask("on-error-start", ephemeral = true)).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    check await hook.done.withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      hook.stoppedByTimer
      hook.stoppedAt - hook.firstErrorAt < chronos.milliseconds(500)
      hook.results.allIt(it.isOk())

  asyncTest "stopping the service cancels the sends that run":
    let processor = newScripted(stalled = @["stall"])
    let service = newService(processor)
    let task = buildTask("stall")
    check service.enqueue(task).isOk()

    service.startSendService()
    check await processor.retryStarted("stall").withTimeout(FUTURE_TIMEOUT_MEDIUM)

    await service.stopSendService()
    # The stop cancels the send, and with it the wait for the reply.
    check:
      processor.cancelled == @["stall"]
      processor.replies.getOrDefault("stall").cancelled()
      log.propagated.len == 0 # no event for a cancelled send
      log.errors.len == 0

  asyncTest "a send cancelled by a stop is retried after the restart, with one terminal event":
    ## The stop cancels the send in the fallback processor, so the task is left
    ## at `FallbackRetry`. The restart starts the task again.
    let handOff = HandOffProcessor()
    let stalling = StallingProcessor()
    handOff.chain(stalling)
    let service = newService(handOff)
    let task = buildTask("cancelled-by-stop")
    check service.enqueue(task).isOk()

    service.startSendService()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      stalling.replies.len == 1
    check task.state == DeliveryState.FallbackRetry
    await service.stopSendService()
    check:
      stalling.replies[0].cancelled()
      task.state == DeliveryState.NextRoundRetry # waits for its next attempt
      log.propagated.len == 0
      log.errors.len == 0

    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      stalling.replies.len == 2
    if stalling.replies.len == 2:
      stalling.replies[1].complete()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check not await log.waitPropagated(2).withTimeout(FUTURE_TIMEOUT_SHORT)
    check:
      log.propagated == @[task.requestId]
      log.errors.len == 0

  asyncTest "a second start while the service runs changes nothing":
    privateAccess(SendService)
    let service = newService(FakePropagatingProcessor())
    service.startSendService()
    let loop = service.retryLoopHandle
    service.startSendService()
    check service.retryLoopHandle == loop
    await service.stopSendService()
    check:
      loop.cancelled()
      service.retryLoopHandle.isNil()

  asyncTest "a task queued before the start waits for the start":
    let processor = FakePropagatingProcessor()
    let service = newService(processor)
    check service.enqueue(buildTask("early")).isOk()
    check not await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_SHORT)
    check processor.calls == 0

    service.startSendService()
    defer:
      await service.stopSendService()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)

  asyncTest "enqueue returns the task of a queued message, waits while stopped, and refuses only a full send queue":
    let processor = FakePropagatingProcessor()
    let service = newService(processor, sendQueueCapacity = 2)
    let first = buildTask("first")
    let copy = DeliveryTask(
      requestId: RequestId("copy-of-first"),
      pubsubTopic: first.pubsubTopic,
      msg: first.msg, # the same message, so the same hash
      msgHash: first.msgHash,
      state: DeliveryState.Entry,
    )

    check:
      service.enqueue(first).valueOr(RequestId("refused")) == first.requestId
      service.enqueue(copy).valueOr(RequestId("refused")) == first.requestId
        # the task of `first`
      service.enqueue(buildTask("second")).isOk()
      service.isFull()
      service.enqueue(buildTask("third")).errorOr("accepted") ==
        "Send queue full, retry later"
      service.enqueue(copy).valueOr(RequestId("refused")) == first.requestId
        # a queued message gets its request id also when the send queue is full

    service.startSendService()
    check await log.waitPropagated(2).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      processor.calls == 2 # `first` and `second`
      log.propagated == @[first.requestId, RequestId("second")]

    await service.stopSendService()
    check service.enqueue(buildTask("after-stop")).isOk()
    check not await log.waitPropagated(3).withTimeout(FUTURE_TIMEOUT_SHORT)
    service.startSendService()
    defer:
      await service.stopSendService()
    check await log.waitPropagated(3).withTimeout(FUTURE_TIMEOUT_MEDIUM)

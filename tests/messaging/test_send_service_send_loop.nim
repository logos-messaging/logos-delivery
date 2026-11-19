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

func id(task: DeliveryTask): string =
  ## The name of a test task, which is its payload.
  return string.fromBytes(task.msg.payload)

func hex(task: DeliveryTask): string =
  ## The message hash of the task, as its events carry it.
  return task.msgHash.to0xHex()

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
  let id = task.id()
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

  if task.firstPropagatedTime.isNone():
    task.firstPropagatedTime = Opt.some(Moment.now())
  task.state = DeliveryState.SuccessfullyPropagated

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
  if task.firstPropagatedTime.isNone():
    task.firstPropagatedTime = Opt.some(Moment.now())
  task.state = DeliveryState.SuccessfullyPropagated

type OrderProcessor = ref object of BaseSendProcessor
  ## Parks each task at its first call and propagates it at the next one.
  ## `calls` holds the task names in call order.
  calls: seq[string]

method process(self: OrderProcessor, task: DeliveryTask): Future[void] {.async.} =
  let id = task.id()
  let propagated = id in self.calls
  self.calls.add(id)
  if not propagated:
    task.state = DeliveryState.NextRoundRetry
    return
  if task.firstPropagatedTime.isNone():
    task.firstPropagatedTime = Opt.some(Moment.now())
  task.state = DeliveryState.SuccessfullyPropagated

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
  if task.firstPropagatedTime.isNone():
    task.firstPropagatedTime = Opt.some(Moment.now())
  task.state = DeliveryState.SuccessfullyPropagated

type FailingProcessor = ref object of BaseSendProcessor
  ## Fails each task at once, with no suspension.

method isValidProcessor(self: FailingProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: FailingProcessor, task: DeliveryTask): Future[void] {.async.} =
  task.state = DeliveryState.FailedToDeliver
  task.errorDesc = "scripted failure"

type RaisingProcessor = ref object of BaseSendProcessor
  calls: int

method isValidProcessor(self: RaisingProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: RaisingProcessor, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  raise newException(ValueError, "scripted fallback failure")

type OutcomeLog = ref object
  ## The message hashes of the propagation and error events, in order.
  brokerCtx: BrokerContext
  propagated: seq[string]
  errors: seq[string]
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
        log.propagated.add(event.messageHash)
        log.propagatedCount.inc(),
    )
    .expect("listen propagated")
  log.errorListener = MessageErrorEvent
    .listen(
      brokerCtx,
      proc(event: MessageErrorEvent) {.async: (raises: []).} =
        log.errors.add(event.messageHash),
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
  return proc(
      timestamp: uint64
  ): Future[Opt[EpochQuota]] {.async: (raises: [CancelledError]), gcsafe.} =
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
  results: seq[Result[WakuMessageHash, SendError]]
  done: Future[void]

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

proc fixedEpochQuota(epoch: ref uint64, userMessageLimit: uint64): QuotaProvider =
  ## `epoch` is a ref so the test can roll the epoch without taking the
  ## address of a local.
  return proc(
      timestamp: uint64
  ): Future[Opt[EpochQuota]] {.async: (raises: [CancelledError]), gcsafe.} =
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
    ## A message from now, so its delivery window does not end in the test.
    let msg = WakuMessage(
      contentTopic: "/test/1/send-loop/proto",
      payload: id.toBytes(),
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

  proc newService(
      processor: BaseSendProcessor,
      interval = FastRetryInterval,
      maxSendsInFlight = MaxSendsInFlight,
      manager =
        RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new"),
  ): SendService =
    return SendService
      .new(
        false,
        waku,
        manager,
        processor,
        maxSendsInFlight = maxSendsInFlight,
        retryInterval = interval,
      )
      .expect("SendService.new")

  proc fakeQuotaService(
      processor: BaseSendProcessor,
      quota: FakeQuotaProvider,
      interval = FastRetryInterval,
  ): SendService =
    ## A service whose quota reads wait for the reply of `quota`. Its sends do
    ## not wait for them: they read the budget that the manager last got.
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
    processor.seen.add(task.id())
    return task

  asyncTest "a send that ends is reported while another send still waits":
    let processor = newScripted(stalled = @["slow"])
    let service = newService(processor)
    let slow = buildTask("slow")
    let fast = buildTask("fast")
    check:
      (service.enqueue(slow)).isOk()
      (service.enqueue(fast)).isOk()

    service.startSendService()
    defer:
      await service.stopSendService()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      log.propagated == @[fast.hex()]
      processor.running == 1 # the retry of `slow` still waits for its reply

  asyncTest "MaxSendsInFlight sends run at once, and the next one is refused until one ends":
    ## Each send with no last event takes a place, so all of them run at once.
    ## A send beyond the limit is refused, and a place frees at the last event.
    let ids = names("r", MaxSendsInFlight)
    let processor = newScripted(stalled = ids)
    let service = newService(processor)
    for id in ids:
      check (service.enqueue(buildTask(id))).isOk()
    let refused = service.enqueue(buildTask("over"))
    check:
      refused.isErr()
      refused.error.kind == SendErrorKind.QueueFull

    service.startSendService()
    defer:
      await service.stopSendService()
    # The first call of each task leaves it for a retry; the retries stall.
    service.retryNow()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      processor.running == MaxSendsInFlight

    processor.replies[ids[0]].complete()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      not service.isFull()
    check (service.enqueue(buildTask("after"))).isOk()

  asyncTest "a retry with its charge and its proof sends while a new task waits in admission":
    ## The proof of the new task waits for `reply`. The retry already has its
    ## charge and its proof, so it does not wait for that admission.
    let reply = newFuture[void]("proof-reply")
    let proofCalls = new int
    proc generate(message: WakuMessage): Future[Result[seq[byte], RlnError]] {.async.} =
      proofCalls[].inc()
      await reply
      return ok(@[4'u8, 5, 6])

    waku.node.rlnPlugin =
      Opt.some(RlnPlugin(name: "fake", generateProof: generate, proofSize: Opt.some(3)))
    let processor = newScripted()
    let service = newService(processor)
    let proven = processor.admitted(buildTask("proven-retry"))
    proven.msg.proof = @[1'u8, 2, 3]
    check:
      (service.enqueue(buildTask("fresh"))).isOk()
      (service.enqueue(buildTask("fresh-2"))).isOk() # waits for the admission of `fresh`
      (service.enqueue(proven)).isOk()

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

  asyncTest "a send does not wait for a budget read":
    ## The quota read of the fake provider waits for its reply. `enqueue` reads
    ## the budget that the manager last got, so it returns at once while the read
    ## runs in the background, and one read runs at a time.
    let quota = newFakeQuotaProvider()
    let processor = newScripted()
    let service = fakeQuotaService(processor, quota, interval = chronos.minutes(10))

    check:
      service.enqueue(buildTask("first")).isOk()
      service.enqueue(buildTask("second")).isOk()
    check await quota.waitCalls(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check not await quota.waitCalls(2).withTimeout(FUTURE_TIMEOUT_SHORT)
    quota.reply.complete()

    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      processor.seen == @["first", "second"]

  asyncTest "a send over the epoch budget is refused with the time to the next epoch":
    ## With a budget of one per epoch, the first send gets the budget, and the
    ## second is refused before it reaches the send queue.
    let epoch = new uint64
    epoch[] = 1'u64
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
        fixedEpochQuota(epoch, userMessageLimit = 100),
      )
      .expect("RateLimitManager.new")
    let processor = FakePropagatingProcessor()
    let service = SendService
      .new(false, waku, manager, processor, retryInterval = chronos.minutes(10))
      .expect("SendService.new")

    let first = buildTask("in-budget")
    let second = buildTask("over-budget")
    check (service.enqueue(first)).isOk()
    let refused = service.enqueue(second)
    check:
      refused.isErr()
      refused.error.kind == SendErrorKind.RateLimited
      refused.error.retryAfter > ZeroDuration
      first.firstAdmittedTime.isSome()
      second.firstAdmittedTime.isNone()
      manager.sentInCurrentEpoch == 1'u64

    service.startSendService()
    defer:
      await service.stopSendService()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check not await log.waitPropagated(2).withTimeout(FUTURE_TIMEOUT_SHORT)
    check:
      log.propagated == @[first.hex()]
      log.errors.len == 0 # a refused send gets no event
      processor.calls == 1

  asyncTest "a restart starts the tasks in queue order":
    let ids = names("q", 8)
    let processor = OrderProcessor()
    let service = newService(processor, interval = chronos.minutes(10))
    for id in ids:
      check (service.enqueue(buildTask(id))).isOk()
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
    check (service.enqueue(buildTask("waits"))).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      processor.seen == @["waits"] # parked by the first call
    check not await processor.retryStarted("waits").withTimeout(FUTURE_TIMEOUT_SHORT)

    service.retryNow()
    check await processor.retryStarted("waits").withTimeout(FUTURE_TIMEOUT_MEDIUM)

  asyncTest "the delivery window runs from the message timestamp":
    ## The message is older than the window, so the task fails with no attempt,
    ## though it was queued just now.
    let processor = newScripted()
    let service = newService(processor, interval = chronos.minutes(10))
    service.deliveryWindow = chronos.seconds(1)
    let task = buildTask(
      "stale", timestamp = getNowInNanosecondTime() - chronos.seconds(2).nanoseconds
    )
    check (service.enqueue(task)).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      log.errors == @[task.hex()]
    check:
      processor.seen.len == 0 # no attempt
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == "Unable to send within the delivery window"
      log.propagated.len == 0

  asyncTest "a send that raises leaves the task for its next attempt":
    let processor = newScripted(raising = @["boom"])
    let service = newService(processor, interval = chronos.minutes(10))
    let boom = processor.admitted(buildTask("boom"))
    let fine = processor.admitted(buildTask("fine"))
    check:
      (service.enqueue(boom)).isOk()
      (service.enqueue(fine)).isOk()

    service.startSendService()
    defer:
      await service.stopSendService()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      log.propagated == @[fine.hex()]
      boom.state == DeliveryState.NextRoundRetry
      log.errors.len == 0

    processor.raising = @[]
    service.retryNow()
    check await log.waitPropagated(2).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check log.propagated == @[fine.hex(), boom.hex()]

  asyncTest "a raise in a fallback processor leaves the task for its next attempt":
    ## An exception ends `process` before it moves `FallbackRetry` to
    ## `NextRoundRetry`,
    ## so `sendUntilPropagated` moves it.
    let handOff = HandOffProcessor()
    let raising = RaisingProcessor()
    handOff.chain(raising)
    let service = newService(handOff, interval = chronos.minutes(10))
    let task = buildTask("fallback-raise")
    check (service.enqueue(task)).isOk()
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
    let results = new seq[Result[WakuMessageHash, SendError]]
    let listener = MessagePropagatedEvent
      .listen(
        waku.brokerCtx,
        proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
          if event.messageHash == first.hex():
            results[].add(service.enqueue(second))
        ,
      )
      .expect("listen")
    defer:
      await MessagePropagatedEvent.dropListener(waku.brokerCtx, listener)

    check (service.enqueue(first)).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    check await log.waitPropagated(2).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      results[].len == 1
      results[].allIt(it.isOk())
      processor.calls == 2
      log.propagated == @[first.hex(), second.hex()]

  asyncTest "the event loop runs while a listener sends at each error":
    ## The processor fails each task with no suspension, and the listener sends a
    ## new message at each error. The timer of the first error ends before the
    ## listener reaches its limit only when the service returns to the event loop
    ## between the sends.
    let service = newService(FailingProcessor())
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
          hook.results.add(service.enqueue(buildTask("on-error-" & $hook.results.len))),
      )
      .expect("listen")
    defer:
      await MessageErrorEvent.dropListener(waku.brokerCtx, listener)

    check (service.enqueue(buildTask("on-error-start"))).isOk()
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
    check (service.enqueue(task)).isOk()

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
    check (service.enqueue(task)).isOk()

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
      log.propagated == @[task.hex()]
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
    check (service.enqueue(buildTask("early"))).isOk()
    check not await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_SHORT)
    check processor.calls == 0

    service.startSendService()
    defer:
      await service.stopSendService()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)

  asyncTest "enqueue returns the message hash, refuses a duplicate and a full send queue, and waits while stopped":
    let processor = FakePropagatingProcessor()
    let service = newService(processor, maxSendsInFlight = 2)
    let first = buildTask("first")
    let second = buildTask("second")
    let copy = DeliveryTask(
      pubsubTopic: first.pubsubTopic,
      msg: first.msg, # the same message, so the same hash
      msgHash: first.msgHash,
      state: DeliveryState.Entry,
    )

    let accepted = service.enqueue(first)
    let duplicate = service.enqueue(copy)
    check:
      accepted.isOk()
      accepted.get() == first.msgHash
      duplicate.isErr()
      duplicate.error.kind == SendErrorKind.Duplicate
      (service.enqueue(second)).isOk()
      service.isFull()

    let full = service.enqueue(buildTask("third"))
    let duplicateWhenFull = service.enqueue(copy)
    check:
      full.isErr()
      full.error.kind == SendErrorKind.QueueFull
      duplicateWhenFull.isErr()
      duplicateWhenFull.error.kind == SendErrorKind.Duplicate
        # the duplicate check comes before the capacity check

    service.startSendService()
    check await log.waitPropagated(2).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      processor.calls == 2 # `first` and `second`
      log.propagated == @[first.hex(), second.hex()]

    await service.stopSendService()
    check (service.enqueue(buildTask("after-stop"))).isOk()
    check not await log.waitPropagated(3).withTimeout(FUTURE_TIMEOUT_SHORT)
    service.startSendService()
    defer:
      await service.stopSendService()
    check await log.waitPropagated(3).withTimeout(FUTURE_TIMEOUT_MEDIUM)

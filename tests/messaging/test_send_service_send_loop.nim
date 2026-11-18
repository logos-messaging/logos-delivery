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
  logos_delivery/messaging/messaging_client {.all.},
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

method attempt(
    self: ScriptedProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  let id = $task.requestId
  if id notin self.seen:
    self.seen.add(id)
    return StepReport.init(Trigger.ServiceUnavailable)

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
  return StepReport.init(Trigger.Published)

proc newScripted(
    stalled: seq[string] = @[], raising: seq[string] = @[]
): ScriptedProcessor =
  return ScriptedProcessor(stalled: stalled, raising: raising)

type FakePropagatingProcessor = ref object of BaseSendProcessor
  ## Propagates each task at once.
  calls: int

method attempt(
    self: FakePropagatingProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  self.calls.inc()
  return StepReport.init(Trigger.Published)

type OrderProcessor = ref object of BaseSendProcessor
  ## Parks each task at its first call and propagates it at the next one.
  ## `calls` holds the request ids in call order.
  calls: seq[string]

method attempt(self: OrderProcessor, task: DeliveryTask): Future[StepReport] {.async.} =
  let id = $task.requestId
  let trigger = if id in self.calls: Trigger.Published else: Trigger.ServiceUnavailable
  self.calls.add(id)
  return StepReport.init(trigger)

type HandOffProcessor = ref object of BaseSendProcessor
  ## The mix processor of a `Preferred` service. The first call parks the task
  ## for a retry. Each later call hands it to the plain path, as the mix
  ## processor does when mix cannot take the task.
  calls: int

method attempt(
    self: HandOffProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  inc self.calls
  let trigger = if self.calls == 1: Trigger.ServiceBusy else: Trigger.MixUnavailable
  return StepReport.init(trigger)

type StallingProcessor = ref object of BaseSendProcessor
  ## Each call waits on a new reply in `replies`, then propagates the task.
  replies: seq[Future[void]]

method attempt(
    self: StallingProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  let reply = newFuture[void]("stalling-reply")
  self.replies.add(reply)
  await reply
  return StepReport.init(Trigger.Published)

type PeerLossProcessor = ref object of BaseSendProcessor
  ## A lightpush processor whose peer can go away.
  ## Each attempt waits for a reply.
  peerGone: bool
  replies: seq[Future[void]]

method checkBeforeAttempt(
    self: PeerLossProcessor, task: DeliveryTask
): Result[void, StepReport] {.gcsafe.} =
  if self.peerGone:
    return err(StepReport.init(Trigger.NoLightpushPeer))
  return ok()

method attempt(
    self: PeerLossProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  let reply = newFuture[void]("peer-loss-reply")
  self.replies.add(reply)
  await reply
  return StepReport.init(Trigger.Published)

type NoRelayPeerProcessor = ref object of BaseSendProcessor
  ## A relay processor that never has a relay peer.

method attempt(
    self: NoRelayPeerProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  return StepReport.init(Trigger.NoRelayPeers)

type ReplyProcessor = ref object of BaseSendProcessor
  ## Each attempt waits for a reply that the test gives.
  replies: seq[Future[StepReport]]

method attempt(self: ReplyProcessor, task: DeliveryTask): Future[StepReport] {.async.} =
  let reply = newFuture[StepReport]("scripted reply")
  self.replies.add(reply)
  return await reply

type SeenFlags = ref object ## The flags of a task that the listeners saw.
  propagated, queued: bool

type ZeroPeersProcessor = ref object of BaseSendProcessor
  ## A relay processor whose publish reaches no peer.

method attempt(
    self: ZeroPeersProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  return publishReport(0)

type RaisingProcessor = ref object of BaseSendProcessor
  calls: int

method attempt(
    self: RaisingProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  inc self.calls
  raise newException(ValueError, "scripted fallback failure")

type RestartingProcessor = ref object of BaseSendProcessor
  ## Reports `Started`, which only `deliver` can report.

method attempt(
    self: RestartingProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  return StepReport.init(Trigger.Started)

type SilentProcessor = ref object of BaseSendProcessor
  ## Ends its attempt with the zero value of a report.

method attempt(
    self: SilentProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  return StepReport()

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
  return proc(): Future[Opt[EpochQuota]] {.async: (raises: [CancelledError]), gcsafe.} =
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
  return proc(): Future[Opt[EpochQuota]] {.async: (raises: [CancelledError]), gcsafe.} =
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
      state: DeliveryState.Initial,
    )

  proc newService(
      processor: BaseSendProcessor,
      interval = FastRetryInterval,
      sendQueueCapacity = DefaultSendQueueCapacity,
      manager =
        RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new"),
      mix: BaseSendProcessor = nil,
  ): SendService =
    ## With `mix`, the service has the `Preferred` plan.
    let level = if mix.isNil(): AnonymityLevel.None else: AnonymityLevel.Preferred
    return SendService
      .new(
        false,
        waku,
        manager,
        SendProcessors(mix: mix, lightpush: processor),
        level,
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
      .new(
        false,
        waku,
        manager,
        SendProcessors(lightpush: processor),
        retryInterval = interval,
      )
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
        SendProcessors(lightpush: processor),
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
      .new(
        false,
        waku,
        manager,
        SendProcessors(lightpush: processor),
        retryInterval = chronos.minutes(10),
      )
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
    let quota = proc(): Future[Opt[EpochQuota]] {.
        async: (raises: [CancelledError]), gcsafe
    .} =
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

  asyncTest "a cancel of the RLN quota read is raised, and it is not a missing quota":
    ## A missing quota sends the rate limit to its wall-clock window.
    let read = newFuture[void]("rln quota read")
    proc epochQuota(timestamp: uint64): Future[Result[EpochQuota, RlnError]] {.async.} =
      await read
      return ok(EpochQuota(epochIndex: 1, rateLimit: 100, remaining: 100))

    waku.node.rlnPlugin = Opt.some(RlnPlugin(name: "fake", getEpochQuota: epochQuota))
    let quota = rlnQuotaProvider(waku)()
    check not quota.finished()
    await quota.cancelAndWait()
    check quota.cancelled()

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

  asyncTest "an attempt that waits for a send slot past the window is not made":
    let stalling = StallingProcessor()
    let service = SendService
      .new(
        false,
        waku,
        RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new"),
        SendProcessors(lightpush: stalling),
        retryInterval = FastRetryInterval,
        maxSendsInFlight = 1,
      )
      .expect("SendService.new")
    let first = service.step(buildTask("holds-the-slot"), DeliveryState.Lightpush)
    let late = buildTask("waits-for-the-slot")
    late.firstAdmittedTime =
      Opt.some(Moment.now() - DeliveryWindow + chronos.milliseconds(50))
    let second = service.step(late, DeliveryState.Lightpush)
    await sleepAsync(chronos.milliseconds(100))
    stalling.replies[0].complete()
    check:
      await second.withTimeout(FUTURE_TIMEOUT)
      second.read() == DeliveryState.NotPropagated
      late.tryCount == 0
      stalling.replies.len == 1
    discard await first

  asyncTest "the check before an attempt comes after the wait for a send slot":
    let processor = PeerLossProcessor()
    let service = SendService
      .new(
        false,
        waku,
        RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new"),
        SendProcessors(lightpush: processor),
        retryInterval = FastRetryInterval,
        maxSendsInFlight = 1,
      )
      .expect("SendService.new")
    let first = service.step(buildTask("holds-the-slot"), DeliveryState.Lightpush)
    let waiting = buildTask("waits-for-the-slot")
    let second = service.step(waiting, DeliveryState.Lightpush)
    processor.peerGone = true
    processor.replies[0].complete()
    check:
      await second.withTimeout(FUTURE_TIMEOUT)
      second.read() == DeliveryState.NextRoundRetry
      waiting.lastFailure == Opt.some(Trigger.NoLightpushPeer)
      processor.replies.len == 1
    discard await first

  asyncTest "a step that reports nothing fails the send":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService
      .new(false, waku, manager, SendProcessors(relay: SilentProcessor()))
      .expect("SendService.new")
    let task = buildTask("reports-nothing")
    check:
      (await service.step(task, DeliveryState.Relay)) == DeliveryState.NotPropagated
      task.lastReport.get().trigger == Trigger.Unreported

  asyncTest "a step that reports Started fails the send":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService
      .new(false, waku, manager, SendProcessors(relay: RestartingProcessor()))
      .expect("SendService.new")
    let task = buildTask("reports-started")
    check:
      (await service.step(task, DeliveryState.Relay)) == DeliveryState.NotPropagated
      task.lastReport.get().trigger == Trigger.Started

  asyncTest "each trigger that can fail a send has an error text":
    ## "detail" is the text that came with the trigger.
    let expected = {
      Trigger.WindowElapsed: "Unable to send within retry time window",
      Trigger.ParkedTooLong:
        "No rate-limit budget came within the maximum wait of a queued message",
      Trigger.StoreWindowElapsed:
        "Propagated but not confirmed by a store node within the store validation window",
      Trigger.TooLargeForMix: "message too large for mix: detail",
      Trigger.ProofSizeUnknown: "Failed to determine RLN proof size: detail",
      Trigger.ProofPermanent: "Failed to attach RLN proof: detail",
      Trigger.ProofBudgetExhausted: "Failed to attach RLN proof: detail",
      Trigger.EphemeralDropped: "Ephemeral message dropped: rate limit detail",
      Trigger.MixNotMounted: "mix is not mounted or knows fewer than 4 usable mix nodes",
      Trigger.MixUnavailable:
        "mix is not mounted or knows fewer than 4 usable mix nodes",
      Trigger.MixSelfHop: "this node has no address that mix can use for replies",
      Trigger.MixNoExit: "no mix node serves lightpush on the shard of the message",
      Trigger.NoRelayPeers: "No relay peer to publish the message to",
      Trigger.ZeroPeers: "No relay peer to publish the message to",
      Trigger.Rejected: "detail",
      Trigger.ProofRejected: "detail",
    }.toTable()
    for level in AnonymityLevel:
      for transports in [
        {DeliveryState.Relay},
        {DeliveryState.Lightpush},
        {DeliveryState.Relay, DeliveryState.Lightpush},
        {DeliveryState.Mix},
        {DeliveryState.Mix, DeliveryState.Lightpush},
        {DeliveryState.Mix, DeliveryState.Relay, DeliveryState.Lightpush},
      ]:
        let plan = buildDeliveryPlan(level, transports, true).valueOr:
          continue
        for transition in plan.transitions:
          if transition.toState in {
            DeliveryState.NotPropagated, DeliveryState.NotStored
          }:
            for trigger in transition.triggers:
              checkpoint($level & " " & $transports & " " & $transition)
              check:
                trigger in expected
                StepReport.init(trigger, "detail").errorText() ==
                  expected.getOrDefault(trigger)

  asyncTest "a publish that ended before a stop is kept, and it is not sent again":
    ## The stop comes in the turn in which the publish ends, before the step resumes.
    ## With reliability on, the task then waits for Store, so the restart starts it.
    let processor = ReplyProcessor()
    let service = SendService
      .new(
        true,
        waku,
        RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new"),
        SendProcessors(lightpush: processor),
        retryInterval = FastRetryInterval,
      )
      .expect("SendService.new")
    let task = buildTask("published-then-stopped")
    check service.enqueue(task).isOk()
    service.startSendService()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      processor.replies.len == 1
    processor.replies[0].complete(StepReport.init(Trigger.Published))
    await service.stopSendService()
    check:
      task.state == DeliveryState.AwaitingStore
      log.propagated == @[task.requestId]
    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      not task.storeAnswer.isNil()
    check processor.replies.len == 1

  asyncTest "a fallback that ends at a stop starts no attempt on the next transport":
    ## The report of relay is there when the stop comes, so the task moves to lightpush.
    ## The service does not run then, so `deliver` ends before that step.
    let relay = ReplyProcessor()
    let lightpush = FakePropagatingProcessor()
    let service = SendService
      .new(
        false,
        waku,
        RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new"),
        SendProcessors(relay: relay, lightpush: lightpush),
        retryInterval = FastRetryInterval,
      )
      .expect("SendService.new")
    let task = buildTask("fell-back-at-the-stop")
    check service.enqueue(task).isOk()
    service.startSendService()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      relay.replies.len == 1
    relay.replies[0].complete(StepReport.init(Trigger.NoRelayPeers))
    await service.stopSendService()
    check:
      task.state == DeliveryState.Lightpush
      lightpush.calls == 0

  asyncTest "an attempt with no reply in its timeout ends as timed out, and it is cancelled":
    let processor = ReplyProcessor()
    let service = newService(processor)
    let task = buildTask("times-out")
    let run =
      service.runAttempt(task, processor.attempt(task), chronos.milliseconds(20))
    check await run.withTimeout(FUTURE_TIMEOUT)
    check:
      run.completed() and run.read().trigger == Trigger.AttemptTimedOut
      processor.replies[0].cancelled()

  asyncTest "an attempt that ends at the cancel of its step still gives its report":
    ## The reply is there, and the attempt did not resume when the cancel comes.
    let processor = ReplyProcessor()
    let service = newService(processor)
    let task = buildTask("done-at-the-cancel")
    let run = service.runAttempt(task, processor.attempt(task))
    processor.replies[0].complete(StepReport.init(Trigger.Published))
    await run.cancelAndWait()
    check:
      run.completed()
      run.read().trigger == Trigger.Published

  asyncTest "a cancel of a step cancels an attempt that has no reply":
    let processor = ReplyProcessor()
    let service = newService(processor)
    let task = buildTask("cancelled-with-no-reply")
    let run = service.runAttempt(task, processor.attempt(task))
    await run.cancelAndWait()
    check:
      run.cancelled()
      processor.replies[0].cancelled()

  asyncTest "a listener sees its own event recorded on the task":
    let service = newService(ReplyProcessor())
    let task = buildTask("listened")
    let seen = SeenFlags()
    let onPropagated = MessagePropagatedEvent
      .listen(
        waku.brokerCtx,
        proc(e: MessagePropagatedEvent) {.async: (raises: []).} =
          seen.propagated = task.propagatedEventEmitted,
      )
      .expect("listen")
    let onQueued = MessageQueuedEvent
      .listen(
        waku.brokerCtx,
        proc(e: MessageQueuedEvent) {.async: (raises: []).} =
          seen.queued = task.queuedEventEmitted,
      )
      .expect("listen")
    defer:
      await MessagePropagatedEvent.dropListener(waku.brokerCtx, onPropagated)
      await MessageQueuedEvent.dropListener(waku.brokerCtx, onQueued)
    service.reportPropagated(task)
    service.reportQueued(task)
    check:
      seen.propagated
      seen.queued

  asyncTest "a relay-only send whose publish reaches no peer fails with an error text":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService
      .new(false, waku, manager, SendProcessors(relay: ZeroPeersProcessor()))
      .expect("SendService.new")
    let task = buildTask("relay-only-zero-peers")
    check:
      (await service.step(task, DeliveryState.Relay)) == DeliveryState.NotPropagated
      task.errorText() == "No relay peer to publish the message to"

  asyncTest "a relay-only send with no relay peer fails with an error text":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService
      .new(false, waku, manager, SendProcessors(relay: NoRelayPeerProcessor()))
      .expect("SendService.new")
    let task = buildTask("relay-only")
    check:
      (await service.step(task, DeliveryState.Relay)) == DeliveryState.NotPropagated
      task.errorText() == "No relay peer to publish the message to"

  asyncTest "a raise in a fallback processor leaves the task for its next attempt":
    let handOff = HandOffProcessor()
    let raising = RaisingProcessor()
    let service = newService(raising, interval = chronos.minutes(10), mix = handOff)
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
      .new(false, waku, manager, SendProcessors(lightpush: FakePropagatingProcessor()))
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
    ## in `Lightpush`. The restart starts a new round of the task.
    let handOff = HandOffProcessor()
    let stalling = StallingProcessor()
    let service = newService(stalling, mix = handOff)
    let task = buildTask("cancelled-by-stop")
    check service.enqueue(task).isOk()

    service.startSendService()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      stalling.replies.len == 1
    check task.state == DeliveryState.Lightpush
    await service.stopSendService()
    check:
      stalling.replies[0].cancelled()
      task.state == DeliveryState.Lightpush # the step that the stop cancelled
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
      handOff.calls == 3 # the restart starts a round at mix again

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
      state: DeliveryState.Initial,
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

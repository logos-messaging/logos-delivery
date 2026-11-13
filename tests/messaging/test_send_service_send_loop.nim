{.used.}

import std/[sequtils, tables]
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

proc id(task: DeliveryTask): string =
  ## The id that `buildTask` gave the task.
  ## It is the payload of the message.
  return string.fromBytes(task.msg.payload)

proc hashHex(task: DeliveryTask): string =
  ## The message hash as the events carry it.
  return task.msgHash.to0xHex()

type ScriptedProcessor = ref object of BaseSendProcessor
  ## A `stalled` task waits for its reply, and a `raising` task raises.
  ## Other tasks propagate.
  stalled: seq[string]
  raising: seq[string]
  replies: Table[string, Future[void]] ## the reply of each stalled send
  started: Table[string, AsyncEvent] ## fired when the send of the task starts
  calls: seq[string] ## the task ids in call order
  running: int ## the sends that run now
  cancelled: seq[string]

proc startedEvent(self: ScriptedProcessor, id: string): AsyncEvent =
  if id notin self.started:
    self.started[id] = newAsyncEvent()
  return self.started.getOrDefault(id)

proc sendStarted(self: ScriptedProcessor, id: string): Future[void] =
  ## Completes when the send of `id` starts. Each call returns a new future.
  return self.startedEvent(id).wait()

method process(self: ScriptedProcessor, task: DeliveryTask): Future[void] {.async.} =
  let id = task.id
  self.calls.add(id)
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
  task.firstPropagatedTime = Opt.some(Moment.now())

type HandOffProcessor = ref object of BaseSendProcessor
  ## Overrides `sendImpl`, so the base chain runs.
  ## Each call hands the task to the fallback processor.
  ## The mix processor does that for `Preferred`.
  calls: int

method isValidProcessor(self: HandOffProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: HandOffProcessor, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  task.state = DeliveryState.Fallback

type NoPeerProcessor = ref object of BaseSendProcessor
  ## A processor with no peer, so the chain does not call its `sendImpl`.
  checks: int

method isValidProcessor(self: NoPeerProcessor, task: DeliveryTask): bool {.gcsafe.} =
  inc self.checks
  return false

type RaisingProcessor = ref object of BaseSendProcessor
  calls: int

method isValidProcessor(self: RaisingProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: RaisingProcessor, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  raise newException(ValueError, "scripted fallback failure")

type FailingProcessor = ref object of BaseSendProcessor
  ## Fails each task at once, with no suspension.

method process(self: FailingProcessor, task: DeliveryTask): Future[void] {.async.} =
  task.state = DeliveryState.FailedToDeliver
  task.errorDesc = "scripted failure"

type OutcomeLog = ref object
  ## The message hashes of the propagation and error events, in order.
  brokerCtx: BrokerContext
  propagated: seq[string]
  errors: seq[string]
  errorEvents: seq[MessageErrorEvent]
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
        log.errors.add(event.messageHash)
        log.errorEvents.add(event),
    )
    .expect("listen error")
  return log

proc teardown(log: OutcomeLog) {.async.} =
  await MessagePropagatedEvent.dropListener(log.brokerCtx, log.propagatedListener)
  await MessageErrorEvent.dropListener(log.brokerCtx, log.errorListener)

type SendOnErrorHook = ref object
  ## A listener that sends a new message at each error. It starts `timer` at the
  ## first error and stops when the timer ends or after `limit`.
  limit: Duration
  firstErrorAt: Moment
  timer: Future[void] ## a `sleepAsync(ZeroDuration)` from the first error
  stoppedByTimer: bool
  stoppedAt: Moment
  results: seq[Result[void, SendError]]
  done: Future[void]

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

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
    ## The payload is `id`, so each id gives its own message hash.
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
      deliveryWindow = DeliveryWindow,
      maxSendsInFlight = MaxSendsInFlight,
  ): SendService =
    ## A service that runs.
    let service = SendService
      .new(
        false,
        waku,
        RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new"),
        processor,
        deliveryWindow = deliveryWindow,
        maxSendsInFlight = maxSendsInFlight,
      )
      .expect("SendService.new")
    service.startSendService()
    return service

  proc names(prefix: string, count: int): seq[string] =
    return (0 ..< count).toSeq().mapIt(prefix & $it)

  asyncTest "a send that ends is reported while another send still waits":
    let processor = newScripted(stalled = @["slow"])
    let service = newService(processor)
    defer:
      await service.stopSendService()
    let slow = buildTask("slow")
    let fast = buildTask("fast")
    check:
      service.enqueue(slow).isOk()
      service.enqueue(fast).isOk()

    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      log.propagated == @[fast.hashHex]
      processor.running == 1 # the send of `slow` still waits for its reply

  asyncTest "the service refuses a send over MaxSendsInFlight, and accepts it after a send ends":
    ## The service keeps no send that waits for its turn.
    let ids = names("r", MaxSendsInFlight)
    let processor = newScripted(stalled = ids)
    let service = newService(processor)
    defer:
      await service.stopSendService()
    for id in ids:
      check service.enqueue(buildTask(id)).isOk()

    let over = buildTask("over")
    let refused = service.enqueue(over)
    check refused.isErr()
    if refused.isErr():
      check refused.error.kind == SendErrorKind.QueueFull
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      processor.running == MaxSendsInFlight
    check "over" notin processor.calls

    processor.replies[ids[0]].complete()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check service.enqueue(over).isOk()

  asyncTest "a task with its proof sends while another task waits for its proof":
    ## The proof of `fresh` waits for `reply`.
    ## `proven` has its proof, so it does not wait for the proof of another task.
    let reply = newFuture[void]("proof-reply")
    let proofCalls = new int
    proc generate(message: WakuMessage): Future[Result[seq[byte], RlnError]] {.async.} =
      proofCalls[].inc()
      await reply
      return ok(@[4'u8, 5, 6])

    waku.node.rlnPlugin = Opt.some(RlnPlugin(name: "fake", generateProof: generate))
    let processor = newScripted()
    let service = newService(processor)
    defer:
      await service.stopSendService()
    let proven = buildTask("proven")
    proven.msg.proof = @[1'u8, 2, 3]
    check:
      service.enqueue(buildTask("fresh")).isOk()
      service.enqueue(proven).isOk()

    check await processor.sendStarted("proven").withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      proofCalls[] == 1 # `fresh` still waits for its proof
      processor.calls == @["proven"]

  asyncTest "a task that no processor propagates fails, and the service sends it one time":
    ## The service makes no second send.
    ## The app sends the message again, with a new `send`.
    let processor = NoPeerProcessor()
    let service = newService(processor)
    defer:
      await service.stopSendService()
    let task = buildTask("one-send")
    check service.enqueue(task).isOk()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      log.errors == @[task.hashHex]
    check not await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_SHORT)
    check:
      processor.checks == 1
      log.errorEvents[0].kind == MessageErrorKind.NotPropagated
      log.errorEvents[0].error == NoSendPeerReason
      # The send ended, so the same message is a new send.
      service.enqueue(task).isOk()

  asyncTest "a send with no result in the delivery window fails as NotPropagated":
    let processor = newScripted(stalled = @["no-result"])
    let service = newService(processor, deliveryWindow = chronos.milliseconds(50))
    defer:
      await service.stopSendService()
    let task = buildTask("no-result")
    check service.enqueue(task).isOk()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      log.errors == @[task.hashHex]
    check:
      log.errorEvents[0].kind == MessageErrorKind.NotPropagated
      log.errorEvents[0].error == DeliveryWindowElapsedReason
      processor.cancelled == @["no-result"] # the window ended the send
      processor.calls == @["no-result"]
      log.propagated.len == 0

  asyncTest "a send that raises fails its task and no other task":
    let processor = newScripted(raising = @["boom"])
    let service = newService(processor)
    defer:
      await service.stopSendService()
    let boom = buildTask("boom")
    let fine = buildTask("fine")
    check:
      service.enqueue(boom).isOk()
      service.enqueue(fine).isOk()

    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      log.propagated == @[fine.hashHex]
      log.errors == @[boom.hashHex]
      log.errorEvents[0].kind == MessageErrorKind.NotPropagated
      processor.calls.count("boom") == 1

  asyncTest "a raise in a fallback processor fails the task":
    let handOff = HandOffProcessor()
    let raising = RaisingProcessor()
    handOff.chain(raising)
    let service = newService(handOff)
    defer:
      await service.stopSendService()
    let task = buildTask("fallback-raise")
    check service.enqueue(task).isOk()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      log.errors == @[task.hashHex]
    check:
      handOff.calls == 1
      raising.calls == 1

  asyncTest "a listener that sends inside its handler adds one task, and the service sends it":
    ## The listener runs inside `emit`, in the `deliver` of the first task.
    let processor = FakePropagatingProcessor()
    let service = newService(processor)
    defer:
      await service.stopSendService()
    let first = buildTask("first")
    let second = buildTask("second")
    let results = new seq[Result[void, SendError]]
    let listener = MessagePropagatedEvent
      .listen(
        waku.brokerCtx,
        proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
          if event.messageHash == first.hashHex:
            results[].add(service.enqueue(second))
        ,
      )
      .expect("listen")
    defer:
      await MessagePropagatedEvent.dropListener(waku.brokerCtx, listener)

    check service.enqueue(first).isOk()
    check await log.waitPropagated(2).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      results[].len == 1
      results[].allIt(it.isOk())
      processor.calls == 2
      log.propagated == @[first.hashHex, second.hashHex]

  asyncTest "the event loop runs while a listener sends at each error":
    ## The processor fails each task with no
    ## suspension, and the listener sends a new message at each error. The timer
    ## of the first error ends before the listener reaches its limit only when the
    ## service returns to the event loop between the sends.
    let service = newService(FailingProcessor())
    defer:
      await service.stopSendService()
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

    check service.enqueue(buildTask("on-error-start")).isOk()
    check await hook.done.withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      hook.stoppedByTimer
      hook.stoppedAt - hook.firstErrorAt < chronos.milliseconds(500)
      hook.results.allIt(it.isOk())

  asyncTest "a stop cancels a send that runs and fails its task":
    ## The service keeps no task for a restart.
    let processor = newScripted(stalled = @["stall"])
    let service = newService(processor)
    let task = buildTask("stall")
    check service.enqueue(task).isOk()
    check await processor.sendStarted("stall").withTimeout(FUTURE_TIMEOUT_MEDIUM)

    await service.stopSendService()
    check:
      processor.cancelled == @["stall"]
      processor.replies.getOrDefault("stall").cancelled()
      log.propagated.len == 0
      log.errors == @[task.hashHex]
      log.errorEvents[0].kind == MessageErrorKind.NotPropagated
      log.errorEvents[0].error == ServiceStoppedReason

    # A restart sends nothing.
    service.startSendService()
    defer:
      await service.stopSendService()
    check not await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_SHORT)
    check:
      processor.calls == @["stall"]
      log.errors == @[task.hashHex]

  asyncTest "a stop before the send of a task starts fails the task, and the send never starts":
    ## `enqueue` starts the send in a later turn of the event loop.
    ## The stop waits for the send of `stall`, and `late` must not start in that wait.
    let processor = newScripted(stalled = @["stall"])
    let service = newService(processor)
    let stall = buildTask("stall")
    check service.enqueue(stall).isOk()
    check await processor.sendStarted("stall").withTimeout(FUTURE_TIMEOUT_MEDIUM)

    let late = buildTask("late")
    check service.enqueue(late).isOk()
    await service.stopSendService()
    check not await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_SHORT)
    check:
      processor.calls == @["stall"]
      log.errors.len == 2
      log.errors.count(late.hashHex) == 1
      log.errors.count(stall.hashHex) == 1
      log.errorEvents.allIt(it.error == ServiceStoppedReason)

  asyncTest "a service that does not run refuses a send":
    let processor = FakePropagatingProcessor()
    let service = newService(processor)
    await service.stopSendService()
    let refused = service.enqueue(buildTask("after-stop"))
    check:
      refused.isErr()
      refused.error.kind == SendErrorKind.Other
    check not await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_SHORT)
    check processor.calls == 0

  asyncTest "enqueue refuses a message in flight":
    let processor = newScripted(stalled = @["first"])
    let service = newService(processor)
    defer:
      await service.stopSendService()
    let first = buildTask("first")
    let copy = DeliveryTask(
      pubsubTopic: first.pubsubTopic,
      msg: first.msg, # the same message, so the same hash
      msgHash: first.msgHash,
      state: DeliveryState.Entry,
    )

    check:
      service.enqueue(first).isOk()
      service.enqueue(copy).error.kind == SendErrorKind.Duplicate
    check await processor.sendStarted("first").withTimeout(FUTURE_TIMEOUT_MEDIUM)
    processor.replies["first"].complete()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    # The send of `first` ended, so the same message is a new send.
    check service.enqueue(copy).isOk()

{.used.}

import std/sequtils
import chronos, chronicles, testutils/unittests, results, stew/byteutils

import
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service, send_processor, delivery_task]
import ../testlib/[testasync, wakunodeconf]

## The service pass sends queued tasks in batches of `MaxSendsInFlight`, and
## admits them in order. A scripted processor stalls, fails or completes each
## task on demand and records what ran at the same time.

type ScriptedProcessor = ref object of BaseSendProcessor
  ## The first `process` of a task parks it at `NextRoundRetry`, so `send()`
  ## caches it for the pass. Later calls follow the script: `stalled` tasks wait
  ## on `gate`, `raising` tasks raise, and the rest propagate at once.
  gate: Future[void]
  stalled: seq[string]
  raising: seq[string]
  seen: seq[string]
  retries: seq[string] ## order of the retry calls
  running: int
  peakRunning: int
  cancelled: seq[string]

method process(self: ScriptedProcessor, task: DeliveryTask): Future[void] {.async.} =
  let id = $task.requestId
  if id notin self.seen:
    self.seen.add(id)
    task.state = DeliveryState.NextRoundRetry
    return

  self.retries.add(id)
  inc self.running
  self.peakRunning = max(self.peakRunning, self.running)
  defer:
    dec self.running

  if id in self.raising:
    raise newException(ValueError, "scripted failure for " & id)
  if id in self.stalled:
    try:
      await self.gate
    except CancelledError as exc:
      self.cancelled.add(id)
      raise exc
  else:
    # Suspend here too, so `running` stays up until the caller starts the next
    # send and `peakRunning` measures the batch size.
    await sleepAsync(ZeroDuration)

  task.state = DeliveryState.SuccessfullyPropagated
  if task.firstPropagatedTime.isNone():
    task.firstPropagatedTime = Opt.some(Moment.now())

proc newScripted(
    stalled: seq[string] = @[], raising: seq[string] = @[]
): ScriptedProcessor =
  ScriptedProcessor(
    gate: newFuture[void]("send-loop-gate"), stalled: stalled, raising: raising
  )

type HandOffProcessor = ref object of BaseSendProcessor
  ## Overrides `sendImpl`, so the base chain runs. The first call parks the task
  ## for `send()`; each later call hands it to the fallback processor, as the mix
  ## processor does for `Preferred`.
  calls: int

method isValidProcessor(self: HandOffProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: HandOffProcessor, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  task.state =
    if self.calls == 1: DeliveryState.NextRoundRetry else: DeliveryState.FallbackRetry

type StallingProcessor = ref object of BaseSendProcessor
  ## Overrides `sendImpl`, which the chain calls on each link, and waits there on
  ## `gate`.
  gate: Future[void]
  calls: int

method isValidProcessor(self: StallingProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: StallingProcessor, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  await self.gate

type RaisingProcessor = ref object of BaseSendProcessor
  calls: int

method isValidProcessor(self: RaisingProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: RaisingProcessor, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  raise newException(ValueError, "scripted fallback failure")

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

suite "SendService - batched send pass":
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")

  asyncTeardown:
    discard await waku.stop()

  proc buildTask(id: string): DeliveryTask =
    let msg = WakuMessage(
      contentTopic: "/test/1/send-loop/proto",
      payload: id.toBytes(),
      timestamp: 1_700_000_000_000_000_000,
    )
    let pubsubTopic = PubsubTopic("/waku/2/rs/3/0")
    return DeliveryTask(
      requestId: RequestId(id),
      pubsubTopic: pubsubTopic,
      msg: msg,
      msgHash: computeMessageHash(pubsubTopic, msg),
      state: DeliveryState.Entry,
    )

  proc newService(processor: ScriptedProcessor): SendService =
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    return SendService.new(false, waku, manager, processor).expect("SendService.new")

  proc names(prefix: string, count: int): seq[string] =
    return (0 ..< count).toSeq().mapIt(prefix & $it)

  proc queue(service: SendService, tasks: seq[DeliveryTask]) {.async.} =
    ## `send()` parks each task in the cache (the processor's first call).
    for task in tasks:
      await service.send(task)
      check task.state == DeliveryState.NextRoundRetry

  asyncTest "a send that waits on its reply does not hold the other queued sends":
    let processor = newScripted(stalled = @["a"])
    let service = newService(processor)
    let a = buildTask("a")
    let b = buildTask("b")
    let c = buildTask("c")
    await service.queue(@[a, b, c])

    let pass = service.trySendMessages()
    await sleepAsync(chronos.milliseconds(50))
    check:
      not pass.finished()
      a.state == DeliveryState.NextRoundRetry # still waiting on its reply
      b.state == DeliveryState.SuccessfullyPropagated
      c.state == DeliveryState.SuccessfullyPropagated
      processor.peakRunning >= 2

    processor.gate.complete()
    await pass
    check a.state == DeliveryState.SuccessfullyPropagated

  asyncTest "a pass starts at most MaxSendsInFlight sends before waiting for them":
    let ids = names("t", MaxSendsInFlight + 1)
    let processor = newScripted(stalled = ids)
    let service = newService(processor)
    await service.queue(ids.mapIt(buildTask(it)))

    let pass = service.trySendMessages()
    await sleepAsync(chronos.milliseconds(50))
    check:
      processor.retries == ids[0 ..< MaxSendsInFlight] # the last waits for the batch
      processor.peakRunning == MaxSendsInFlight

    processor.gate.complete()
    await pass
    check:
      processor.retries == ids
      processor.peakRunning == MaxSendsInFlight

  asyncTest "admission stays sequential and in order":
    ## With a budget of one per epoch, the pass sends the first task and parks the
    ## second before the processor, whatever the batch size.
    let epoch = new uint64
    epoch[] = 1'u64
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
        fixedEpochQuota(epoch, userMessageLimit = 100),
      )
      .expect("RateLimitManager.new")
    let processor = newScripted()
    let service =
      SendService.new(false, waku, manager, processor).expect("SendService.new")

    let first = buildTask("in-budget")
    let second = buildTask("over-budget")
    await service.send(first) # admitted, parked by the processor's first call
    check:
      first.firstAdmittedTime.isSome()
      manager.sentInCurrentEpoch == 1'u64
    await service.send(second) # over budget, parked before the processor
    check:
      manager.sentInCurrentEpoch == 1'u64
      second.firstAdmittedTime.isNone()

    await service.trySendMessages()
    check:
      processor.retries == @["in-budget"]
      first.state == DeliveryState.SuccessfullyPropagated
      second.state == DeliveryState.NextRoundRetry

  asyncTest "a send that raises does not end the pass":
    let processor = newScripted(raising = @["boom"])
    let service = newService(processor)
    let boom = buildTask("boom")
    let fine = buildTask("fine")
    await service.queue(@[boom, fine])

    await service.trySendMessages()
    check:
      fine.state == DeliveryState.SuccessfullyPropagated
      boom.state == DeliveryState.NextRoundRetry # left for the next round

    # The service keeps working: the next pass retries the failed task.
    processor.raising = @[]
    await service.trySendMessages()
    check boom.state == DeliveryState.SuccessfullyPropagated

  asyncTest "stopping the service cancels the sends still in flight":
    let processor = newScripted(stalled = @["stall"])
    let service = newService(processor)
    await service.queue(@[buildTask("stall")])

    service.startSendService()
    await sleepAsync(chronos.milliseconds(50))
    check processor.retries == @["stall"]

    await service.stopSendService()
    # The stop cancels the send, and with it the wait on `gate`.
    check:
      processor.cancelled == @["stall"]
      processor.gate.cancelled()

  asyncTest "stopping the service cancels a pass started directly":
    ## A pass that waits on its batch empties `inFlight` when its cancelled send
    ## finishes, inside the stop's own wait, so the stop takes the batch first.
    let processor = newScripted(stalled = @["s"])
    let service = newService(processor)
    await service.queue(@[buildTask("s")])

    let pass = service.trySendMessages() # parks on its batch
    await sleepAsync(chronos.milliseconds(50))
    check not pass.finished()

    await service.stopSendService()
    # The stop cancelled the batch, so this pass ends; the time limit turns a hang
    # into a failure.
    check await pass.withTimeout(chronos.seconds(2))
    check processor.cancelled == @["s"]

  asyncTest "a raise in send() is caught, not handed to asyncSpawn":
    ## Chronos turns a failed spawned future into a `FutureDefect` that ends the
    ## process, so `send` catches the raise and keeps the task for the next round.
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let processor = RaisingProcessor()
    let service =
      SendService.new(false, waku, manager, processor).expect("SendService.new")

    let task = buildTask("raise-in-send")
    let fut = service.send(task)
    check await fut.withTimeout(chronos.seconds(2))

    check:
      not fut.failed() # the raise never reaches the spawn
      processor.calls == 1
      task.state == DeliveryState.NextRoundRetry

  asyncTest "a stop ends a directly driven pass, not only its batch":
    ## After the stop cancels the batch, a directly driven pass resumes with tasks
    ## left in its list, and must not start them.
    let ids = names("s", 2 * MaxSendsInFlight)
    let processor = newScripted(stalled = ids)
    let service = newService(processor)
    await service.queue(ids.mapIt(buildTask(it)))

    let pass = service.trySendMessages() # parks on the first batch
    await sleepAsync(chronos.milliseconds(50))
    check processor.retries == ids[0 ..< MaxSendsInFlight]

    await service.stopSendService()
    check await pass.withTimeout(chronos.seconds(2))
    check processor.retries == ids[0 ..< MaxSendsInFlight] # the rest never started

  asyncTest "a raise in a fallback processor still leaves the task for the next round":
    ## A raise skips the tail of `process` that moves a hand-off to
    ## `NextRoundRetry`, so the drain must move the task out of `FallbackRetry`.
    let handOff = HandOffProcessor()
    let raising = RaisingProcessor()
    handOff.chain(raising)
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service =
      SendService.new(false, waku, manager, handOff).expect("SendService.new")
    let task = buildTask("fallback-raise")
    await service.send(task) # parked by the first call
    check task.state == DeliveryState.NextRoundRetry

    await service.trySendMessages() # the hand-off, then the fallback raises
    check:
      raising.calls == 1
      task.state == DeliveryState.NextRoundRetry # left for the next round

    await service.trySendMessages()
    check raising.calls == 2 # ... and the next round did retry it

  asyncTest "a stop normalises a task its cancel left at FallbackRetry":
    ## A cancel skips the tail of `process`, and the drain of the owning pass sees
    ## an empty batch, so the stop must move the task out of `FallbackRetry`.
    let handOff = HandOffProcessor()
    let stalling = StallingProcessor(gate: newFuture[void]("stop-normalise"))
    handOff.chain(stalling)
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service =
      SendService.new(false, waku, manager, handOff).expect("SendService.new")
    let task = buildTask("stop-normalise")
    await service.send(task) # parked by the first call
    check task.state == DeliveryState.NextRoundRetry

    let pass = service.trySendMessages() # hands off, then parks in the chain
    await sleepAsync(chronos.milliseconds(50))
    check task.state == DeliveryState.FallbackRetry

    await service.stopSendService()
    check await pass.withTimeout(chronos.seconds(2))
    check task.state == DeliveryState.NextRoundRetry

  asyncTest "a send cancelled during a stop is put back and retried after the restart":
    ## `send()` puts a cancelled task back in the cache, also during a stop, and
    ## the next start sends it. The request id then still gets a terminal event.
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let stalling = StallingProcessor(gate: newFuture[void]("never-replied"))
    let service =
      SendService.new(false, waku, manager, stalling).expect("SendService.new")

    let task = buildTask("cancelled-in-send")
    let fut = service.send(task)
    await sleepAsync(chronos.milliseconds(50))
    check stalling.calls == 1

    await service.stopSendService()
    await fut.cancelAndWait()
    check:
      fut.completed() # neither failed nor cancelled: nothing reaches the spawn
      task.state == DeliveryState.NextRoundRetry

    service.startSendService() # the loop's first pass picks it up again
    await sleepAsync(chronos.milliseconds(50))
    check stalling.calls == 2
    await service.stopSendService()

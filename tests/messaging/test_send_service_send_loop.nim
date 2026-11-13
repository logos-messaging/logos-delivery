{.used.}

import std/[sequtils, sets]
import chronos, testutils/unittests, results, stew/byteutils, libp2p/peerid

import
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/rln/[rln_api, rln_plugin],
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service, transports, delivery_task]
import ../testlib/[fake_transport, futures, testasync, wakucore, wakunodeconf]

## Tests of the `deliver` of each task of `send`. Fake transports stall, fail or
## propagate each attempt, and record when each attempt starts.

const PollInterval = chronos.milliseconds(5)
  ## The poll interval of `checkUntilTimeoutCustom` in this file.

const ShortInterval = chronos.milliseconds(40)
  ## The attempt interval of a test that waits for more than one attempt.

const LongInterval = chronos.minutes(1)
  ## The attempt interval of a test in which an attempt must not end by itself.

const TimerSlack = chronos.milliseconds(5)

proc hashHex(task: DeliveryTask): string =
  ## The message hash as the events carry it.
  return task.msgHash.to0xHex()

type OutcomeLog = ref object
  ## The message hashes of the propagation and error events, in order.
  brokerCtx: BrokerContext
  propagated: seq[string]
  errors: seq[string]
  errorEvents: seq[MessageErrorEvent]
  propagatedCount: EventCounter
  errorCount: EventCounter
  propagatedListener: MessagePropagatedEventListener
  errorListener: MessageErrorEventListener

proc waitPropagated(log: OutcomeLog, count: int): Future[void] =
  ## Completes when the log holds `count` propagation events. Each call returns a
  ## new future.
  return log.propagatedCount.waitCount(count)

proc waitErrors(log: OutcomeLog, count: int): Future[void] =
  return log.errorCount.waitCount(count)

proc newOutcomeLog(brokerCtx: BrokerContext): OutcomeLog =
  let log = OutcomeLog(
    brokerCtx: brokerCtx, propagatedCount: EventCounter(), errorCount: EventCounter()
  )
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
        log.errorEvents.add(event)
        log.errorCount.inc(),
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

  const Shard = PubsubTopic("/waku/2/rs/3/0")

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
    return DeliveryTask(
      pubsubTopic: Shard,
      msg: msg,
      msgHash: computeMessageHash(Shard, msg),
      state: DeliveryState.Entry,
    )

  proc newService(
      transports: Transports,
      attemptInterval = LongInterval,
      anonymityLevel = AnonymityLevel.None,
      maxSendsInFlight = MaxSendsInFlight,
      reliability = false,
      maxValidationAge = StoreValidationWindow,
  ): SendService =
    ## A service that runs.
    let service = SendService
      .new(
        reliability,
        waku,
        RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new"),
        transports,
        anonymityLevel = anonymityLevel,
        attemptInterval = attemptInterval,
        maxValidationAge = maxValidationAge,
        storeValidationInterval = chronos.milliseconds(10),
        maxSendsInFlight = maxSendsInFlight,
      )
      .expect("SendService.new")
    service.startSendService()
    return service

  proc names(prefix: string, count: int): seq[string] =
    return (0 ..< count).toSeq().mapIt(prefix & $it)

  proc countingRln(): ref int =
    ## Mounts an RLN backend that counts the proofs that it makes.
    let proofs = new int
    proc generate(message: WakuMessage): Future[Result[seq[byte], RlnError]] {.async.} =
      proofs[].inc()
      return ok(@[4'u8, 5, 6])

    waku.node.rlnPlugin = Opt.some(RlnPlugin(name: "fake", generateProof: generate))
    return proofs

  proc count(counter: ref int): int =
    return counter[]

  asyncTest "a send that ends is reported while another send still waits":
    let relay = FakeTransport.new(stalled = @["slow"])
    let service = newService(transportsOf((Transport.Relay, relay)))
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
      relay.running == 1 # the attempt of `slow` still waits for its answer

  asyncTest "the service refuses a send over MaxSendsInFlight, and accepts it after a send ends":
    ## The service keeps no send that waits for its turn.
    let ids = names("r", MaxSendsInFlight)
    let relay = FakeTransport.new(stalled = ids)
    let service = newService(transportsOf((Transport.Relay, relay)))
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
      relay.running == MaxSendsInFlight
    check "over" notin relay.calls

    relay.reply(ids[0])
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
    let relay = FakeTransport.new()
    let service = newService(transportsOf((Transport.Relay, relay)))
    defer:
      await service.stopSendService()
    let proven = buildTask("proven")
    proven.msg.proof = @[1'u8, 2, 3]
    check:
      service.enqueue(buildTask("fresh")).isOk()
      service.enqueue(proven).isOk()

    check await relay.attemptStarted("proven").withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      proofCalls.count == 1 # `fresh` still waits for its proof
      relay.calls == @["proven"]

  asyncTest "a message that no attempt propagates gets MaxSendAttempts attempts, one each interval":
    ## A transport can propagate a message that it could not propagate some seconds before.
    let relay = FakeTransport.new(results = @[AttemptResult.notPropagated("scripted")])
    let service = newService(
      transportsOf((Transport.Relay, relay)), attemptInterval = ShortInterval
    )
    defer:
      await service.stopSendService()
    let task = buildTask("four-attempts")
    check service.enqueue(task).isOk()
    check await log.waitErrors(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check not await relay.attempts.waitCount(MaxSendAttempts + 1).withTimeout(
      ShortInterval * 2
    )
    check:
      relay.calls.len == MaxSendAttempts
      log.errors == @[task.hashHex]
      log.errorEvents[0].kind == MessageErrorKind.NotPropagated
      log.errorEvents[0].error == "scripted"
      log.propagated.len == 0
      # The send ended, so the same message is a new send.
      service.enqueue(task).isOk()
    if relay.times.len == MaxSendAttempts:
      for index in 1 ..< MaxSendAttempts:
        check relay.times[index] - relay.times[0] >= ShortInterval * index - TimerSlack

  asyncTest "an attempt that propagates is the last attempt":
    let relay = FakeTransport.new(
      results = @[AttemptResult.notPropagated("scripted"), AttemptResult.propagated()]
    )
    let service = newService(
      transportsOf((Transport.Relay, relay)), attemptInterval = ShortInterval
    )
    defer:
      await service.stopSendService()
    let task = buildTask("second-attempt")
    check service.enqueue(task).isOk()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check not await relay.attempts.waitCount(3).withTimeout(ShortInterval * 3)
    check:
      relay.calls.len == 2
      log.propagated == @[task.hashHex]
      log.errors.len == 0

  asyncTest "an Invalid attempt fails the task with no other attempt":
    let relay = FakeTransport.new(results = @[AttemptResult.invalid("scripted")])
    let lightpush = FakeTransport.new()
    let service = newService(
      transportsOf((Transport.Relay, relay), (Transport.Lightpush, lightpush)),
      attemptInterval = ShortInterval,
    )
    defer:
      await service.stopSendService()
    let task = buildTask("invalid")
    check service.enqueue(task).isOk()
    check await log.waitErrors(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check not await lightpush.attempts.waitCount(1).withTimeout(ShortInterval * 3)
    check:
      relay.calls.len == 1
      lightpush.calls.len == 0
      log.errorEvents[0].kind == MessageErrorKind.NotPropagated
      log.errorEvents[0].error == "scripted"

  asyncTest "a transport that cannot carry the message gets no attempt, and the next transport gets each one":
    let relay =
      FakeTransport.new(checkResult = Opt.some(AttemptResult.invalid("scripted")))
    let lightpush = FakeTransport.new(results = @[AttemptResult.notPropagated()])
    let service = newService(
      transportsOf((Transport.Relay, relay), (Transport.Lightpush, lightpush)),
      attemptInterval = ShortInterval,
    )
    defer:
      await service.stopSendService()
    let task = buildTask("invalid-for-relay")
    check service.enqueue(task).isOk()
    check await log.waitErrors(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      relay.calls.len == 0
      lightpush.calls.len == MaxSendAttempts

  asyncTest "a task fails at once when no transport can carry the message":
    let relay =
      FakeTransport.new(checkResult = Opt.some(AttemptResult.invalid("scripted")))
    let service = newService(transportsOf((Transport.Relay, relay)))
    defer:
      await service.stopSendService()
    let task = buildTask("no-transport")
    check service.enqueue(task).isOk()
    check await log.waitErrors(1).withTimeout(FUTURE_TIMEOUT)
    check:
      relay.calls.len == 0
      log.errorEvents[0].kind == MessageErrorKind.NotPropagated
      log.errorEvents[0].error == "scripted"

  asyncTest "an attempt with no answer ends at the end of its interval, and the next attempt starts":
    let relay = FakeTransport.new(stalled = @["no-answer"])
    let service = newService(
      transportsOf((Transport.Relay, relay)), attemptInterval = ShortInterval
    )
    defer:
      await service.stopSendService()
    let task = buildTask("no-answer")
    check service.enqueue(task).isOk()
    check await log.waitErrors(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      relay.calls.len == MaxSendAttempts
      relay.cancelled.len == MaxSendAttempts
      log.errorEvents[0].kind == MessageErrorKind.NotPropagated
      log.errorEvents[0].error == SendWindowElapsedReason
      log.propagated.len == 0

  test "the first transport gets the first half of the attempts":
    const R = Transport.Relay
    const L = Transport.Lightpush
    const M = Transport.Mix
    check:
      attemptPlan([R, L], 4) == @[R, R, L, L]
      attemptPlan([L], 4) == @[L, L, L, L]
      attemptPlan([R], 4) == @[R, R, R, R]
      attemptPlan([M], 4) == @[M, M, M, M]
      attemptPlan([M, R, L], 4) == @[M, M, R, L]
      attemptPlan([M, L], 4) == @[M, M, L, L]

  asyncTest "a relay that reaches no peer gets two attempts, and lightpush gets the last two":
    ## One attempt uses one transport.
    let relay = FakeTransport.new(results = @[AttemptResult.notPropagated()])
    let lightpush = FakeTransport.new(results = @[AttemptResult.notPropagated()])
    let service = newService(
      transportsOf((Transport.Relay, relay), (Transport.Lightpush, lightpush)),
      attemptInterval = ShortInterval,
    )
    defer:
      await service.stopSendService()
    let task = buildTask("relay-relay-lightpush-lightpush")
    check service.enqueue(task).isOk()
    check await log.waitErrors(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      relay.calls.len == 2
      lightpush.calls.len == 2
      log.errorEvents[0].kind == MessageErrorKind.NotPropagated
    if relay.times.len == 2 and lightpush.times.len == 2:
      check:
        relay.times[1] - relay.times[0] >= ShortInterval - TimerSlack
        lightpush.times[0] - relay.times[1] >= ShortInterval - TimerSlack
        lightpush.times[1] - lightpush.times[0] >= ShortInterval - TimerSlack

  asyncTest "after relay propagates, the next attempts go to lightpush while no Store node confirms":
    ## The peers of the relay drop a second publish of the message, so a second
    ## relay attempt reaches no Store node. A lightpush service node can.
    let relay = FakeTransport.new()
    let lightpush = FakeTransport.new()
    let service = newService(
      transportsOf((Transport.Relay, relay), (Transport.Lightpush, lightpush)),
      attemptInterval = ShortInterval,
      reliability = true,
      maxValidationAge = ShortInterval * 6,
    )
    defer:
      await service.stopSendService()
    let task = buildTask("relay-then-lightpush")
    check service.enqueue(task).isOk()
    check await log.waitErrors(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      relay.calls.len == 1
      lightpush.calls.len == 3
      log.propagated == @[task.hashHex]
      log.errorEvents[0].kind == MessageErrorKind.NotStored

  asyncTest "a relay-only node publishes one time, and then only waits for a Store node":
    let relay = FakeTransport.new()
    let service = newService(
      transportsOf((Transport.Relay, relay)),
      attemptInterval = ShortInterval,
      reliability = true,
      maxValidationAge = ShortInterval * 6,
    )
    defer:
      await service.stopSendService()
    let task = buildTask("relay-only")
    check service.enqueue(task).isOk()
    check await log.waitErrors(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      relay.calls.len == 1
      log.propagated == @[task.hashHex]
      log.errorEvents[0].kind == MessageErrorKind.NotStored

  asyncTest "a Store answer in the time of an attempt ends the send with no other attempt":
    let relay = FakeTransport.new()
    let lightpush = FakeTransport.new()
    let service = newService(
      transportsOf((Transport.Relay, relay), (Transport.Lightpush, lightpush)),
      reliability = true,
    )
    defer:
      await service.stopSendService()
    let sent = EventCounter()
    let listener = MessageSentEvent
      .listen(
        waku.brokerCtx,
        proc(event: MessageSentEvent) {.async: (raises: []).} =
          sent.inc(),
      )
      .expect("listen sent")
    defer:
      await MessageSentEvent.dropListener(waku.brokerCtx, listener)

    let task = buildTask("confirmed-in-first-attempt")
    check service.enqueue(task).isOk()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      task.awaitsStore()
    # The Store validation loop does this when a Store node reports the message.
    task.confirmed = true
    task.storeAnswer.complete()

    check await sent.waitCount(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      relay.calls.len == 1
      lightpush.calls.len == 0
      log.propagated == @[task.hashHex]
      log.errors.len == 0

  asyncTest "a message that relay propagates does not go to lightpush":
    let relay = FakeTransport.new()
    let lightpush = FakeTransport.new()
    let service = newService(
      transportsOf((Transport.Relay, relay), (Transport.Lightpush, lightpush))
    )
    defer:
      await service.stopSendService()
    check service.enqueue(buildTask("relay-only")).isOk()
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      relay.calls == @["relay-only"]
      lightpush.calls.len == 0

  asyncTest "a send with no lightpush peer is accepted, and the message propagates when a peer comes":
    ## A node with no peer can get one in the next seconds, as after a network outage.
    ## The message gets its RLN proof only when lightpush can take it.
    let proofs = countingRln()
    let lightpush =
      FakeTransport.new(checkResult = Opt.some(AttemptResult.notPropagated()))
    let service = newService(
      transportsOf((Transport.Lightpush, lightpush)), attemptInterval = ShortInterval
    )
    defer:
      await service.stopSendService()
    let task = buildTask("peer-comes")
    check service.enqueue(task).isOk()
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      lightpush.checks > 0
    check:
      lightpush.calls.len == 0
      proofs.count == 0

    lightpush.checkResult = Opt.none(AttemptResult)
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      lightpush.calls == @["peer-comes"]
      proofs.count == 1
      log.errors.len == 0

  asyncTest "a message that never has a lightpush peer fails as NotPropagated after its last attempt":
    let lightpush =
      FakeTransport.new(checkResult = Opt.some(AttemptResult.notPropagated()))
    let service = newService(
      transportsOf((Transport.Lightpush, lightpush)), attemptInterval = ShortInterval
    )
    defer:
      await service.stopSendService()
    let started = Moment.now()
    let task = buildTask("no-peer")
    check service.enqueue(task).isOk()
    check await log.waitErrors(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      Moment.now() - started >= ShortInterval * (MaxSendAttempts - 1) - TimerSlack
      lightpush.calls.len == 0
      log.errorEvents[0].kind == MessageErrorKind.NotPropagated
      log.errorEvents[0].error == SendWindowElapsedReason

  asyncTest "each relay attempt after the first tells the relay that it validated the message":
    ## The RLN validator of a node refuses a proof that it already has.
    ## So the relay of the node validates a message one time.
    let relay = FakeTransport.new(
      results = @[AttemptResult(outcome: AttemptOutcome.NotPropagated, validated: true)]
    )
    let service = newService(
      transportsOf((Transport.Relay, relay)), attemptInterval = ShortInterval
    )
    defer:
      await service.stopSendService()
    check service.enqueue(buildTask("validated-once")).isOk()
    check await log.waitErrors(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check relay.validated == @[false, true, true, true]

  asyncTest "each lightpush attempt goes to a peer that got no attempt of the message":
    ## A lightpush peer that does not propagate a message can fail the next attempt also.
    var known: HashSet[PeerId]
    for port in [60501, 60502]:
      let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
      known.incl(peerId)
      waku.node.peerManager.addPeer(
        RemotePeerInfo.init(
          peerId,
          @[MultiAddress.init("/ip4/127.0.0.1/tcp/" & $port).tryGet()],
          protocols = @[WakuLightPushCodec],
          shards = @[0'u16],
        )
      )
      waku.node.peerManager.switch.peerStore.setShardInfo(peerId, @[0'u16])
    let lightpush =
      FakeTransport.new(results = @[AttemptResult.notPropagated("scripted")])
    let service = newService(
      transportsOf((Transport.Lightpush, lightpush)), attemptInterval = ShortInterval
    )
    defer:
      await service.stopSendService()
    check service.enqueue(buildTask("two-peers")).isOk()
    check await log.waitErrors(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check lightpush.peers.len == MaxSendAttempts
    if lightpush.peers.len == MaxSendAttempts:
      check:
        lightpush.peers.allIt(it.len == 1)
        lightpush.peers[0 .. 1].mapIt(it[0].peerId).toHashSet() == known

  asyncTest "a listener that sends inside its handler adds one task, and the service sends it":
    ## The listener runs inside `emit`, in the `deliver` of the first task.
    let relay = FakeTransport.new()
    let service = newService(transportsOf((Transport.Relay, relay)))
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
      relay.calls == @["first", "second"]
      log.propagated == @[first.hashHex, second.hashHex]

  asyncTest "the event loop runs while a listener sends at each error":
    ## The transport fails each task with no suspension, and the listener sends a
    ## new message at each error. The timer of the first error ends before the
    ## listener reaches its limit only when the service returns to the event loop
    ## between the sends.
    let relay =
      FakeTransport.new(checkResult = Opt.some(AttemptResult.invalid("scripted")))
    let service = newService(transportsOf((Transport.Relay, relay)))
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

  asyncTest "a stop cancels an attempt that runs and fails its task":
    ## The service keeps no task for a restart.
    let relay = FakeTransport.new(stalled = @["stall"])
    let service = newService(transportsOf((Transport.Relay, relay)))
    let task = buildTask("stall")
    check service.enqueue(task).isOk()
    check await relay.attemptStarted("stall").withTimeout(FUTURE_TIMEOUT_MEDIUM)

    await service.stopSendService()
    check:
      relay.cancelled == @["stall"]
      log.propagated.len == 0
      log.errors == @[task.hashHex]
      log.errorEvents[0].kind == MessageErrorKind.NotPropagated
      log.errorEvents[0].error == ServiceStoppedReason

    # A restart sends nothing.
    service.startSendService()
    defer:
      await service.stopSendService()
    check not await relay.attempts.waitCount(2).withTimeout(FUTURE_TIMEOUT_SHORT)
    check:
      relay.calls == @["stall"]
      log.errors == @[task.hashHex]

  asyncTest "a stop in the wait for the next attempt fails the task":
    let relay = FakeTransport.new(results = @[AttemptResult.notPropagated("scripted")])
    let service = newService(transportsOf((Transport.Relay, relay)))
    let task = buildTask("between-attempts")
    check service.enqueue(task).isOk()
    check await relay.attempts.waitCount(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, PollInterval):
      relay.running == 0

    await service.stopSendService()
    check:
      relay.calls.len == 1
      log.errors == @[task.hashHex]
      log.errorEvents[0].kind == MessageErrorKind.NotPropagated
      log.errorEvents[0].error == ServiceStoppedReason

  asyncTest "a stop before the send of a task starts fails the task, and the send never starts":
    ## `enqueue` starts the send in a later turn of the event loop.
    ## The stop waits for the attempt of `stall`, and `late` must not start in that wait.
    let relay = FakeTransport.new(stalled = @["stall"])
    let service = newService(transportsOf((Transport.Relay, relay)))
    let stall = buildTask("stall")
    check service.enqueue(stall).isOk()
    check await relay.attemptStarted("stall").withTimeout(FUTURE_TIMEOUT_MEDIUM)

    let late = buildTask("late")
    check service.enqueue(late).isOk()
    await service.stopSendService()
    check not await relay.attempts.waitCount(2).withTimeout(FUTURE_TIMEOUT_SHORT)
    check:
      relay.calls == @["stall"]
      log.errors.len == 2
      log.errors.count(late.hashHex) == 1
      log.errors.count(stall.hashHex) == 1
      log.errorEvents.allIt(it.error == ServiceStoppedReason)

  asyncTest "a service that does not run refuses a send":
    let relay = FakeTransport.new()
    let service = newService(transportsOf((Transport.Relay, relay)))
    await service.stopSendService()
    let refused = service.enqueue(buildTask("after-stop"))
    check:
      refused.isErr()
      refused.error.kind == SendErrorKind.Other
    check not await relay.attempts.waitCount(1).withTimeout(FUTURE_TIMEOUT_SHORT)

  asyncTest "enqueue refuses a message in flight":
    let relay = FakeTransport.new(stalled = @["first"])
    let service = newService(transportsOf((Transport.Relay, relay)))
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
    check await relay.attemptStarted("first").withTimeout(FUTURE_TIMEOUT_MEDIUM)
    relay.reply("first")
    check await log.waitPropagated(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    # The send of `first` ended, so the same message is a new send.
    check service.enqueue(copy).isOk()

  asyncTest "a service with no transport for its anonymity level is an error":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let mixOnly = transportsOf((Transport.Mix, FakeTransport.new()))
    var none: Transports
    check:
      SendService.new(false, waku, manager, mixOnly).isErr()
      SendService.new(false, waku, manager, none, AnonymityLevel.Preferred).isErr()
      SendService.new(false, waku, manager, none, AnonymityLevel.Required).isErr()
      SendService.new(false, waku, manager, mixOnly, AnonymityLevel.Required).isOk()

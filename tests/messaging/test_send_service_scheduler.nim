{.used.}

import std/[importutils, sequtils, tables]
import chronos, testutils/unittests, results, stew/byteutils

import
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service {.all.}, transports, delivery_task]
import ../testlib/[fake_transport, futures, testasync, wakunodeconf]

privateAccess(SendService) # the tests read `sendsEnded` and `deliveryTasks`

## Tests of the rate limit in the send service.
## An accepted task is charged one time.
## An over-budget task is refused with no event.
## A fake transport scripts the result of each attempt.

const ShortInterval = chronos.milliseconds(20)
  ## The attempt interval of a test that waits for each attempt of a task.

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
  ): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
    let left = if remaining.isNil(): rateLimit else: remaining[]
    return
      Opt.some(EpochQuota(epochIndex: epoch[], rateLimit: rateLimit, remaining: left))

suite "SendService rate-limit admission":
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
      state: DeliveryState.Entry,
    )

  proc waitSends(
      service: SendService, count: int, timeout = FUTURE_TIMEOUT_MEDIUM
  ): Future[bool] {.async.} =
    ## Completes with true when `count` sends ended, or with false after
    ## `timeout`. It is the bool form of `checkUntilTimeoutCustom`, so a check can
    ## also wait for a send that must not come.
    let deadline = Moment.now() + timeout
    while service.sendsEnded < count:
      if Moment.now() > deadline:
        return false
      await sleepAsync(chronos.milliseconds(5))
    return true

  proc sendNow(service: SendService, task: DeliveryTask) {.async.} =
    ## Enqueues `task`, and waits for the end of its send.
    let before = service.sendsEnded
    check service.enqueue(task).isOk()
    check await service.waitSends(before + 1)

  proc newManager(
      epoch: ref uint64,
      messagesPerEpoch: uint64,
      rateLimit = 100'u64,
      remaining: ref uint64 = nil,
  ): RateLimitManager =
    return RateLimitManager
      .new(
        RateLimitConfig(
          enabled: true, epochPeriodSec: 600, messagesPerEpoch: messagesPerEpoch
        ),
        fixedEpochQuota(epoch, rateLimit, remaining),
      )
      .expect("RateLimitManager.new")

  proc newService(
      manager: RateLimitManager,
      fake: FakeTransport,
      reliability = false,
      attemptInterval = SendAttemptInterval,
      maxValidationAge = StoreValidationWindow,
      maxSendsInFlight = MaxSendsInFlight,
      transport = Transport.Relay,
  ): SendService =
    ## A service that runs, with `fake` as its one transport.
    let service = SendService
      .new(
        reliability,
        waku,
        manager,
        transportsOf((transport, fake)),
        attemptInterval = attemptInterval,
        maxValidationAge = maxValidationAge,
        storeValidationInterval = chronos.milliseconds(10),
        maxSendsInFlight = maxSendsInFlight,
      )
      .expect("SendService.new")
    service.startSendService()
    started.add(service)
    return service

  type EventLog = ref object ## The send events of one test, in order.
    errors: seq[MessageErrorEvent]
    propagated: seq[string]
    errorSeen: AsyncEvent

  proc listenEvents(brokerCtx: BrokerContext): EventLog =
    let log = EventLog(errorSeen: newAsyncEvent())
    discard MessageErrorEvent
      .listen(
        brokerCtx,
        proc(evt: MessageErrorEvent) {.async: (raises: []).} =
          log.errors.add(evt)
          log.errorSeen.fire(),
      )
      .expect("listen MessageErrorEvent")
    discard MessagePropagatedEvent
      .listen(
        brokerCtx,
        proc(evt: MessagePropagatedEvent) {.async: (raises: []).} =
          log.propagated.add(evt.messageHash),
      )
      .expect("listen MessagePropagatedEvent")
    return log

  proc dropEventListeners(brokerCtx: BrokerContext) {.async.} =
    await MessageErrorEvent.dropAllListeners(brokerCtx)
    await MessagePropagatedEvent.dropAllListeners(brokerCtx)

  proc epochRef(index: uint64): ref uint64 =
    let epoch = new uint64
    epoch[] = index
    return epoch

  asyncTest "a task with more than one attempt is charged one time":
    ## Each attempt sends the same message, with the same RLN message id.
    let manager = newManager(epochRef(5), messagesPerEpoch = 3)
    let relay = FakeTransport.new(results = @[AttemptResult.notPropagated("scripted")])
    let service = newService(manager, relay, attemptInterval = ShortInterval)
    let log = listenEvents(waku.brokerCtx)
    defer:
      await dropEventListeners(waku.brokerCtx)

    let task = buildTask("charge-once", "hi")
    await service.sendNow(task)
    check:
      manager.sentInCurrentEpoch == 1'u64
      relay.calls.len == MaxSendAttempts
      task.msgHash notin service.deliveryTasks
      log.errors.mapIt(it.kind) == @[MessageErrorKind.NotPropagated]

  asyncTest "a task that no attempt transmitted gives its charge back":
    ## The message used no RLN message id, so the next send must not be refused.
    let manager = newManager(epochRef(5), messagesPerEpoch = 1)
    # A lightpush with no peer makes no attempt. A relay publishes also with no peer.
    let lightpush =
      FakeTransport.new(checkResult = Opt.some(AttemptResult.notPropagated()))
    let service = newService(
      manager,
      lightpush,
      attemptInterval = ShortInterval,
      transport = Transport.Lightpush,
    )

    let task = buildTask("charge-back", "hi")
    check service.enqueue(task).isOk()
    check manager.sentInCurrentEpoch == 1'u64
    check await service.waitSends(1)
    check:
      lightpush.calls.len == 0
      manager.sentInCurrentEpoch == 0'u64
      manager.quotaState() == QuotaState.Normal

  asyncTest "a send over the budget is refused with RateLimited and no event":
    ## An app needs the refusal as the result of `send`, with the time to wait.
    ## The network refuses the timestamp of the message when the budget refills.
    let epoch = epochRef(1)
    let manager = newManager(epoch, messagesPerEpoch = 1)
    let relay = FakeTransport.new()
    let service = newService(manager, relay)
    let log = listenEvents(waku.brokerCtx)
    defer:
      await dropEventListeners(waku.brokerCtx)

    let first = buildTask("in-budget", "one")
    await service.sendNow(first)
    check:
      first.state == DeliveryState.SuccessfullyPropagated
      manager.sentInCurrentEpoch == 1'u64

    let second = buildTask("over-budget", "two")
    let refused = service.enqueue(second)
    check refused.isErr()
    if refused.isErr():
      check:
        refused.error.kind == SendErrorKind.RateLimited
        refused.error.retryAfter == manager.retryAfter()
        refused.error.retryAfter > ZeroDuration
    check:
      second.msgHash notin service.deliveryTasks
      manager.sentInCurrentEpoch == 1'u64

    # No send and no event comes for the refused task.
    check:
      not await service.waitSends(2, FUTURE_TIMEOUT_SHORT)
      relay.calls.len == 1
      log.errors.len == 0
      log.propagated == @[first.msgHash.to0xHex()]

    # The epoch rolls: the budget refills, and the same message is accepted.
    epoch[] = 2'u64
    await service.sendNow(second)
    check:
      manager.sentInCurrentEpoch == 1'u64 # the first charge of the new epoch
      second.state == DeliveryState.SuccessfullyPropagated

  asyncTest "RLN's spent budget refuses a send until the epoch rolls":
    ## The local cap has room, but RLN reports the epoch's budget spent.
    let epoch = epochRef(1)
    let remaining = new uint64
    remaining[] = 0'u64
    let manager =
      newManager(epoch, messagesPerEpoch = 10, rateLimit = 10, remaining = remaining)
    let relay = FakeTransport.new()
    let service = newService(manager, relay)

    let task = buildTask("rln-spent", "one")
    check:
      service.enqueue(task).error.kind == SendErrorKind.RateLimited
      manager.sentInCurrentEpoch == 0'u64

    epoch[] = 2'u64
    remaining[] = 10'u64
    await service.sendNow(task)
    check:
      task.state == DeliveryState.SuccessfullyPropagated
      relay.calls.len == 1

  asyncTest "a message that the service already sends is refused as Duplicate":
    ## Each event carries only the message hash.
    ## So the app cannot tell apart the events of two sends with one hash.
    let manager = newManager(epochRef(1), messagesPerEpoch = 5)
    let relay = FakeTransport.new()
    # The task stays in the service while it waits for a Store confirmation.
    let service = newService(manager, relay, reliability = true)

    let task = buildTask("duplicate", "one")
    check service.enqueue(task).isOk()
    checkUntilTimeout:
      task.awaitsStore()
    let copy = buildTask("duplicate", "one", timestamp = task.msg.timestamp)
    check:
      copy.msgHash == task.msgHash
      service.enqueue(copy).error.kind == SendErrorKind.Duplicate
      manager.sentInCurrentEpoch == 1'u64

  proc approachedService(
      epoch: ref uint64, messagesPerEpoch: uint64, relay: FakeTransport
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
    return (newService(manager, relay), manager)

  asyncTest "an ephemeral message is refused when the quota is approached":
    ## An ephemeral message must not use the budget left for durable messages.
    let relay = FakeTransport.new()
    let (service, manager) = approachedService(epochRef(1), 4, relay)
    let log = listenEvents(waku.brokerCtx)
    defer:
      await dropEventListeners(waku.brokerCtx)

    await service.sendNow(buildTask("durable-1", "one"))
    await service.sendNow(buildTask("durable-2", "two"))
    check manager.quotaState() == QuotaState.Approached
    let callsBefore = relay.calls.len

    let eph = buildTask("ephemeral-approached", "eph", ephemeral = true)
    check:
      service.enqueue(eph).error.kind == SendErrorKind.RateLimited
      manager.sentInCurrentEpoch == 2'u64 # no charge, so no RLN proof either

    check:
      not await service.waitSends(3, FUTURE_TIMEOUT_SHORT)
      relay.calls.len == callsBefore
      log.errors.len == 0

  asyncTest "an ephemeral message is refused when the quota is exhausted":
    let relay = FakeTransport.new()
    let (service, manager) = approachedService(epochRef(1), 1, relay)

    await service.sendNow(buildTask("durable-spends", "one"))
    check manager.quotaState() == QuotaState.Exhausted

    let eph = buildTask("ephemeral-exhausted", "eph", ephemeral = true)
    check:
      service.enqueue(eph).error.kind == SendErrorKind.RateLimited
      manager.sentInCurrentEpoch == 1'u64

  asyncTest "an ephemeral message below the threshold is charged and sent":
    let relay = FakeTransport.new()
    let (service, manager) = approachedService(epochRef(1), 4, relay)

    let eph = buildTask("ephemeral-normal", "eph", ephemeral = true)
    await service.sendNow(eph)
    check:
      eph.state == DeliveryState.SuccessfullyPropagated
      manager.sentInCurrentEpoch == 1'u64

  asyncTest "a durable message is still admitted when the quota is approached":
    let relay = FakeTransport.new()
    let (service, manager) = approachedService(epochRef(1), 4, relay)

    await service.sendNow(buildTask("durable-a", "a"))
    await service.sendNow(buildTask("durable-b", "b"))
    check manager.quotaState() == QuotaState.Approached

    let durable = buildTask("durable-approached", "c")
    await service.sendNow(durable)
    check:
      durable.state == DeliveryState.SuccessfullyPropagated
      manager.sentInCurrentEpoch == 3'u64

  asyncTest "a propagated task with no Store confirmation in the window fails as NotStored":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let relay = FakeTransport.new()
    let service = newService(
      manager,
      relay,
      reliability = true,
      attemptInterval = chronos.milliseconds(20),
      maxValidationAge = chronos.milliseconds(50),
    )
    let log = listenEvents(waku.brokerCtx)
    defer:
      await dropEventListeners(waku.brokerCtx)

    let task = buildTask("validation-expired", "one")
    await service.sendNow(task)
    check await log.errorSeen.wait().withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      task.state == DeliveryState.FailedToDeliver
      task.msgHash notin service.deliveryTasks
      log.propagated == @[task.msgHash.to0xHex()]
      log.errors.mapIt(it.messageHash) == @[task.msgHash.to0xHex()]
      log.errors.mapIt(it.kind) == @[MessageErrorKind.NotStored]

  asyncTest "the Store wait of a task continues after the time of its attempts":
    ## The attempt intervals bound only the sends.
    ## A Store node can confirm a propagated message later.
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let relay = FakeTransport.new()
    let service = newService(
      manager, relay, reliability = true, attemptInterval = chronos.milliseconds(10)
    )
    let log = listenEvents(waku.brokerCtx)
    defer:
      await dropEventListeners(waku.brokerCtx)

    let task = buildTask("store-after-window", "one")
    await service.sendNow(task)
    check not await log.errorSeen.wait().withTimeout(chronos.milliseconds(300))
    check:
      task.state == DeliveryState.SuccessfullyPropagated
      task.msgHash in service.deliveryTasks
      log.errors.len == 0

  asyncTest "a stop fails a task that waits for a Store confirmation as NotStored":
    ## The service keeps no task for a restart.
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let relay = FakeTransport.new()
    let service = newService(manager, relay, reliability = true)
    let log = listenEvents(waku.brokerCtx)
    defer:
      await dropEventListeners(waku.brokerCtx)

    let task = buildTask("stop-in-store-wait", "one")
    check service.enqueue(task).isOk()
    checkUntilTimeout:
      task.awaitsStore()
    await service.stopSendService()
    check:
      service.deliveryTasks.len == 0
      log.errors.mapIt(it.messageHash) == @[task.msgHash.to0xHex()]
      log.errors.mapIt(it.kind) == @[MessageErrorKind.NotStored]
      log.errors.mapIt(it.error) == @[ServiceStoppedReason]

  asyncTest "a task that waits for a Store confirmation counts for MaxSendsInFlight":
    ## The limit bounds the messages that the node keeps, also after their send.
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let relay = FakeTransport.new()
    let service = newService(manager, relay, reliability = true, maxSendsInFlight = 1)

    let task = buildTask("waits-for-store", "one")
    check service.enqueue(task).isOk()
    checkUntilTimeout:
      task.awaitsStore()
    check service.enqueue(buildTask("over", "two")).error.kind == SendErrorKind.QueueFull

  asyncTest "with reliability off a propagated task is evicted without MessageError":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let relay = FakeTransport.new()
    let service = newService(manager, relay)
    let log = listenEvents(waku.brokerCtx)
    defer:
      await dropEventListeners(waku.brokerCtx)

    let task = buildTask("reliability-off", "one")
    await service.sendNow(task)
    check:
      task.state == DeliveryState.SuccessfullyPropagated
      log.errors.len == 0
      service.deliveryTasks.len == 0 # the service removed the task

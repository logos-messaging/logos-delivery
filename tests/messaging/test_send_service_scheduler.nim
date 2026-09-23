{.used.}

import chronos, chronicles, testutils/unittests, results, stew/byteutils

import
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service, send_processor, delivery_task]
import ../testlib/[testasync, wakunodeconf]

## Scheduler-level coverage for the send service's rate-limit seam: a task is
## charged exactly once however many rounds it takes, and an over-budget task
## is parked then released when the epoch rolls. A fake processor scripts the
## delivery outcome so the loop runs without network or sleeps.

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

proc fixedEpochQuota(epoch: ptr uint64, userMessageLimit: uint64): QuotaProvider =
  ## Quota pinned to whatever `epoch` holds, so a test rolls the epoch by
  ## writing through the pointer.
  return proc(): Opt[EpochQuota] {.gcsafe, raises: [].} =
    return Opt.some(EpochQuota(epochIndex: epoch[], userMessageLimit: userMessageLimit))

suite "SendService - rate-limit scheduling":
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")

  asyncTeardown:
    ## The node is never started, so stop is best-effort cleanup.
    discard await waku.stop()

  proc buildTask(id, payload: string, ephemeral = false): DeliveryTask =
    ## Built directly rather than via `DeliveryTask.new`, which needs a broker
    ## provider only registered once the node starts.
    let msg = WakuMessage(
      contentTopic: "/test/1/scheduler/proto",
      payload: payload.toBytes(),
      timestamp: 1_700_000_000_000_000_000,
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

  asyncTest "a task is charged once even when delivery takes several rounds":
    ## First round fails to propagate, second succeeds. The retry must not draw a
    ## second slot: `firstAdmittedTime` guards re-admission.
    var epoch = 5'u64
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 3),
        fixedEpochQuota(addr epoch, userMessageLimit = 100),
      )
      .expect("RateLimitManager.new")
    let processor = FakeSendProcessor(
      script: @[DeliveryState.NextRoundRetry, DeliveryState.SuccessfullyPropagated]
    )
    let service =
      SendService.new(false, waku, manager, processor).expect("SendService.new")

    let task = buildTask("charge-once", "hi")
    await service.send(task)
    check:
      manager.sentInCurrentEpoch == 1'u64
      task.firstAdmittedTime.isSome()
      task.state == DeliveryState.NextRoundRetry

    await service.trySendMessages()
    check:
      manager.sentInCurrentEpoch == 1'u64 # not re-charged on retry
      processor.calls == 2
      task.state == DeliveryState.SuccessfullyPropagated

  asyncTest "an over-budget task is parked, then released when the epoch rolls":
    ## Budget of one per epoch. The second send is parked until the epoch rolls,
    ## then admitted and delivered.
    var epoch = 1'u64
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
        fixedEpochQuota(addr epoch, userMessageLimit = 100),
      )
      .expect("RateLimitManager.new")
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let service =
      SendService.new(false, waku, manager, processor).expect("SendService.new")

    let first = buildTask("in-budget", "one")
    await service.send(first)
    check:
      first.state == DeliveryState.SuccessfullyPropagated
      manager.sentInCurrentEpoch == 1'u64

    let second = buildTask("over-budget", "two")
    await service.send(second)
    check:
      second.state == DeliveryState.NextRoundRetry # parked
      second.firstAdmittedTime.isNone() # never admitted
    let callsWhenParked = processor.calls

    # Same epoch: still over budget, so the parked task is not handed to the
    # processor.
    await service.trySendMessages()
    check:
      second.state == DeliveryState.NextRoundRetry
      second.firstAdmittedTime.isNone()
      processor.calls == callsWhenParked

    # Epoch rolls: budget refills, the parked task is admitted and delivered.
    epoch = 2'u64
    await service.trySendMessages()
    check:
      second.firstAdmittedTime.isSome()
      second.state == DeliveryState.SuccessfullyPropagated

  asyncTest "a task parked for budget reports itself queued, exactly once":
    ## The park branch is re-entered every retry round; the event must not be.
    var epoch = 1'u64
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
        fixedEpochQuota(addr epoch, userMessageLimit = 100),
      )
      .expect("RateLimitManager.new")
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let service =
      SendService.new(false, waku, manager, processor).expect("SendService.new")

    var queued: seq[MessageQueuedEvent]
    discard MessageQueuedEvent
      .listen(
        waku.brokerCtx,
        proc(evt: MessageQueuedEvent) {.async: (raises: []).} =
          queued.add(evt),
      )
      .expect("listen MessageQueuedEvent")

    ## Spends the epoch's single slot; admitted, so it reports nothing.
    await service.send(buildTask("queued-in-budget", "one"))
    check queued.len == 0

    let second = buildTask("queued-over-budget", "two")
    await service.send(second)
    check:
      queued.len == 1
      queued[0].requestId == second.requestId
      queued[0].messageHash == second.msgHash.to0xHex()

    ## Still over budget: the task parks again, the event does not repeat.
    await service.trySendMessages()
    check queued.len == 1

    ## Released by the roll, and delivery emits no further queued event.
    epoch = 2'u64
    await service.trySendMessages()
    check:
      second.state == DeliveryState.SuccessfullyPropagated
      queued.len == 1

    await MessageQueuedEvent.dropAllListeners(waku.brokerCtx)

  proc approachedService(
      epoch: ptr uint64, messagesPerEpoch: uint64, processor: FakeSendProcessor
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
        fixedEpochQuota(epoch, userMessageLimit = 100),
      )
      .expect("RateLimitManager.new")
    let service =
      SendService.new(false, waku, manager, processor).expect("SendService.new")
    return (service, manager)

  asyncTest "an ephemeral message is dropped when the quota is approached":
    var epoch = 1'u64
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let (service, manager) = approachedService(addr epoch, 4, processor)

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

    await service.send(buildTask("durable-1", "one"))
    await service.send(buildTask("durable-2", "two"))
    check manager.quotaState() == QuotaState.Approached
    let callsBefore = processor.calls

    let eph = buildTask("ephemeral-approached", "eph", ephemeral = true)
    await service.send(eph)
    check:
      eph.state == DeliveryState.FailedToDeliver
      eph.firstAdmittedTime.isNone() # no slot, so no RLN proof either
      manager.sentInCurrentEpoch == 2'u64
      processor.calls == callsBefore
      queued.len == 0
      errors.len == 1
      errors[0].requestId == eph.requestId
      errors[0].messageHash == eph.msgHash.to0xHex()

    ## Not parked: a later round never hands it to the processor.
    await service.trySendMessages()
    check processor.calls == callsBefore

    await MessageErrorEvent.dropAllListeners(waku.brokerCtx)
    await MessageQueuedEvent.dropAllListeners(waku.brokerCtx)

  asyncTest "an ephemeral message is dropped, not parked, when the quota is exhausted":
    var epoch = 1'u64
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let (service, manager) = approachedService(addr epoch, 1, processor)

    var errors: seq[MessageErrorEvent]
    discard MessageErrorEvent
      .listen(
        waku.brokerCtx,
        proc(evt: MessageErrorEvent) {.async: (raises: []).} =
          errors.add(evt),
      )
      .expect("listen MessageErrorEvent")

    await service.send(buildTask("durable-spends", "one"))
    check manager.quotaState() == QuotaState.Exhausted
    let callsBefore = processor.calls

    let eph = buildTask("ephemeral-exhausted", "eph", ephemeral = true)
    await service.send(eph)
    check:
      eph.state == DeliveryState.FailedToDeliver
      eph.firstAdmittedTime.isNone()
      errors.len == 1

    ## Budget refills, but the dropped message stays dropped.
    epoch = 2'u64
    await service.trySendMessages()
    check:
      processor.calls == callsBefore
      manager.quotaState() == QuotaState.Normal
      manager.sentInCurrentEpoch == 0'u64

    await MessageErrorEvent.dropAllListeners(waku.brokerCtx)

  asyncTest "an ephemeral message below the threshold is charged and sent":
    var epoch = 1'u64
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let (service, manager) = approachedService(addr epoch, 4, processor)

    let eph = buildTask("ephemeral-normal", "eph", ephemeral = true)
    await service.send(eph)
    check:
      eph.state == DeliveryState.SuccessfullyPropagated
      eph.firstAdmittedTime.isSome()
      manager.sentInCurrentEpoch == 1'u64

  asyncTest "a durable message is still admitted when the quota is approached":
    var epoch = 1'u64
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let (service, manager) = approachedService(addr epoch, 4, processor)

    await service.send(buildTask("durable-a", "a"))
    await service.send(buildTask("durable-b", "b"))
    check manager.quotaState() == QuotaState.Approached

    let durable = buildTask("durable-approached", "c")
    await service.send(durable)
    check:
      durable.state == DeliveryState.SuccessfullyPropagated
      manager.sentInCurrentEpoch == 3'u64

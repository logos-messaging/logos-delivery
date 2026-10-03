{.used.}

import std/sequtils
import chronos, testutils/unittests, results, stew/byteutils

import
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/rln/rln_plugin,
  logos_delivery/api/types,
  logos_delivery/api/events/[kernel_events, messaging_client_events],
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service, send_processor, delivery_task]
import ../testlib/[futures, testasync, wakunodeconf]

## The exit of a mix send publishes the message before it replies. When the
## reply is lost, this node still receives its message from the network, and
## the send is complete.

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

proc newTask(id: string, ephemeral = false): DeliveryTask =
  let msg = WakuMessage(
    contentTopic: "/test/1/seen/proto",
    payload: id.toBytes(),
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

type FakeProcessor = ref object of BaseSendProcessor
  ## Each call sets `anonymized` as a mix attempt does, unless `plain`. Then it
  ## waits for `finish`, and writes the next state of `outcomes`.
  plain: bool
  outcomes: seq[DeliveryState]
  calls: int
  callIds: seq[RequestId]
  started: AsyncEvent
  finish: AsyncEvent
  onCall: proc(task: DeliveryTask) {.gcsafe, raises: [].}
    ## Runs in the call before the wait, as a processor that publishes does.

proc newFakeProcessor(outcomes: seq[DeliveryState], plain = false): FakeProcessor =
  FakeProcessor(
    plain: plain, outcomes: outcomes, started: newAsyncEvent(), finish: newAsyncEvent()
  )

method process(self: FakeProcessor, task: DeliveryTask): Future[void] {.async.} =
  let outcome = self.outcomes[min(self.calls, self.outcomes.high)]
  inc self.calls
  self.callIds.add(task.requestId)
  if not self.plain:
    task.anonymized = true
  if not self.onCall.isNil():
    self.onCall(task)
  self.started.fire()
  await self.finish.wait()
  self.finish.clear()
  task.state = outcome
  if outcome == DeliveryState.SuccessfullyPropagated:
    task.deliveryTime = Moment.now()
    task.firstPropagatedTime = Opt.some(Moment.now())

type SendEvent {.pure.} = enum
  Propagated
  Sent
  Failed

type SendEventLog = ref object
  brokerCtx: BrokerContext
  ids: array[SendEvent, seq[RequestId]]
  propagatedListener: MessagePropagatedEventListener
  sentListener: MessageSentEventListener
  errorListener: MessageErrorEventListener

proc newSendEventLog(brokerCtx: BrokerContext): SendEventLog =
  let log = SendEventLog(brokerCtx: brokerCtx)
  log.propagatedListener = MessagePropagatedEvent
    .listen(
      brokerCtx,
      proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
        log.ids[SendEvent.Propagated].add(event.requestId),
    )
    .expect("listen propagated")
  log.sentListener = MessageSentEvent
    .listen(
      brokerCtx,
      proc(event: MessageSentEvent) {.async: (raises: []).} =
        log.ids[SendEvent.Sent].add(event.requestId),
    )
    .expect("listen sent")
  log.errorListener = MessageErrorEvent
    .listen(
      brokerCtx,
      proc(event: MessageErrorEvent) {.async: (raises: []).} =
        log.ids[SendEvent.Failed].add(event.requestId),
    )
    .expect("listen error")
  return log

proc teardown(log: SendEventLog) {.async.} =
  await MessagePropagatedEvent.dropListener(log.brokerCtx, log.propagatedListener)
  await MessageSentEvent.dropListener(log.brokerCtx, log.sentListener)
  await MessageErrorEvent.dropListener(log.brokerCtx, log.errorListener)

proc count(log: SendEventLog, event: SendEvent, task: DeliveryTask): int =
  for id in log.ids[event]:
    if id == task.requestId:
      inc result

proc receiveOwn(waku: Waku, task: DeliveryTask) =
  ## This node receives the message of `task` from the network.
  MessageSeenEvent.emit(waku.brokerCtx, task.pubsubTopic, task.msg)

suite "SendService - a mix send that this node receives from the network":
  var waku {.threadvar.}: Waku
  var log {.threadvar.}: SendEventLog

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")
    log = newSendEventLog(waku.brokerCtx)

  asyncTeardown:
    await log.teardown()
    discard await waku.stop()

  proc newService(processor: FakeProcessor, reliability = true): SendService =
    ## The loop runs one pass at start, then the tests drive the passes.
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService
      .new(
        reliability,
        waku,
        manager,
        processor,
        AnonymityLevel.Required,
        serviceLoopInterval = chronos.hours(1),
      )
      .expect("SendService.new")
    service.startSendService()
    return service

  asyncTest "a mix message that this node receives completes its first attempt":
    let processor = newFakeProcessor(@[DeliveryState.NextRoundRetry])
    let service = newService(processor)
    defer:
      await service.stopSendService()
    let task = newTask("first-attempt")

    let sending = service.send(task)
    check await processor.started.wait().withTimeout(FUTURE_TIMEOUT)
    waku.receiveOwn(task)
    check task.seenOnNetwork
    processor.finish.fire()
    check await sending.withTimeout(FUTURE_TIMEOUT)

    check:
      processor.calls == 1
      task.state == DeliveryState.SuccessfullyPropagated
      task.propagatedAnonymously
      log.count(SendEvent.Propagated, task) == 1
      log.count(SendEvent.Failed, task) == 0

  asyncTest "the message that this node received wins over a later refusal of the exit":
    let processor =
      newFakeProcessor(@[DeliveryState.NextRoundRetry, DeliveryState.FailedToDeliver])
    let service = newService(processor)
    defer:
      await service.stopSendService()
    let task = newTask("refused-retry")
    let sending = service.send(task)
    check await processor.started.wait().withTimeout(FUTURE_TIMEOUT)
    processor.started.clear()
    processor.finish.fire()
    check await sending.withTimeout(FUTURE_TIMEOUT)
    check task.state == DeliveryState.NextRoundRetry

    let pass = service.trySendMessages()
    check await processor.started.wait().withTimeout(FUTURE_TIMEOUT)
    waku.receiveOwn(task)
    processor.finish.fire()
    check await pass.withTimeout(FUTURE_TIMEOUT)
    service.evaluateAndCleanUp()

    check:
      processor.calls == 2
      log.count(SendEvent.Propagated, task) == 1
      log.count(SendEvent.Failed, task) == 0

  asyncTest "a seen message gets no next attempt and no second admission":
    let processor = newFakeProcessor(@[DeliveryState.NextRoundRetry])
    let service = newService(processor)
    defer:
      await service.stopSendService()
    let task = newTask("between-rounds")
    let sending = service.send(task)
    check await processor.started.wait().withTimeout(FUTURE_TIMEOUT)
    processor.finish.fire()
    check await sending.withTimeout(FUTURE_TIMEOUT)
    # An RLN refusal parks the task for a new admission and a new proof. The
    # hook makes the park wait for a refresh.
    waku.node.rlnPlugin = Opt.some(
      RlnPlugin(
        onProofRejected: proc() {.gcsafe, raises: [].} =
          discard
      )
    )
    task.parkForRlnProofRefresh(waku, "stale proof")
    check task.firstAdmittedTime.isNone()

    waku.receiveOwn(task)
    # An attempt in this pass must not wait for the test.
    processor.finish.fire()
    check await service.trySendMessages().withTimeout(FUTURE_TIMEOUT)
    service.evaluateAndCleanUp()

    check:
      processor.calls == 1
      task.firstAdmittedTime.isNone()
      task.state == DeliveryState.SuccessfullyPropagated
      log.count(SendEvent.Propagated, task) == 1

  asyncTest "a message received in the FallbackRetry state does not count":
    ## A fallback processor runs in this state, and relay gives this node its own
    ## publish.
    let processor = newFakeProcessor(@[DeliveryState.NextRoundRetry])
    processor.onCall = proc(task: DeliveryTask) {.gcsafe, raises: [].} =
      task.state = DeliveryState.FallbackRetry
      waku.receiveOwn(task)
    let service = newService(processor)
    defer:
      await service.stopSendService()
    let task = newTask("own-publish")

    let sending = service.send(task)
    check await processor.started.wait().withTimeout(FUTURE_TIMEOUT)
    processor.finish.fire()
    check await sending.withTimeout(FUTURE_TIMEOUT)

    check:
      task.anonymized
      not task.seenOnNetwork
      task.state == DeliveryState.NextRoundRetry
      log.count(SendEvent.Propagated, task) == 0

  asyncTest "a task that the plain path propagated keeps its Store confirmation":
    ## A `Preferred` task can propagate on the plain path after a mix attempt.
    ## Its message then arrives, and the task still waits for a Store node.
    let processor = newFakeProcessor(
      @[DeliveryState.NextRoundRetry, DeliveryState.SuccessfullyPropagated]
    )
    let service = newService(processor)
    defer:
      await service.stopSendService()
    let task = newTask("plain-propagated")
    let sending = service.send(task)
    check await processor.started.wait().withTimeout(FUTURE_TIMEOUT)
    processor.started.clear()
    processor.finish.fire()
    check await sending.withTimeout(FUTURE_TIMEOUT)

    let pass = service.trySendMessages()
    check await processor.started.wait().withTimeout(FUTURE_TIMEOUT)
    processor.finish.fire()
    check await pass.withTimeout(FUTURE_TIMEOUT)
    waku.receiveOwn(task)
    service.evaluateAndCleanUp()

    check:
      task.firstPropagatedTime.isSome()
      not task.propagatedAnonymously
      service.awaitsStoreValidation(task)
      log.count(SendEvent.Sent, task) == 0

  asyncTest "a task with no mix send attempt does not count its message":
    let processor = newFakeProcessor(@[DeliveryState.NextRoundRetry], plain = true)
    let service = newService(processor)
    defer:
      await service.stopSendService()
    let task = newTask("plain")

    let sending = service.send(task)
    check await processor.started.wait().withTimeout(FUTURE_TIMEOUT)
    waku.receiveOwn(task)
    processor.finish.fire()
    check await sending.withTimeout(FUTURE_TIMEOUT)

    check:
      not task.seenOnNetwork
      task.state == DeliveryState.NextRoundRetry
      log.count(SendEvent.Propagated, task) == 0

  asyncTest "a seen mix message ends with the events of a mix send whose reply arrived":
    for (reliability, ephemeral, sent) in [
      (true, false, 1), (false, false, 0), (true, true, 0)
    ]:
      let processor = newFakeProcessor(@[DeliveryState.NextRoundRetry])
      let service = newService(processor, reliability)
      let task = newTask("events-" & $reliability & $ephemeral, ephemeral)
      let sending = service.send(task)
      check await processor.started.wait().withTimeout(FUTURE_TIMEOUT)
      waku.receiveOwn(task)
      processor.finish.fire()
      check await sending.withTimeout(FUTURE_TIMEOUT)
      service.evaluateAndCleanUp()
      await service.stopSendService()

      check:
        log.count(SendEvent.Propagated, task) == 1
        log.count(SendEvent.Sent, task) == sent
        log.count(SendEvent.Failed, task) == 0
        not service.awaitsStoreValidation(task)

  asyncTest "a stop drops the listener and keeps the mark for the next start":
    let processor = newFakeProcessor(@[DeliveryState.NextRoundRetry])
    let service = newService(processor)
    let task = newTask("stopped")
    let other = newTask("after-stop")
    for t in [task, other]:
      let sending = service.send(t)
      check await processor.started.wait().withTimeout(FUTURE_TIMEOUT)
      processor.started.clear()
      processor.finish.fire()
      check await sending.withTimeout(FUTURE_TIMEOUT)

    let pass = service.trySendMessages()
    check await processor.started.wait().withTimeout(FUTURE_TIMEOUT)
    processor.started.clear()
    waku.receiveOwn(task)
    await service.stopSendService()
    check await pass.withTimeout(FUTURE_TIMEOUT)
    check:
      task.seenOnNetwork
      task.state == DeliveryState.NextRoundRetry

    waku.receiveOwn(other)
    check not other.seenOnNetwork

    # The first pass of the restart completes `task`, and makes one attempt of
    # `other`.
    let calls = processor.callIds.count(task.requestId)
    let otherCalls = processor.callIds.count(other.requestId)
    service.startSendService()
    defer:
      await service.stopSendService()
    check await processor.started.wait().withTimeout(FUTURE_TIMEOUT)
    processor.finish.fire()
    checkUntilTimeout:
      log.count(SendEvent.Propagated, task) == 1
    check:
      processor.callIds.count(task.requestId) == calls
      processor.callIds.count(other.requestId) == otherCalls + 1

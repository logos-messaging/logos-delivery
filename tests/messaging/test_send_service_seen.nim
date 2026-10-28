{.used.}

## A copy of the message from the network completes a mix send whose reply was
## lost. After a plain attempt, a copy tells nothing about the mix send.

import chronos, testutils/unittests, results, stew/byteutils
import brokers/broker_context
import
  logos_delivery/waku/[waku, waku_core],
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/api/types,
  logos_delivery/api/events/[kernel_events, messaging_client_events],
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service, send_processor, delivery_task]
import ../testlib/[testasync, wakucore, wakunodeconf]

type LostReplyProcessor = ref object of BaseSendProcessor
  ## A mix attempt whose reply is lost, each time.
  calls: int

method isPlain(self: LostReplyProcessor): bool {.gcsafe.} =
  return false

method isValidProcessor(self: LostReplyProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: LostReplyProcessor, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  task.anonymized = true
  task.state = DeliveryState.NextRoundRetry

type HandoverProcessor = ref object of BaseSendProcessor
  ## A mix attempt that hands the task to the plain path at once.

method isPlain(self: HandoverProcessor): bool {.gcsafe.} =
  return false

method isValidProcessor(self: HandoverProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: HandoverProcessor, task: DeliveryTask): Future[void] {.async.} =
  task.anonymized = true
  task.state = DeliveryState.FallbackRetry

type NeverValidProcessor = ref object of BaseSendProcessor
  ## No processor attempts the task, as when no peer serves it. `asked` counts
  ## the passes of the service.
  asked: int

method isValidProcessor(
    self: NeverValidProcessor, task: DeliveryTask
): bool {.gcsafe.} =
  inc self.asked
  return false

type PlainRetryProcessor = ref object of BaseSendProcessor
  ## A plain attempt that leaves the task for a retry, each time.
  calls: int

method isValidProcessor(
    self: PlainRetryProcessor, task: DeliveryTask
): bool {.gcsafe.} =
  return true

method sendImpl(self: PlainRetryProcessor, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  task.state = DeliveryState.NextRoundRetry

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

proc buildTask(id: string): DeliveryTask =
  ## An admitted task with no RLN. The id is the payload, so two tasks never
  ## have one hash.
  let msg = WakuMessage(
    contentTopic: "/test/1/seen/proto",
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
    firstAdmittedTime: Opt.some(Moment.now()),
  )

proc emitSeen(waku: Waku, task: DeliveryTask) =
  ## The network gives this node the message of `task`.
  MessageSeenEvent.emit(waku.brokerCtx, task.pubsubTopic, task.msg)

suite "SendService - a message seen on the network":
  var waku {.threadvar.}: Waku
  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")
  asyncTeardown:
    discard await waku.stop()

  proc newService(processor: BaseSendProcessor): SendService =
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService
      .new(false, waku, manager, processor, retryInterval = chronos.milliseconds(100))
      .expect("SendService.new")
    service.startSendService()
    return service

  asyncTest "a message seen on the network completes a mix send whose reply was lost":
    let mix = LostReplyProcessor()
    let service = newService(mix)
    defer:
      await service.stopSendService()
    var propagated = 0
    let listener = MessagePropagatedEvent
      .listen(
        waku.brokerCtx,
        proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
          propagated.inc(),
      )
      .expect("listen")
    defer:
      await MessagePropagatedEvent.dropListener(waku.brokerCtx, listener)
    let task = buildTask("lost-reply")
    check service.enqueue(task).isOk()
    checkUntilTimeout:
      mix.calls >= 1

    waku.emitSeen(task)

    checkUntilTimeout:
      task.state == DeliveryState.SuccessfullyPropagated
    check:
      task.propagatedAnonymously
      task.firstPropagatedTime.isSome()
    checkUntilTimeout:
      propagated == 1

  asyncTest "a message seen before any attempt does not complete the task":
    let never = NeverValidProcessor()
    let service = newService(never)
    defer:
      await service.stopSendService()
    let task = buildTask("no-attempt")
    check service.enqueue(task).isOk()
    checkUntilTimeout:
      task.state == DeliveryState.NextRoundRetry

    waku.emitSeen(task)
    let before = never.asked

    checkUntilTimeout:
      never.asked >= before + 3
    check:
      not task.seenOnNetwork
      task.state == DeliveryState.NextRoundRetry
      not task.propagatedAnonymously

  asyncTest "a message seen after a plain attempt does not complete the task as a mix send":
    ## The plain attempt put the message on the network in the clear.
    let mix = HandoverProcessor()
    let plain = PlainRetryProcessor()
    mix.chain(plain)
    let service = newService(mix)
    defer:
      await service.stopSendService()
    let task = buildTask("plain-after-mix")
    check service.enqueue(task).isOk()
    checkUntilTimeout:
      plain.calls >= 1
    check:
      task.anonymized
      task.plainAttempted

    waku.emitSeen(task)

    checkUntilTimeout:
      plain.calls >= 3
    check:
      not task.seenOnNetwork
      task.state == DeliveryState.NextRoundRetry
      not task.propagatedAnonymously

  asyncTest "a stopped service does not read the network, and a restart reads it again":
    let mix = LostReplyProcessor()
    let service = newService(mix)
    defer:
      await service.stopSendService()
    let task = buildTask("stopped")
    check service.enqueue(task).isOk()
    checkUntilTimeout:
      mix.calls >= 1
    await service.stopSendService()

    waku.emitSeen(task)
    service.startSendService()

    # A second attempt shows that `completeIfSeen` found no `seenOnNetwork` after
    # the restart.
    checkUntilTimeout:
      mix.calls >= 2
    check not task.seenOnNetwork

    waku.emitSeen(task)

    checkUntilTimeout:
      task.state == DeliveryState.SuccessfullyPropagated

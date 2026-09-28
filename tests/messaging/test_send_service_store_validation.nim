{.used.}

import std/sequtils
import chronos, chronicles, testutils/unittests, results, stew/byteutils

import
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_node,
  logos_delivery/waku/waku_store,
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/api/store,
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service, send_processor, delivery_task],
  logos_delivery/api/events/messaging_client_events
import ../testlib/[testasync, wakunodeconf, wakucore, wakunode]
import ../waku_store/store_utils

## Store-based reliability asks a store node for a propagated message's hash, in
## clear from this node's own address. It must never ask for a mixed message.

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

proc newTask(id: string): DeliveryTask =
  let msg = WakuMessage(
    contentTopic: "/test/1/store-validation/proto",
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

proc propagatedAt(id: string, time: Moment): DeliveryTask =
  ## A task that propagated at `time` and waits for a Store confirmation.
  let task = newTask(id)
  task.state = DeliveryState.SuccessfullyPropagated
  task.firstPropagatedTime = Opt.some(time)
  return task

suite "SendService - store validation and mix":
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")

  asyncTeardown:
    discard await waku.stop()

  proc service(reliability: bool): SendService =
    ## The policy under test never sends, so the plain chain is enough.
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let chain = setupSendProcessorChain(waku, AnonymityLevel.None).expect("chain")
    return SendService.new(reliability, waku, manager, chain).expect("SendService.new")

  proc propagatedTask(overMix: bool, ephemeral = false): DeliveryTask =
    let task = propagatedAt("t", Moment.now())
    task.msg.ephemeral = ephemeral
    task.propagatedAnonymously = overMix
    return task

  asyncTest "the store client is mounted even on a node that serves no store":
    ## `checkStoreForMessages` is `preferP2PReliability and isStoreMounted()`,
    ## and every node mounts the store client, so reliability alone decides.
    check waku.isStoreMounted()

  asyncTest "a plainly propagated message is confirmed against a store node":
    check service(reliability = true).awaitsStoreValidation(
      propagatedTask(overMix = false)
    )

  asyncTest "a message that went out over mix is never confirmed against a store node":
    ## The query would carry its hash, in clear, from this node's own address.
    check not service(reliability = true).awaitsStoreValidation(
      propagatedTask(overMix = true)
    )

  asyncTest "an ephemeral message is not confirmed either, mixed or not":
    let reliable = service(reliability = true)
    check:
      not reliable.awaitsStoreValidation(
        propagatedTask(overMix = false, ephemeral = true)
      )
      not reliable.awaitsStoreValidation(
        propagatedTask(overMix = true, ephemeral = true)
      )

  asyncTest "nothing is confirmed when reliability is off":
    check not service(reliability = false).awaitsStoreValidation(
      propagatedTask(overMix = false)
    )

  asyncTest "a task that has not propagated is not confirmed yet":
    let task = propagatedTask(overMix = false)
    task.state = DeliveryState.NextRoundRetry
    check not service(reliability = true).awaitsStoreValidation(task)

## A scripted processor sets the outcome that a real processor would, so these
## tests drive the completion events with no live mixnet.
type ScriptedProc = ref object of BaseSendProcessor
  overMix: bool
  calls: int
  retryCalls: seq[int] ## Calls, counted from 1, that leave the task for the next round.

method process(self: ScriptedProc, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  if self.calls in self.retryCalls:
    task.state = DeliveryState.NextRoundRetry
    return
  task.state = DeliveryState.SuccessfullyPropagated
  task.propagatedAnonymously = self.overMix
  task.deliveryTime = Moment.now()
  if task.firstPropagatedTime.isNone():
    task.firstPropagatedTime = Opt.some(Moment.now())

const FastLoop = chronos.milliseconds(10)
  ## The loop interval of a test service. It keeps each wait for a loop short.

proc reliableService(waku: Waku, processor: ScriptedProc): SendService =
  ## A service with Store-based reliability on and fast loops.
  let manager =
    RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
  return SendService
    .new(true, waku, manager, processor, serviceLoopInterval = FastLoop)
    .expect("SendService.new")

type SendEvent {.pure.} = enum
  Propagated
  Sent
  Failed

type SendEventLog = ref object
  ## Records the request ids of send events and wakes the tests that wait for one.
  brokerCtx: BrokerContext
  ids: array[SendEvent, seq[RequestId]]
  changed: AsyncEvent
  propagatedListener: MessagePropagatedEventListener
  sentListener: MessageSentEventListener
  errorListener: MessageErrorEventListener

proc record(log: SendEventLog, event: SendEvent, id: RequestId) =
  log.ids[event].add(id)
  log.changed.fire()

proc newSendEventLog(brokerCtx: BrokerContext): SendEventLog =
  let log = SendEventLog(brokerCtx: brokerCtx, changed: newAsyncEvent())
  let onPropagated = proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
    log.record(SendEvent.Propagated, event.requestId)
  let onSent = proc(event: MessageSentEvent) {.async: (raises: []).} =
    log.record(SendEvent.Sent, event.requestId)
  let onError = proc(event: MessageErrorEvent) {.async: (raises: []).} =
    log.record(SendEvent.Failed, event.requestId)
  log.propagatedListener =
    MessagePropagatedEvent.listen(brokerCtx, onPropagated).expect("listen propagated")
  log.sentListener = MessageSentEvent.listen(brokerCtx, onSent).expect("listen sent")
  log.errorListener =
    MessageErrorEvent.listen(brokerCtx, onError).expect("listen error")
  return log

proc teardown(log: SendEventLog) {.async.} =
  await MessagePropagatedEvent.dropListener(log.brokerCtx, log.propagatedListener)
  await MessageSentEvent.dropListener(log.brokerCtx, log.sentListener)
  await MessageErrorEvent.dropListener(log.brokerCtx, log.errorListener)

proc waitEvent(
    log: SendEventLog,
    event: SendEvent,
    task: DeliveryTask,
    timeout = chronos.seconds(5),
): Future[bool] {.async.} =
  ## Waits until `event` is recorded for `task`, or the timeout expires.
  let deadline = Moment.now() + timeout
  while true:
    log.changed.clear()
    if task.requestId in log.ids[event]:
      return true
    let remaining = deadline - Moment.now()
    if remaining <= ZeroDuration or not await log.changed.wait().withTimeout(remaining):
      return task.requestId in log.ids[event]

suite "SendService - mix completion":
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")

  asyncTeardown:
    discard await waku.stop()

  asyncTest "a mixed send that follows a prior plain propagation still emits MessageSent":
    ## A task that emitted `MessagePropagated` on a plain attempt still emits
    ## `MessageSent` when a mix retry succeeds.
    var sent = 0
    let listener = MessageSentEvent
      .listen(
        waku.brokerCtx,
        proc(e: MessageSentEvent) {.async: (raises: []).} =
          inc sent
        ,
      )
      .expect("listen")
    defer:
      await MessageSentEvent.dropListener(waku.brokerCtx, listener)
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let scripted = ScriptedProc(overMix: false) # first attempt: plain
    let service = SendService
      .new(true, waku, manager, scripted, AnonymityLevel.Preferred)
      .expect("SendService.new")
    let task = newTask("plain-then-mix")
    await service.send(task)
    await sleepAsync(chronos.milliseconds(10))
    check task.propagateEventEmitted # plain propagation reported
    check sent == 0 # ... but not a mixed completion
    # then a mix retry of the same task succeeds
    task.state = DeliveryState.NextRoundRetry
    scripted.overMix = true
    await service.trySendMessages()
    service.startSendService()
    await sleepAsync(chronos.milliseconds(20))
    await service.stopSendService()
    check sent == 1 # MessageSent must still fire

  asyncTest "a mixed send reports MessageSent once, though it is reported twice":
    ## `send()` reports the task and caches it, and the next pass reports it again
    ## before it drops it. With reliability on, `sentEventEmitted` keeps
    ## `MessageSent` to one event.
    var sent = 0
    let listener = MessageSentEvent
      .listen(
        waku.brokerCtx,
        proc(e: MessageSentEvent) {.async: (raises: []).} =
          inc sent
        ,
      )
      .expect("listen")
    defer:
      await MessageSentEvent.dropListener(waku.brokerCtx, listener)
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService
      .new(true, waku, manager, ScriptedProc(overMix: true), AnonymityLevel.Preferred)
      .expect("SendService.new") # reliability = on
    let task = newTask("mixed-once")

    await service.send(task)
    await sleepAsync(chronos.milliseconds(10))
    check sent == 1 # reported by send()

    service.startSendService()
    await sleepAsync(chronos.milliseconds(50))
    await service.stopSendService()
    check sent == 1 # ... and not again by the pass that drops it

  asyncTest "reliability off: a mixed send ends the same as a plain one (no MessageSent)":
    ## With store reliability off, a plain and a mixed send both end at
    ## `MessagePropagated`.
    var sent = 0
    let listener = MessageSentEvent
      .listen(
        waku.brokerCtx,
        proc(e: MessageSentEvent) {.async: (raises: []).} =
          inc sent
        ,
      )
      .expect("listen")
    defer:
      await MessageSentEvent.dropListener(waku.brokerCtx, listener)
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService
      .new(false, waku, manager, ScriptedProc(overMix: true), AnonymityLevel.Preferred)
      .expect("SendService.new") # reliability = false
    let task = newTask("mixed-no-reliability")
    await service.send(task)
    service.startSendService()
    await sleepAsync(chronos.milliseconds(20))
    await service.stopSendService()
    check sent == 0

suite "SendService - Store validation batches":
  var waku {.threadvar.}: Waku
  var service {.threadvar.}: SendService

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")
    service = reliableService(waku, ScriptedProc())

  asyncTeardown:
    discard await waku.stop()

  asyncTest "a batch holds one Store page, and the tasks that waited longest come first":
    let now = Moment.now()
    var tasks =
      toSeq(0 ..< 250).mapIt(propagatedAt("t" & $it, now - chronos.seconds(10)))

    # A task asked less than ArchiveTime ago waits for a later batch.
    for (first, size) in [(0, 100), (100, 100), (200, 50)]:
      let batch = service.nextStoreValidationBatch(tasks, now)
      check:
        batch.len == size
        batch[0].requestId == RequestId("t" & $first)
      for task in batch:
        task.lastStoreQueryTime = Opt.some(now)
    check service.nextStoreValidationBatch(tasks, now).len == 0

    # A task never asked comes before the tasks asked since it propagated. A task
    # that propagated after that query comes after them. Ties keep cache order.
    tasks.add(propagatedAt("t250", now - chronos.seconds(10)))
    tasks.add(propagatedAt("t251", now + chronos.seconds(1)))
    let later = service.nextStoreValidationBatch(tasks, now + chronos.seconds(5))
    check:
      later.len == 100
      later[0].requestId == RequestId("t250")
      later[1].requestId == RequestId("t0")
      later[99].requestId == RequestId("t98")

  asyncTest "a task that propagated within ArchiveTime or over mix is not in a batch":
    let now = Moment.now()
    let young = propagatedAt("young", now - chronos.seconds(1))
    let mixed = propagatedAt("mixed", now - chronos.seconds(10))
    mixed.propagatedAnonymously = true
    let plain = propagatedAt("plain", now - chronos.seconds(10))
    check service.nextStoreValidationBatch(@[young, mixed, plain], now) == @[plain]

suite "SendService - Store validation loop":
  ## The Store node answers only after `gate` completes, with the hashes listed in
  ## `storedHashes`. It mounts metadata so the peer manager accepts its cluster.
  var waku {.threadvar.}: Waku
  var storeNode {.threadvar.}: WakuNode
  var gate {.threadvar.}: Future[void]
  var queryStarted {.threadvar.}: Future[void]
  var answered {.threadvar.}: AsyncEvent
  var storedHashes {.threadvar.}: seq[WakuMessageHash]
  var log {.threadvar.}: SendEventLog

  proc gatedStoreHandler(
      req: StoreQueryRequest
  ): Future[StoreQueryResult] {.async, gcsafe.} =
    if not queryStarted.finished():
      queryStarted.complete()
    await gate
    var resp = StoreQueryResponse(
      requestId: req.requestId, statusCode: uint32(StatusCode.SUCCESS)
    )
    for hash in req.messageHashes:
      if hash in storedHashes:
        resp.messages.add(WakuMessageKeyValue(messageHash: hash))
    answered.fire()
    return ok(resp)

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")
    (await waku.start()).isOkOr:
      raiseAssert "waku.start: " & error
    gate = newFuture[void]("store gate")
    queryStarted = newFuture[void]("query started")
    answered = newAsyncEvent()
    storedHashes = @[]
    log = newSendEventLog(waku.brokerCtx)
    storeNode = newTestWakuNode(generateSecp256k1Key())
    storeNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
      raiseAssert "mountMetadata: " & error
    discard await newTestWakuStore(storeNode.switch, gatedStoreHandler)
    await storeNode.start()
    waku.node.peerManager.addServicePeer(
      storeNode.peerInfo.toRemotePeerInfo(), WakuStoreCodec
    )

  asyncTeardown:
    if not gate.finished():
      gate.complete()
    await log.teardown()
    await storeNode.stop()
    discard await waku.stop()

  proc startedService(processor = ScriptedProc()): SendService =
    let service = reliableService(waku, processor)
    service.startSendService()
    return service

  proc sendAged(
      service: SendService, id: string, stored = true
  ): Future[DeliveryTask] {.async.} =
    ## Sends a task and makes it old enough for the next Store query. Unless
    ## `stored` is false, the Store lists its hash.
    let task = newTask(id)
    await service.send(task)
    if stored:
      storedHashes.add(task.msgHash)
    task.firstPropagatedTime = Opt.some(Moment.now() - chronos.seconds(10))
    return task

  asyncTest "a slow Store does not delay the send loop":
    ## A's Store query stays pending while B's failed send is retried.
    let processor = ScriptedProc(retryCalls: @[2])
    let service = startedService(processor)
    defer:
      await service.stopSendService()

    let taskA = await service.sendAged("slow-store-a")
    check:
      taskA.state == DeliveryState.SuccessfullyPropagated
      await queryStarted.withTimeout(chronos.seconds(5))

    let taskB = newTask("slow-store-b")
    await service.send(taskB)
    check:
      taskB.state == DeliveryState.NextRoundRetry
      await log.waitEvent(SendEvent.Propagated, taskB)
      waku.node.peerManager.hasActiveStoreRequest(storeNode.peerInfo.peerId)
      processor.calls == 3

    gate.complete()
    check:
      await log.waitEvent(SendEvent.Sent, taskA)
      taskA.state == DeliveryState.SuccessfullyValidated

  asyncTest "an answer for a task that cleanup already failed is ignored":
    ## A's confirmation arrives after the send loop failed A and removed it.
    let service = startedService()
    defer:
      await service.stopSendService()

    let taskA = await service.sendAged("expire-in-flight")
    check await queryStarted.withTimeout(chronos.seconds(5))

    # Make A old enough for the next cleanup pass to fail it.
    taskA.firstPropagatedTime =
      Opt.some(Moment.now() - MaxTimeInCache - chronos.seconds(1))
    check await log.waitEvent(SendEvent.Failed, taskA)

    # C's confirmation comes from a later query, so A's answer was handled first.
    gate.complete()
    check await answered.wait().withTimeout(chronos.seconds(5))
    let taskC = await service.sendAged("confirmed-after")
    check:
      await log.waitEvent(SendEvent.Sent, taskC)
      taskA.state == DeliveryState.FailedToDeliver

  asyncTest "stopping the service ends a pending Store query":
    let service = startedService()
    discard await service.sendAged("stop-in-flight")
    check await queryStarted.withTimeout(chronos.seconds(5))

    let stopping = service.stopSendService()
    check:
      await stopping.join().withTimeout(chronos.seconds(3))
      not waku.node.peerManager.hasActiveStoreRequest(storeNode.peerInfo.peerId)

  asyncTest "a message the Store does not report yet is asked again, never sent again":
    let processor = ScriptedProc()
    let service = startedService(processor)
    defer:
      await service.stopSendService()
    gate.complete()

    # The first answer does not list the hash.
    let task = await service.sendAged("not-yet-stored", stored = false)
    check await answered.wait().withTimeout(chronos.seconds(5))

    # The next answer lists it. Make the task old enough for that query.
    storedHashes.add(task.msgHash)
    task.lastStoreQueryTime = Opt.some(Moment.now() - chronos.seconds(10))
    check:
      await log.waitEvent(SendEvent.Sent, task)
      task.state == DeliveryState.SuccessfullyValidated
      processor.calls == 1

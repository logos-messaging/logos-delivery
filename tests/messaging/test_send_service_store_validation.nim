{.used.}

import std/sequtils
import chronos, testutils/unittests, results, stew/byteutils

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
    [send_service, send_processor, lightpush_processor, delivery_task],
  logos_delivery/api/events/messaging_client_events
import ../testlib/[futures, testasync, wakunodeconf, wakucore, wakunode]
import ../waku_store/store_utils
import ../waku_lightpush/lightpush_utils
import logos_delivery/waku/waku_lightpush/common
import logos_delivery/waku/node/waku_node/lightpush

## Store-based reliability asks a store node for a propagated message's hash, in
## clear from this node's own address. It must never ask for a mixed message.

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

proc newTask(id: string, pubsubTopic = PubsubTopic("/waku/2/rs/3/0")): DeliveryTask =
  let msg = WakuMessage(
    contentTopic: "/test/1/store-validation/proto",
    payload: id.toBytes(),
    timestamp: 1_700_000_000_000_000_000,
  )
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
  retryCalls: seq[int] ## Calls, counted from 1, that leave the task for a retry.
  resender: BaseSendProcessor ## Sends a task again after a Store miss, nil for none.

method canResend(self: ScriptedProc, task: DeliveryTask): bool {.gcsafe.} =
  return not self.resender.isNil() and self.resender.canResend(task)

method resendImpl(
    self: ScriptedProc, task: DeliveryTask
): Future[void] {.async: (raises: [CancelledError]).} =
  await self.resender.resendImpl(task)

method process(self: ScriptedProc, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  if self.calls in self.retryCalls:
    task.state = DeliveryState.NextRoundRetry
    return
  task.state = DeliveryState.SuccessfullyPropagated
  task.propagatedAnonymously = self.overMix
  if task.firstPropagatedTime.isNone():
    task.firstPropagatedTime = Opt.some(Moment.now())

const FastLoop = chronos.milliseconds(10)
  ## The loop interval of a test service. It keeps each wait for a loop short.

proc reliableService(
    waku: Waku, processor: BaseSendProcessor, maxValidationAge = DeliveryWindow
): SendService =
  ## A service with Store-based reliability on and fast loops.
  let manager =
    RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
  return SendService
    .new(
      true,
      waku,
      manager,
      processor,
      maxValidationAge = maxValidationAge,
      retryInterval = FastLoop,
    )
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

  proc countSent(counter: EventCounter): MessageSentEventListener =
    return MessageSentEvent
      .listen(
        waku.brokerCtx,
        proc(e: MessageSentEvent) {.async: (raises: []).} =
          counter.inc(),
      )
      .expect("listen")

  asyncTest "a mixed send reports MessageSent once":
    ## With reliability on, the exit's reply completes the send.
    let sent = EventCounter()
    let listener = countSent(sent)
    defer:
      await MessageSentEvent.dropListener(waku.brokerCtx, listener)
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService
      .new(true, waku, manager, ScriptedProc(overMix: true), AnonymityLevel.Preferred)
      .expect("SendService.new") # reliability = on
    let task = newTask("mixed-once")

    check service.enqueue(task).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    check await sent.waitCount(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check not await sent.waitCount(2).withTimeout(FUTURE_TIMEOUT_SHORT)

  asyncTest "reliability off: a mixed send ends the same as a plain one (no MessageSent)":
    ## With store reliability off, a plain and a mixed send both end at
    ## `MessagePropagated`.
    let sent = EventCounter()
    let listener = countSent(sent)
    defer:
      await MessageSentEvent.dropListener(waku.brokerCtx, listener)
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService
      .new(false, waku, manager, ScriptedProc(overMix: true), AnonymityLevel.Preferred)
      .expect("SendService.new") # reliability = false
    let task = newTask("mixed-no-reliability")
    check service.enqueue(task).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeout:
      task.propagatedEventEmitted
    check not await sent.waitCount(1).withTimeout(FUTURE_TIMEOUT_SHORT)

suite "SendService - Store validation window":
  var waku {.threadvar.}: Waku
  var log {.threadvar.}: SendEventLog

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")
    log = newSendEventLog(waku.brokerCtx)

  asyncTeardown:
    await log.teardown()
    discard await waku.stop()

  asyncTest "the time while the service is stopped does not count against the window":
    ## The task propagates, then the service stops for longer than the window.
    ## After the restart the task still waits for its Store confirmation.
    let window = chronos.milliseconds(500)
    let service = reliableService(waku, ScriptedProc(), maxValidationAge = window)
    let task = newTask("restart")
    check service.enqueue(task).isOk()
    service.startSendService()
    check await log.waitEvent(SendEvent.Propagated, task)
    await service.stopSendService()
    check:
      task.storeAnswer.isNil()
      task.storeValidationWaited < window
    await sleepAsync(window * 2)

    service.startSendService()
    defer:
      await service.stopSendService()
    check not await log.waitEvent(SendEvent.Failed, task, chronos.milliseconds(100))
    checkUntilTimeout:
      not task.storeAnswer.isNil()
    task.storeAnswer.complete()
    check await log.waitEvent(SendEvent.Sent, task)
    check:
      task.state == DeliveryState.SuccessfullyValidated
      log.ids[SendEvent.Failed].len == 0

  asyncTest "the waits of a task add up to the window":
    ## A task that already waited most of the window fails soon after a restart.
    let window = chronos.milliseconds(500)
    let service = reliableService(waku, ScriptedProc(), maxValidationAge = window)
    let task = newTask("adds-up")
    task.storeValidationWaited = window - chronos.milliseconds(50)
    check service.enqueue(task).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    check await log.waitEvent(SendEvent.Failed, task)
    check:
      task.state == DeliveryState.FailedToDeliver
      task.storeValidationWaited >= window

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
  ## The Store node answers only after `allowAnswer` completes, with the hashes listed in
  ## `storedHashes`. It mounts metadata so the peer manager accepts its cluster.
  var waku {.threadvar.}: Waku
  var storeNode {.threadvar.}: WakuNode
  var allowAnswer {.threadvar.}: Future[void]
  var queryStarted {.threadvar.}: Future[void]
  var answered {.threadvar.}: AsyncEvent
  var storedHashes {.threadvar.}: seq[WakuMessageHash]
  var requests {.threadvar.}: seq[StoreQueryRequest]
  var otherQueries {.threadvar.}: int
  var sameShardQueries {.threadvar.}: int
  var storeFails {.threadvar.}: bool
  var log {.threadvar.}: SendEventLog

  proc delayedStoreHandler(
      req: StoreQueryRequest
  ): Future[StoreQueryResult] {.async, gcsafe.} =
    requests.add(req)
    if storeFails:
      return err(StoreError(kind: ErrorCode.BAD_REQUEST, cause: "test"))
    if not queryStarted.finished():
      queryStarted.complete()
    await allowAnswer
    var resp = StoreQueryResponse(
      requestId: req.requestId, statusCode: uint32(StatusCode.SUCCESS)
    )
    for hash in req.messageHashes:
      if hash in storedHashes:
        resp.messages.add(WakuMessageKeyValue(messageHash: hash))
    answered.fire()
    return ok(resp)

  proc reportingStoreHandler(
      req: StoreQueryRequest
  ): Future[StoreQueryResult] {.async, gcsafe.} =
    ## A second Store node, which lists each hash of the request.
    inc otherQueries
    var resp = StoreQueryResponse(
      requestId: req.requestId, statusCode: uint32(StatusCode.SUCCESS)
    )
    for hash in req.messageHashes:
      resp.messages.add(WakuMessageKeyValue(messageHash: hash))
    return ok(resp)

  proc sameShardStoreHandler(
      req: StoreQueryRequest
  ): Future[StoreQueryResult] {.async, gcsafe.} =
    ## A Store node of the shard of the tasks, which lists each hash of the
    ## request.
    inc sameShardQueries
    var resp = StoreQueryResponse(
      requestId: req.requestId, statusCode: uint32(StatusCode.SUCCESS)
    )
    for hash in req.messageHashes:
      resp.messages.add(WakuMessageKeyValue(messageHash: hash))
    return ok(resp)

  asyncSetup:
    otherQueries = 0
    sameShardQueries = 0
    storeFails = false
    waku = (await Waku.new(testConf())).expect("Waku.new")
    (await waku.start()).isOkOr:
      raiseAssert "waku.start: " & error
    allowAnswer = newFuture[void]("allow-answer")
    queryStarted = newFuture[void]("query started")
    answered = newAsyncEvent()
    storedHashes = @[]
    requests = @[]
    log = newSendEventLog(waku.brokerCtx)
    storeNode = newTestWakuNode(generateSecp256k1Key())
    storeNode.mountMetadata(TestClusterId, @[0'u16, 1]).isOkOr:
      raiseAssert "mountMetadata: " & error
    discard await newTestWakuStore(storeNode.switch, delayedStoreHandler)
    await storeNode.start()
    waku.node.peerManager.addServicePeer(
      storeNode.peerInfo.toRemotePeerInfo(), WakuStoreCodec
    )

  asyncTeardown:
    if not allowAnswer.finished():
      allowAnswer.complete()
    await log.teardown()
    await storeNode.stop()
    discard await waku.stop()

  proc startedService(processor: BaseSendProcessor = ScriptedProc()): SendService =
    let service = reliableService(waku, processor)
    service.startSendService()
    return service

  proc sendAged(
      service: SendService,
      id: string,
      stored = true,
      pubsubTopic = PubsubTopic("/waku/2/rs/3/0"),
  ): Future[DeliveryTask] {.async.} =
    ## Sends a task, waits for the report of its propagation, and makes it old
    ## enough for the next Store query. Unless `stored` is false, the Store lists
    ## its hash.
    let task = newTask(id, pubsubTopic)
    check:
      service.enqueue(task).isOk()
      await log.waitEvent(SendEvent.Propagated, task)
    if stored:
      storedHashes.add(task.msgHash)
    task.firstPropagatedTime = Opt.some(Moment.now() - chronos.seconds(10))
    return task

  asyncTest "a slow Store query does not delay a retry":
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
    check:
      service.enqueue(taskB).isOk()
      await log.waitEvent(SendEvent.Propagated, taskB)
      waku.node.peerManager.hasActiveStoreRequest(storeNode.peerInfo.peerId)
      processor.calls == 3

    allowAnswer.complete()
    check:
      await log.waitEvent(SendEvent.Sent, taskA)
      taskA.state == DeliveryState.SuccessfullyValidated

  asyncTest "an answer for a task whose validation window ended is ignored":
    ## A's confirmation arrives after its validation window ended and the service
    ## failed A.
    let service = reliableService(waku, ScriptedProc(), chronos.seconds(2))
    service.startSendService()
    defer:
      await service.stopSendService()

    let taskA = await service.sendAged("expire-in-flight")
    check await queryStarted.withTimeout(chronos.seconds(5))
    check await log.waitEvent(SendEvent.Failed, taskA)

    # C's confirmation comes from a later query, so A's answer was handled first.
    allowAnswer.complete()
    check await answered.wait().withTimeout(chronos.seconds(5))
    let taskC = await service.sendAged("confirmed-after")
    check:
      await log.waitEvent(SendEvent.Sent, taskC)
      taskA.state == DeliveryState.FailedToDeliver
      taskA.requestId notin log.ids[SendEvent.Sent]

  asyncTest "stopping the service ends a pending Store query":
    let service = startedService()
    discard await service.sendAged("stop-in-flight")
    check await queryStarted.withTimeout(chronos.seconds(5))

    let stopping = service.stopSendService()
    check:
      await stopping.join().withTimeout(chronos.seconds(3))
      not waku.node.peerManager.hasActiveStoreRequest(storeNode.peerInfo.peerId)

  asyncTest "a restart during the Store wait sends nothing again, and the Store confirms the send":
    let processor = ScriptedProc()
    let service = startedService(processor)
    let task = await service.sendAged("restart-in-store-wait")
    check await queryStarted.withTimeout(chronos.seconds(5))

    await service.stopSendService()
    # Old enough for the first Store query after the restart.
    task.lastStoreQueryTime = Opt.some(Moment.now() - chronos.seconds(10))
    service.startSendService()
    defer:
      await service.stopSendService()
    allowAnswer.complete()
    check:
      await log.waitEvent(SendEvent.Sent, task)
      processor.calls == 1
      log.ids[SendEvent.Propagated].countIt(it == task.requestId) == 1

  asyncTest "a message the Store does not report yet is asked again, and the send processor does not run again":
    let processor = ScriptedProc()
    let service = startedService(processor)
    defer:
      await service.stopSendService()
    allowAnswer.complete()

    # The first answer does not list the hash, so the next query goes to any
    # Store node.
    let task = await service.sendAged("not-yet-stored", stored = false)
    check await answered.wait().withTimeout(chronos.seconds(5))
    checkUntilTimeout:
      task.storeMissed

    # The next answer lists it. Make the task old enough for that query.
    storedHashes.add(task.msgHash)
    task.lastStoreQueryTime = Opt.some(Moment.now() - chronos.seconds(10))
    check:
      await log.waitEvent(SendEvent.Sent, task)
      task.state == DeliveryState.SuccessfullyValidated
      processor.calls == 1

  proc sendAgedTogether(
      service: SendService, pubsubTopics: seq[PubsubTopic]
  ): Future[seq[DeliveryTask]] {.async.} =
    ## Sends one task for each shard, and makes them old enough for the same
    ## Store validation batch. The Store lists their hashes.
    var tasks: seq[DeliveryTask]
    for i, pubsubTopic in pubsubTopics:
      let task = newTask("shard-task-" & $i, pubsubTopic)
      check:
        service.enqueue(task).isOk()
        await log.waitEvent(SendEvent.Propagated, task)
      storedHashes.add(task.msgHash)
      tasks.add(task)
    let old = Moment.now() - chronos.seconds(10)
    for task in tasks:
      task.firstPropagatedTime = Opt.some(old)
    return tasks

  proc addStoreNode(
      shards: seq[uint16], handler: StoreQueryRequestHandler
  ): Future[WakuNode] {.async.} =
    ## Starts one more Store node, which the client knows with `shards` and
    ## has no connection to.
    let node = newTestWakuNode(generateSecp256k1Key())
    node.mountMetadata(TestClusterId, shards).isOkOr:
      raiseAssert "mountMetadata: " & error
    discard await newTestWakuStore(node.switch, handler)
    await node.start()
    let info = node.peerInfo.toRemotePeerInfo()
    info.protocols = @[WakuStoreCodec]
    waku.node.switch.peerStore.addPeer(info)
    waku.node.switch.peerStore.setShardInfo(info.peerId, shards)
    return node

  const Shard0 = PubsubTopic("/waku/2/rs/3/0")
  const Shard1 = PubsubTopic("/waku/2/rs/3/1")
  const Shard2 = PubsubTopic("/waku/2/rs/3/2")

  asyncTest "tasks of two shards get one Store query for each shard":
    ## The Store node of the suite announced shards 0 and 1.
    let service = startedService()
    defer:
      await service.stopSendService()
    allowAnswer.complete()

    let tasks = await service.sendAgedTogether(@[Shard0, Shard1])
    check:
      await log.waitEvent(SendEvent.Sent, tasks[0])
      await log.waitEvent(SendEvent.Sent, tasks[1])
      requests.len == 2
      requests.anyIt(it.messageHashes == @[tasks[0].msgHash])
      requests.anyIt(it.messageHashes == @[tasks[1].msgHash])

  asyncTest "a shard that no Store node can have gets its own Store query":
    ## After the first query, the node knows that the Store node announced
    ## shards 0 and 1 only.
    let service = startedService()
    defer:
      await service.stopSendService()
    allowAnswer.complete()

    let first = await service.sendAged("known-shards")
    check await log.waitEvent(SendEvent.Sent, first)
    checkUntilTimeout:
      waku.node.switch.peerStore.peers().anyIt(
        it.peerId == storeNode.peerInfo.peerId and it.shards == @[0'u16, 1]
      )
    requests = @[]

    let tasks = await service.sendAgedTogether(@[Shard0, Shard2])
    check:
      await log.waitEvent(SendEvent.Sent, tasks[0])
      await log.waitEvent(SendEvent.Sent, tasks[1])
      requests.len == 2
      requests.allIt(it.messageHashes.len == 1)

  asyncTest "a Store node of the shard answers when the connected Store node fails":
    ## One more Store node announced shard 0, and one announced shard 2. The
    ## node has a connection to the Store node of the suite, which fails each
    ## query. So a query goes on to the other Store node of shard 0, and not
    ## to the one of shard 2.
    let sameShardStore = await addStoreNode(@[0'u16], sameShardStoreHandler)
    let otherShardStore = await addStoreNode(@[2'u16], reportingStoreHandler)
    defer:
      await allFutures(sameShardStore.stop(), otherShardStore.stop())
    await waku.node.connectToNodes(@[storeNode.peerInfo.toRemotePeerInfo()])
    let service = startedService()
    defer:
      await service.stopSendService()
    allowAnswer.complete()

    storeFails = true
    for i in 0 ..< 5:
      let task = await service.sendAged("store-fails-" & $i)
      check await log.waitEvent(SendEvent.Sent, task)
    check:
      requests.len >= 1
      sameShardQueries >= 5
      otherQueries == 0

  asyncTest "a message that a Store node does not report is asked from any Store node":
    ## The Store node of the suite announced shards 0 and 1, and it does not
    ## list the hash. A second Store node announced another shard, and it
    ## reports each hash. It gets a query only after the miss.
    let otherStore = await addStoreNode(@[2'u16], reportingStoreHandler)
    defer:
      await otherStore.stop()
    let service = startedService()
    defer:
      await service.stopSendService()
    allowAnswer.complete()

    # Each check of a stored task goes to the Store node of its shard.
    for i in 0 ..< 5:
      let stored = await service.sendAged("stored-" & $i)
      check await log.waitEvent(SendEvent.Sent, stored)
    check otherQueries == 0

    let task = await service.sendAged("missed", stored = false)
    checkUntilTimeout:
      task.storeMissed
    check otherQueries == 0

    # Each next query goes to one of the two Store nodes at random.
    for _ in 0 ..< 40:
      if otherQueries > 0:
        break
      task.lastStoreQueryTime = Opt.some(Moment.now() - chronos.seconds(10))
      await sleepAsync(chronos.milliseconds(100))
    check:
      otherQueries > 0
      await log.waitEvent(SendEvent.Sent, task)

  asyncTest "a message the Store does not report is sent again through lightpush":
    let lightpushNode = newTestWakuNode(generateSecp256k1Key())
    lightpushNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
      raiseAssert "mountMetadata: " & error
    var pushed: seq[WakuMessageHash]
    proc pushHandler(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      pushed.add(computeMessageHash(pubsubTopic, message))
      return lightpushSuccessResult(1)

    discard await newTestWakuLightpushNode(lightpushNode.switch, pushHandler)
    await lightpushNode.start()
    defer:
      await lightpushNode.stop()
    waku.node.mountLightPushClient()
    waku.node.peerManager.addServicePeer(
      lightpushNode.peerInfo.toRemotePeerInfo(), WakuLightPushCodec
    )

    let processor =
      ScriptedProc(resender: LightpushSendProcessor.new(waku, waku.brokerCtx))
    let service = startedService(processor)
    defer:
      await service.stopSendService()
    allowAnswer.complete()

    let task = await service.sendAged("resent-after-miss", stored = false)
    checkUntilTimeout:
      task.msgHash in pushed
    check processor.calls == 1

    storedHashes.add(task.msgHash)
    task.lastStoreQueryTime = Opt.some(Moment.now() - chronos.seconds(10))
    check await log.waitEvent(SendEvent.Sent, task)

  asyncTest "a lightpush resend that does not answer does not stop the Store rounds":
    ## A resend waits for a lightpush peer that does not answer. A second task that
    ## the Store reports must get `Sent` in the next round, not after the resend
    ## timeout of 5 s.
    let lightpushNode = newTestWakuNode(generateSecp256k1Key())
    lightpushNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
      raiseAssert "mountMetadata: " & error
    let pushStarted = newFuture[void]("push started")
    let releasePush = newFuture[void]("release push")
    proc stalledHandler(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      if not pushStarted.finished():
        pushStarted.complete()
      await releasePush
      return lightpushSuccessResult(1)

    discard await newTestWakuLightpushNode(lightpushNode.switch, stalledHandler)
    await lightpushNode.start()
    defer:
      # The handler must end before the stop, or the stop of the node waits for it.
      if not releasePush.finished():
        releasePush.complete()
      await lightpushNode.stop()
    waku.node.mountLightPushClient()
    waku.node.peerManager.addServicePeer(
      lightpushNode.peerInfo.toRemotePeerInfo(), WakuLightPushCodec
    )

    let service = startedService(
      ScriptedProc(resender: LightpushSendProcessor.new(waku, waku.brokerCtx))
    )
    defer:
      await service.stopSendService()
    allowAnswer.complete()

    discard await service.sendAged("missed", stored = false)
    check await pushStarted.withTimeout(chronos.seconds(5))

    let stored = await service.sendAged("stored-after-stalled-resend")
    check await log.waitEvent(SendEvent.Sent, stored)

  asyncTest "a message the Store reports is not sent again":
    let lightpushNode = newTestWakuNode(generateSecp256k1Key())
    lightpushNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
      raiseAssert "mountMetadata: " & error
    var pushed: seq[WakuMessageHash]
    proc pushHandler(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      pushed.add(computeMessageHash(pubsubTopic, message))
      return lightpushSuccessResult(1)

    discard await newTestWakuLightpushNode(lightpushNode.switch, pushHandler)
    await lightpushNode.start()
    defer:
      await lightpushNode.stop()
    waku.node.mountLightPushClient()
    waku.node.peerManager.addServicePeer(
      lightpushNode.peerInfo.toRemotePeerInfo(), WakuLightPushCodec
    )

    let service = startedService(
      ScriptedProc(resender: LightpushSendProcessor.new(waku, waku.brokerCtx))
    )
    defer:
      await service.stopSendService()
    allowAnswer.complete()

    let task = await service.sendAged("reported")
    check await log.waitEvent(SendEvent.Sent, task)
    check pushed.len == 0

  asyncTest "a message the Store never reports is sent again at most MaxStoreMissResends times":
    let lightpushNode = newTestWakuNode(generateSecp256k1Key())
    lightpushNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
      raiseAssert "mountMetadata: " & error
    var pushed: seq[WakuMessageHash]
    proc pushHandler(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      pushed.add(computeMessageHash(pubsubTopic, message))
      return lightpushSuccessResult(1)

    discard await newTestWakuLightpushNode(lightpushNode.switch, pushHandler)
    await lightpushNode.start()
    defer:
      await lightpushNode.stop()
    waku.node.mountLightPushClient()
    waku.node.peerManager.addServicePeer(
      lightpushNode.peerInfo.toRemotePeerInfo(), WakuLightPushCodec
    )

    let service = startedService(
      ScriptedProc(resender: LightpushSendProcessor.new(waku, waku.brokerCtx))
    )
    defer:
      await service.stopSendService()
    allowAnswer.complete()

    let task = await service.sendAged("never-reported", stored = false)
    for _ in 0 ..< MaxStoreMissResends + 3:
      task.lastStoreQueryTime = Opt.some(Moment.now() - chronos.seconds(10))
      await sleepAsync(chronos.milliseconds(100))
    check:
      pushed.len == MaxStoreMissResends
      task.resendCount == MaxStoreMissResends

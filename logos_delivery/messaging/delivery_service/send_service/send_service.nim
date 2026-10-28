## The send service. It runs one `deliver` for each queued message, with its
## retries, its admission and its Store confirmation.
##

import std/[algorithm, sequtils, tables, typetraits]
import chronos, chronicles
import brokers/broker_context
import
  ./[send_processor, relay_processor, lightpush_processor, mix_processor, delivery_task],
  logos_delivery/waku/[waku_core, waku_store/common],
  logos_delivery/waku/waku,
  logos_delivery/waku/api/[store, publish],
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager
import logos_delivery/api/events/[kernel_events, messaging_client_events]
import logos_delivery/api/conf/modes
import logos_delivery/messaging/messaging_metrics

{.push raises: [].}

logScope:
  topics = "send service"

const DeliveryWindow* = chronos.minutes(1)
  ## The delivery window: how long an admitted task tries before it fails with no
  ## propagation (`Preferred` gets two, see `maxDeliveryTime`). Also the mix
  ## window of `MixSendProcessor` and the default Store validation window.

proc maxDeliveryTime*(anonymityLevel: AnonymityLevel): timer.Duration =
  ## `Preferred` gets two windows: one for mix, then one for the plain path.
  if anonymityLevel == AnonymityLevel.Preferred:
    DeliveryWindow + DeliveryWindow
  else:
    DeliveryWindow

const DefaultMaxParkedAge* = chronos.minutes(30)
  ## Parked tasks never admitted within this age (from the message timestamp)
  ## are dropped with a `MessageErrorEvent`. Spans a few default RLN epochs.

const DefaultSendQueueCapacity* = 1000
  ## Hard cap on tasks tracked by the send service; further sends are rejected.

const RetryInterval* = chronos.seconds(1)
  ## The pause between two ticks of `retryLoop`, and between two Store validation
  ## rounds.

const ArchiveTime = chronos.seconds(3)
  ## The time a Store node needs to archive a message. A task is asked about in
  ## Store only after this time.

const StoreValidationQueryTimeout = chronos.seconds(15)
  ## Bounds one Store validation query with its dials. It exceeds one
  ## `DefaultDialTimeout`, so a dead Store peer leaves time for another.

const MaxSendsInFlight* = 50
  ## The number of sends that run at the same time. It bounds the open streams
  ## of this node independent of `sendQueueCapacity`.

type SendService* = ref object of RootObj
  brokerCtx: BrokerContext
  deliveryTasks: OrderedTable[WakuMessageHash, DeliveryTask]
    ## Each task that did not get its last event, by message hash, in queue order.
    ## A restart starts the tasks in this order.
  running: bool
    ## True while each task has its `deliver`. While false, `enqueue` keeps each
    ## task until `startSendService`.
  admissionLock: AsyncLock
    ## One task at a time runs `admitAndProve` (see `runAdmission`).
  sendSlots: AsyncSemaphore
    ## One slot for each send that runs. `process` runs with a slot held, so at
    ## most `maxSendsInFlight` sends run at the same time.
  retryTick: AsyncEvent
    ## `retryNow` fires it, and each task that waits on it starts its next attempt.
    ## Chronos wakes the waiters in the order that they started to wait, so the
    ## parked tasks reach `admissionLock` in the order that they parked.
  retryLoopHandle: Future[void] ## The `retryLoop`, nil while the service does not run.
  seenMsgListener: MessageSeenEventListener
    ## Calls `markSeen` for each message that this node receives from the network.
  attempts: int
    ## The number of attempts that ended, in admission or in a send. Only tests
    ## read it.
  subscribeOnSend: bool ## True only for the None anonymity level.
  sendProcessor: BaseSendProcessor
  rateLimitManager: RateLimitManager
    ## Charges first transmissions against the per-epoch budget; re-publishes
    ## are free.

  waku: Waku
  checkStoreForMessages: bool
  storeValidationHandle: Future[void]
    ## The Store validation loop. Nil when Store-based reliability is off.
  maxDeliveryTime*: timer.Duration
    ## How long an admitted task may keep trying before it is failed.
  maxParkedAge*: timer.Duration
    ## How old a never-admitted (parked) task may get before it is failed.
  maxValidationAge*: timer.Duration
    ## How long a task may wait for a Store confirmation before it fails. The
    ## time while the service is stopped does not count.
  archiveTime*: timer.Duration
    ## A task is asked about in Store only once its propagation and its last
    ## Store query are older than this, giving a Store node time to archive it.
    ## Also the pause of the Store validation loop while no Store peer is available.
  sendQueueCapacity*: int
  retryInterval: timer.Duration

proc setupSendProcessorChain*(
    waku: Waku, anonymityLevel: AnonymityLevel
): Result[BaseSendProcessor, string] =
  let brokerCtx = waku.brokerCtx
  let isRelayAvail = waku.hasRelay()
  let isLightPushAvail = waku.hasLightpush()

  var processors = newSeq[BaseSendProcessor]()

  case anonymityLevel
  of AnonymityLevel.None:
    discard
  of AnonymityLevel.Preferred, AnonymityLevel.Required:
    if not isLightPushAvail:
      return err("Mix sending needs a lightpush client, which is not mounted")

    let mixProcessor: BaseSendProcessor =
      MixSendProcessor.new(waku, brokerCtx, anonymityLevel, DeliveryWindow)
    if anonymityLevel == AnonymityLevel.Required:
      return ok(mixProcessor)

    processors.add(mixProcessor)

  if isRelayAvail:
    let publishProc = waku.relayPushHandler()
    processors.add(
      RelaySendProcessor.new(isLightPushAvail, publishProc, waku, brokerCtx)
    )
  if isLightPushAvail:
    processors.add(LightpushSendProcessor.new(waku, brokerCtx))

  if processors.len == 0:
    return err("No valid send processor found for the delivery task")

  var currentProcessor: BaseSendProcessor = processors[0]
  for i in 1 ..< processors.len:
    currentProcessor.chain(processors[i])
    currentProcessor = processors[i]
    trace "Send processor chain", index = i, processor = type(processors[i]).name

  return ok(processors[0])

proc new*(
    T: typedesc[SendService],
    preferP2PReliability: bool,
    waku: Waku,
    rateLimitManager: RateLimitManager,
    sendProcessor: BaseSendProcessor,
    anonymityLevel: AnonymityLevel = AnonymityLevel.None,
    maxParkedAge: timer.Duration = DefaultMaxParkedAge,
    sendQueueCapacity: int = DefaultSendQueueCapacity,
    maxValidationAge: timer.Duration = DeliveryWindow,
    retryInterval: timer.Duration = RetryInterval,
    maxSendsInFlight: int = MaxSendsInFlight,
): Result[T, string] =
  # With zero, `retryLoop` ticks at each turn of the event loop, and the waiting
  # tasks retry with no pause.
  if retryInterval <= ZeroDuration:
    return err("retryInterval must be positive")
  if maxSendsInFlight <= 0:
    return err("maxSendsInFlight must be positive")

  let checkStoreForMessages = preferP2PReliability and waku.isStoreMounted()

  let sendService = SendService(
    brokerCtx: waku.brokerCtx,
    deliveryTasks: initOrderedTable[WakuMessageHash, DeliveryTask](),
    admissionLock: newAsyncLock(),
    sendSlots: newAsyncSemaphore(maxSendsInFlight),
    retryTick: newAsyncEvent(),
    sendProcessor: sendProcessor,
    rateLimitManager: rateLimitManager,
    waku: waku,
    checkStoreForMessages: checkStoreForMessages,
    maxDeliveryTime: maxDeliveryTime(anonymityLevel),
    maxParkedAge: maxParkedAge,
    maxValidationAge: maxValidationAge,
    archiveTime: ArchiveTime,
    sendQueueCapacity: sendQueueCapacity,
    retryInterval: retryInterval,
    subscribeOnSend: anonymityLevel == AnonymityLevel.None,
  )

  return ok(sendService)

proc subscribesOnSend*(self: SendService): bool =
  return self.subscribeOnSend

func isFull*(self: SendService): bool =
  return self.deliveryTasks.len >= self.sendQueueCapacity

proc storeConfirmationExpected(self: SendService, task: DeliveryTask): bool =
  ## True when a plain send of this task would wait for a store confirmation:
  ## reliability is on and the message is not ephemeral.
  return self.checkStoreForMessages and not task.isEphemeral()

proc awaitsStoreValidation*(self: SendService, task: DeliveryTask): bool =
  ## True while a propagated task still needs a store node to confirm it. A task
  ## that went out over mix never does: the store query would carry its hash in
  ## clear from this node's own address.
  return
    self.storeConfirmationExpected(task) and
    task.state == DeliveryState.SuccessfullyPropagated and not task.propagatedAnonymously

func storeValidationKey(task: DeliveryTask): Moment =
  ## The last Store query time, or the first propagation for a task never asked.
  if task.lastStoreQueryTime.isSome():
    task.lastStoreQueryTime.get()
  else:
    task.firstPropagatedTime.get()

proc nextStoreValidationBatch*(
    self: SendService, tasks: openArray[DeliveryTask], now: Moment
): seq[DeliveryTask] =
  ## Selects up to one Store page of tasks that await Store validation and whose
  ## propagation and last query are older than `archiveTime`. The tasks that
  ## waited longest come first.
  const batchSize = int(MaxPageSize)
  var eligible: seq[DeliveryTask]
  for task in tasks:
    if not self.awaitsStoreValidation(task):
      continue
    if task.firstPropagatedTime.isNone() or
        now - task.firstPropagatedTime.get() <= self.archiveTime:
      continue
    if task.lastStoreQueryTime.isSome() and
        now - task.lastStoreQueryTime.get() <= self.archiveTime:
      continue
    eligible.add(task)
  eligible.sort(
    proc(a, b: DeliveryTask): int =
      cmp(storeValidationKey(a), storeValidationKey(b))
  )
  if eligible.len > batchSize:
    eligible.setLen(batchSize)
  return eligible

func storeAnswerPending(task: DeliveryTask): bool =
  ## True while the `deliver` of the task waits for a Store confirmation.
  return not task.storeAnswer.isNil() and not task.storeAnswer.finished()

proc checkMsgsInStore(self: SendService, batch: seq[DeliveryTask]) {.async.} =
  ## Asks a Store peer about one batch and confirms the tasks that it reports.
  let now = Moment.now()
  for task in batch:
    task.lastStoreQueryTime = Opt.some(now)

  # TODO: confirm hash format for store query!!!
  let query = self.waku.storeQueryToAny(
    StoreQueryRequest(
      includeData: false,
      messageHashes: batch.mapIt(it.msgHash),
      paginationLimit: Opt.some(uint64(batch.len)),
    )
  )
  if not await query.withTimeout(StoreValidationQueryTimeout):
    debug "Store validation query timed out", messageCount = batch.len
    return

  let storeResp: StoreQueryResponse = query.read().valueOr:
    debug "Failed to get store validation for messages",
      messageCount = batch.len, error = $error
    return

  # The Store peer decides which hashes its answer lists, and it can list hashes
  # that this node did not ask about. Only a task whose `deliver` waits for a Store
  # confirmation takes a hash from the answer, so a message sent over mix is never
  # confirmed.
  for item in storeResp.messages:
    let task = self.deliveryTasks.getOrDefault(item.messageHash)
    if not task.isNil() and task.storeAnswerPending():
      task.storeAnswer.complete()

proc storeValidationLoop(self: SendService) {.async: (raises: [CancelledError]).} =
  ## Confirms propagated tasks against Store, one batch per round, apart from the
  ## sends, so that a slow Store peer does not delay them.
  while true:
    var delay = self.retryInterval
    try:
      let batch = self.nextStoreValidationBatch(
        toSeq(self.deliveryTasks.values).filterIt(it.storeAnswerPending()), Moment.now()
      )
      if batch.len > 0:
        if self.waku.hasStorePeer():
          await self.checkMsgsInStore(batch)
        else:
          debug "Skipping store validation, no store peer available",
            messageCount = batch.len
          delay = self.archiveTime
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      error "Exception in a Store validation round", error = exc.msg
    await sleepAsync(delay)

proc loggedHash(task: DeliveryTask): string =
  ## The hash for INFO and ERROR records, withheld once the task is anonymized.
  if task.anonymized:
    "withheld"
  else:
    task.msgHash.to0xHex()

func isQueued(self: SendService, task: DeliveryTask): bool =
  ## True when `task` itself is in the send queue.
  return self.deliveryTasks.getOrDefault(task.msgHash) == task

func finish(self: SendService, task: DeliveryTask) =
  ## Removes a task that got its last event.
  if self.isQueued(task):
    self.deliveryTasks.del(task.msgHash)

proc fail(self: SendService, task: DeliveryTask, errorDesc: string) =
  ## Fails the task with `MessageErrorEvent`, its last event.
  task.state = DeliveryState.FailedToDeliver
  task.errorDesc = errorDesc
  MessageErrorEvent.emit(
    self.brokerCtx, task.requestId, task.msgHash.to0xHex(), errorDesc
  )
  self.finish(task)

proc failExpired(self: SendService, task: DeliveryTask): bool =
  ## Fails the task when its delivery window or its parked age ended.
  if task.isDeliveryTimedOut(self.maxDeliveryTime):
    # A processor that leaves a task for a retry can write why in `errorDesc`,
    # as the mix processor does for a `Required` task that mix cannot attempt yet.
    # Report that reason if set.
    let errorDesc =
      if task.errorDesc.len > 0:
        task.errorDesc
      else:
        "Unable to send within retry time window"
    error "Failed to send message",
      requestId = task.requestId,
      msgHash = task.loggedHash(),
      error = errorDesc,
      age = task.admissionAge()
    self.fail(task, errorDesc)
    return true
  if task.isParkedExpired(self.maxParkedAge):
    error "Failed to send message",
      requestId = task.requestId,
      msgHash = task.loggedHash(),
      error = "Parked message too old",
      age = task.messageAge()
    self.fail(
      task, "No rate-limit budget came within the maximum wait of a queued message"
    )
    return true
  return false

proc reportPropagated(self: SendService, task: DeliveryTask) =
  ## Emits `MessagePropagatedEvent`, and `MessageSentEvent` for a mixed send that
  ## a plain send would confirm in Store.
  # INFO lines reach log collectors, where a hash would tie this node to an
  # anonymized message; `MixSendProcessor` still logs it at DEBUG.
  info "Message successfully propagated",
    requestId = task.requestId, msgHash = task.loggedHash()
  MessagePropagatedEvent.emit(self.brokerCtx, task.requestId, task.msgHash.to0xHex())
  task.propagatedEventEmitted = true
  if task.propagatedAnonymously and self.storeConfirmationExpected(task):
    # The exit's reply completes a mixed send when a plain send would wait for
    # a store confirmation, so both paths end with the same event. The INFO line
    # omits the hash.
    info "Message successfully sent over mix", requestId = task.requestId
    MessageSentEvent.emit(self.brokerCtx, task.requestId, task.msgHash.to0xHex())

proc reportTaskQueued(self: SendService, task: DeliveryTask) =
  ## Emits `MessageQueuedEvent` once for a task that waits for epoch budget.
  if task.queuedEventEmitted:
    return

  info "Message queued for rate-limit budget",
    requestId = task.requestId, msgHash = task.loggedHash()
  MessageQueuedEvent.emit(self.brokerCtx, task.requestId, task.msgHash.to0xHex())
  task.queuedEventEmitted = true

proc admitAndProve(self: SendService, task: DeliveryTask): Future[bool] {.async.} =
  ## Charges the epoch budget, then attaches the RLN proof, so a message over the
  ## budget reserves no RLN message id. It charges a task once for each proof. Returns false
  ## when the task waits for its next attempt or failed.
  if not self.sendProcessor.checkBeforeAdmission(task):
    return false

  if task.firstAdmittedTime.isNone():
    # Ephemeral traffic is shed rather than queued so it cannot eat into the
    # budget left for durable messages.
    if task.isEphemeral():
      let quotaState = await self.rateLimitManager.quotaState()
      if quotaState != QuotaState.Normal:
        debug "Dropping ephemeral message as we are approaching rate-limit quota",
          requestId = task.requestId,
          msgHash = task.msgHash.to0xHex(),
          quotaState = quotaState
        task.state = DeliveryState.FailedToDeliver
        task.errorDesc = "Ephemeral message dropped: rate limit " & $quotaState
        return false

    (await self.rateLimitManager.admit(task.msg.payload)).isOkOr:
      debug "Over rate-limit budget, task waits for the epoch to roll",
        requestId = task.requestId, msgHash = task.msgHash.to0xHex()
      self.reportTaskQueued(task)
      return false
    task.firstAdmittedTime = Opt.some(Moment.now())

  # The message timestamp sets its epoch, so a backend past that epoch or out of
  # budget fails the task. Other errors wait for a retry.
  task.msg = (await self.waku.attachRlnProof(task.msg)).valueOr:
    case error.kind
    of RlnErrorKind.Permanent, RlnErrorKind.BudgetExhausted:
      task.state = DeliveryState.FailedToDeliver
      task.errorDesc = "Failed to attach RLN proof: " & $error
    of RlnErrorKind.NotReady, RlnErrorKind.Transient:
      debug "Failed to attach RLN proof, the task waits for a retry",
        requestId = task.requestId, msgHash = task.msgHash.to0xHex(), error = $error
    return false

  return true

func needsAdmission(self: SendService, task: DeliveryTask): bool =
  ## True when the task needs an epoch budget charge or an RLN proof. A task that
  ## needs neither does not wait for another task in `admitAndProve`.
  return task.firstAdmittedTime.isNone() or self.waku.needsRlnProof(task.msg)

proc runAdmission(
    self: SendService, task: DeliveryTask
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Runs `admitAndProve` with `admissionLock` held. The budget check reads the
  ## RLN quota, which counts only the message ids that earlier proofs reserved,
  ## so each task reserves its id before the next task checks the budget.
  await self.admissionLock.acquire()
  try:
    return await self.admitAndProve(task)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    error "Exception in admission",
      requestId = task.requestId, msgHash = task.loggedHash(), error = exc.msg
    return false
  finally:
    try:
      self.admissionLock.release()
    except AsyncLockError:
      discard

proc retryNow(self: SendService) =
  ## Starts the next attempt of each task that waits for one.
  self.retryTick.fire()
  self.retryTick.clear()

proc retryLoop(self: SendService) {.async: (raises: [CancelledError]).} =
  ## Runs `retryNow` each `retryInterval`.
  while true:
    await sleepAsync(self.retryInterval)
    self.retryNow()

proc completeIfSeen(task: DeliveryTask): bool =
  ## Completes a task whose message this node received from the network after a
  ## mix attempt started, as a mix send whose reply arrived. Returns true when it
  ## completes the task.
  if not task.seenOnNetwork or task.firstPropagatedTime.isSome():
    return false
  debug "Message seen on the network, the mix send is complete",
    requestId = task.requestId, msgHash = task.msgHash.to0xHex()
  task.state = DeliveryState.SuccessfullyPropagated
  task.propagatedAnonymously = true
  task.firstPropagatedTime = Opt.some(Moment.now())
  return true

proc sendUntilPropagated(
    self: SendService, task: DeliveryTask
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Makes the first attempt at once, then one attempt at each tick of
  ## `retryLoop`, until the task propagates. Returns false when the task failed.
  while true:
    if task.completeIfSeen():
      self.reportPropagated(task)
      return true
    if not self.needsAdmission(task) or await self.runAdmission(task):
      await self.sendSlots.acquire()
      try:
        await self.sendProcessor.process(task)
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        # The send path returns remote errors as results, so an exception is a local
        # fault.
        error "Exception in a send attempt",
          requestId = task.requestId, msgHash = task.loggedHash(), error = exc.msg
      finally:
        self.sendSlots.release2()
    self.attempts.inc()
    # A task with `seenOnNetwork` is complete, also when its attempt failed.
    discard task.completeIfSeen()
    case task.state
    of DeliveryState.SuccessfullyPropagated:
      self.reportPropagated(task)
      return true
    of DeliveryState.FailedToDeliver:
      # A mix exit may have published the message even though its reply was lost.
      error "Failed to send message",
        requestId = task.requestId, msgHash = task.loggedHash(), error = task.errorDesc
      self.fail(task, task.errorDesc)
      return false
    else:
      # All other states wait for the next attempt: `process` left `NextRoundRetry`,
      # the admission did not admit the task, or an exception ended `process` before
      # it moved `Entry` or `FallbackRetry`.
      task.state = DeliveryState.NextRoundRetry
    if self.failExpired(task):
      return false
    await self.retryTick.wait()

proc waitForStoreValidation(
    self: SendService, task: DeliveryTask
) {.async: (raises: [CancelledError]).} =
  ## Waits for a Store node to report the message, until the waits of the task
  ## add up to `maxValidationAge`.
  let left = self.maxValidationAge - task.storeValidationWaited
  let started = Moment.now()
  task.storeAnswer = newFuture[void]("store confirmation")
  try:
    if left > ZeroDuration and await task.storeAnswer.withTimeout(left):
      task.state = DeliveryState.SuccessfullyValidated
      # An anonymized task gets here only through the clear republish of a
      # `Preferred` send whose mix reply was lost.
      info "Message successfully sent",
        requestId = task.requestId, msgHash = task.loggedHash()
      MessageSentEvent.emit(self.brokerCtx, task.requestId, task.msgHash.to0xHex())
      self.finish(task)
    else:
      debug "Message propagated but not validated by a store node within time window; stop trying.",
        requestId = task.requestId,
        msgHash = task.msgHash.to0xHex(),
        waited = task.storeValidationWaited + (Moment.now() - started)
      recordStoreValidationTimeout()
      self.fail(
        task,
        "Propagated but not confirmed by a store node within the store validation window",
      )
  finally:
    task.storeValidationWaited = task.storeValidationWaited + (Moment.now() - started)
    task.storeAnswer = nil

proc deliver(
    self: SendService, task: DeliveryTask
) {.async: (raises: [CancelledError]).} =
  ## Sends the task until it propagates, then waits for a Store confirmation
  ## when one is expected. Each event goes out when its step ends.
  try:
    if not task.propagatedEventEmitted:
      if not await self.sendUntilPropagated(task):
        return
    if self.awaitsStoreValidation(task):
      await self.waitForStoreValidation(task)
    else:
      self.finish(task)
  except CancelledError as exc:
    # A cancel can stop `process` before it moves `Entry` or `FallbackRetry`.
    # The task waits for its next attempt, as after any other attempt.
    if task.state == DeliveryState.Entry or task.state == DeliveryState.FallbackRetry:
      task.state = DeliveryState.NextRoundRetry
    raise exc

func isRunning(task: DeliveryTask): bool =
  ## True while the `deliver` of the task runs.
  return not task.deliverHandle.isNil() and not task.deliverHandle.finished()

proc startDeliverSoon(self: SendService, task: DeliveryTask) =
  ## Starts `deliver` in a later turn of the event loop, when the service runs
  ## then. The caller of `enqueue` gets its result before any event of the task.
  callSoon(
    proc(udata: pointer) {.gcsafe, raises: [].} =
      if self.running and not task.isRunning() and self.isQueued(task):
        task.deliverHandle = self.deliver(task)
  )

proc enqueue*(self: SendService, task: DeliveryTask): Result[RequestId, string] =
  ## Puts `task` in the send queue and returns its request id. It makes no
  ## attempt and emits no event, so the caller gets the result first. The network
  ## keeps one copy of a message, so a message that the send queue already has
  ## gets the request id of the queued task.
  assert(not task.isNil(), "task for enqueue must not be nil")
  let queued = self.deliveryTasks.getOrDefault(task.msgHash)
  if not queued.isNil():
    debug "Message already in the send queue",
      requestId = queued.requestId, msgHash = task.msgHash.to0xHex()
    return ok(queued.requestId)
  if self.isFull():
    return err("Send queue full, retry later")

  debug "Task added to the send queue",
    requestId = task.requestId, msgHash = task.msgHash.to0xHex()
  self.deliveryTasks[task.msgHash] = task
  self.startDeliverSoon(task)
  return ok(task.requestId)

proc markSeen(self: SendService, pubsubTopic: PubsubTopic, msg: WakuMessage) =
  ## Marks the task of a message that this node received from the network, when
  ## the task had a mix attempt and no plain attempt. A plain attempt puts
  ## the message on the network in the clear, so a copy of it tells nothing
  ## about the mix send.
  if self.deliveryTasks.len == 0:
    return
  let task = self.deliveryTasks.getOrDefault(computeMessageHash(pubsubTopic, msg))
  if task.isNil() or not task.anonymized or task.plainAttempted:
    return
  task.seenOnNetwork = true

proc startSendService*(self: SendService) =
  ## Starts each task. Call it after `stopSendService` ends. A call while the
  ## service runs does nothing.
  if self.running:
    return
  self.running = true
  for task in self.deliveryTasks.values:
    self.startDeliverSoon(task)
  self.retryLoopHandle = self.retryLoop()
  self.seenMsgListener = MessageSeenEvent.listen(
    self.brokerCtx,
    proc(event: MessageSeenEvent) {.async: (raises: []).} =
      self.markSeen(event.topic, event.message),
  ).valueOr:
    # Without the listener, only the reply of the exit completes a mix send.
    error "Failed to set MessageSeenEvent listener", error = error
    MessageSeenEventListener()
  if self.checkStoreForMessages:
    self.storeValidationHandle = self.storeValidationLoop()

proc stopSendService*(self: SendService) {.async: (raises: []).} =
  ## Cancels each `deliver`, `retryLoop` and the Store validation loop, and drops
  ## the `MessageSeenEvent` listener. The tasks stay in the send queue with no
  ## event, and `startSendService` starts them again.
  self.running = false
  var handles: seq[Future[void]]
  for handle in [self.retryLoopHandle, self.storeValidationHandle]:
    if not handle.isNil():
      handles.add(handle)
  self.retryLoopHandle = nil
  self.storeValidationHandle = nil
  for task in self.deliveryTasks.values:
    if task.isRunning():
      handles.add(task.deliverHandle)
  await cancelAndWait(handles)
  await MessageSeenEvent.dropListener(self.brokerCtx, self.seenMsgListener)
  self.seenMsgListener = MessageSeenEventListener()

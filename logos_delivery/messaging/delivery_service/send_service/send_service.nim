## The send service. It runs one `deliver` for each queued message, with its
## retries, its admission and its Store confirmation.
##

import std/[algorithm, sequtils, sets, tables, typetraits]
import chronos, chronicles
import brokers/broker_context
import
  ./[send_processor, relay_processor, lightpush_processor, mix_processor, delivery_task],
  logos_delivery/waku/[waku_core, waku_store/common],
  logos_delivery/waku/waku,
  logos_delivery/waku/api/[store, publish],
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager
import logos_delivery/api/events/messaging_client_events
import logos_delivery/api/conf/modes
import logos_delivery/messaging/messaging_metrics

{.push raises: [].}

logScope:
  topics = "send service"

const DeliveryWindow* = chronos.seconds(15)
  ## How long after its message timestamp a task may try to propagate, mix and
  ## its plain fallback included. Store and RLN validators refuse a message more
  ## than 20 s off their clock, so a later attempt would be refused anyway.

const MixWindow* = chronos.seconds(10)
  ## The part of `DeliveryWindow` that a `Preferred` task spends on mix before it
  ## takes the plain path, which keeps the rest of the window.

const StoreValidationWindow* = chronos.seconds(30)
  ## The default wait for a Store node to report a propagated message. The
  ## delivery window does not bound it.

const RetryInterval* = chronos.seconds(1)
  ## The pause between two ticks of `retryLoop`, and between two Store validation
  ## rounds.

const ArchiveTime = chronos.seconds(3)
  ## The time a Store node needs to archive a message. A task is asked about in
  ## Store only after this time.

const StoreValidationQueryTimeout = chronos.seconds(15)
  ## Bounds one Store validation query with its dials. It exceeds one
  ## `DefaultDialTimeout`, so a dead Store peer leaves time for another.

const MaxStoreMissResends* = 3 ## The most resends of one message after a Store miss.

const MaxSendsInFlight* = 50
  ## The most sends with no last event. `send` refuses the next one with
  ## `QueueFull`. It bounds the memory and the open streams of the node, also
  ## without a rate limit. A send with Store validation keeps its place until a
  ## Store node confirms it, up to 30 s after it propagated.

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
  retryTick: AsyncEvent
    ## `retryNow` fires it, and each task that waits on it starts its next attempt.
    ## Chronos wakes the waiters in the order that they started to wait, so the
    ## waiting tasks reach `admissionLock` in the order that they started to wait.
  retryLoopHandle: Future[void] ## The `retryLoop`, nil while the service does not run.
  attempts: int
    ## The number of attempts that ended, in admission or in a send. Only tests
    ## read it.
  sendProcessor: BaseSendProcessor
  rateLimitManager: RateLimitManager
    ## Charges first transmissions against the per-epoch budget; re-publishes
    ## are free.

  waku: Waku
  checkStoreForMessages: bool
  storeValidationHandle: Future[void]
    ## The Store validation loop. Nil when Store-based reliability is off.
  resends: Table[WakuMessageHash, Future[void]]
    ## The resend of each task, by message hash, while it runs. The
    ## Store validation loop does not wait for them, and `stopSendService`
    ## cancels them.
  deliveryWindow*: timer.Duration
    ## How long after its message timestamp a task may try to propagate.
  maxValidationAge*: timer.Duration
    ## How long a task may wait for a Store confirmation before it fails. The
    ## time while the service is stopped does not count.
  archiveTime*: timer.Duration
    ## A task is asked about in Store only once its propagation and its last
    ## Store query are older than this, giving a Store node time to archive it.
    ## Also the pause of the Store validation loop while no Store peer is available.
  maxSendsInFlight*: int
    ## The most tasks in the send queue, `MaxSendsInFlight` by default.
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
      MixSendProcessor.new(waku, brokerCtx, anonymityLevel, MixWindow)
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
    maxValidationAge: timer.Duration = StoreValidationWindow,
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
    retryTick: newAsyncEvent(),
    sendProcessor: sendProcessor,
    rateLimitManager: rateLimitManager,
    waku: waku,
    checkStoreForMessages: checkStoreForMessages,
    deliveryWindow: DeliveryWindow,
    maxValidationAge: maxValidationAge,
    archiveTime: ArchiveTime,
    maxSendsInFlight: maxSendsInFlight,
    retryInterval: retryInterval,
  )

  return ok(sendService)

func isFull*(self: SendService): bool =
  return self.deliveryTasks.len >= self.maxSendsInFlight

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

proc startResend(self: SendService, task: DeliveryTask) =
  ## Starts the resend of `task` and does not wait for it. A task gets no second
  ## resend while its last resend runs, and at most `MaxStoreMissResends` in all,
  ## so a peer that does not answer holds one resend for each task and a message
  ## that the Store lags on is not sent again every round.
  if task.resendCount >= MaxStoreMissResends or self.sendProcessor.isNil():
    return
  # A resend reuses the timestamp of `send`, so after the delivery window the
  # validators would refuse it.
  if task.messageAge() > self.deliveryWindow:
    return
  self.resends.withValue(task.msgHash, resend):
    if not resend[].finished():
      return
  self.resends[task.msgHash] = self.sendProcessor.resend(task)

proc dropFinishedResends(self: SendService) =
  ## Removes the resends that ended.
  var ended: seq[WakuMessageHash]
  for msgHash, resend in self.resends:
    if resend.finished():
      ended.add(msgHash)
  for msgHash in ended:
    self.resends.del(msgHash)

proc queryStoreForTasks(
    self: SendService, shards: seq[PubsubTopic], tasks: seq[DeliveryTask]
) {.async.} =
  ## Sends one Store query about `tasks`, whose messages are in `shards`.
  ## Confirms the tasks the answer reports and resends the others.
  ## With no `shards`, any Store peer can answer.
  # TODO: confirm hash format for store query!!!
  let query = self.waku.storeQueryToAny(
    StoreQueryRequest(
      includeData: false,
      messageHashes: tasks.mapIt(it.msgHash),
      paginationLimit: Opt.some(uint64(tasks.len)),
    ),
    shards,
  )
  if not await query.withTimeout(StoreValidationQueryTimeout):
    debug "Store validation query timed out", messageCount = tasks.len
    return

  let storeResp: StoreQueryResponse = query.read().valueOr:
    debug "Failed to get store validation for messages",
      messageCount = tasks.len, error = $error
    return

  # The Store peer decides which hashes its answer lists, and it can list hashes
  # that this node did not ask about. Only a task whose `deliver` waits for a Store
  # confirmation takes a hash from the answer, so a message sent over mix is never
  # confirmed.
  var reported: HashSet[WakuMessageHash]
  for item in storeResp.messages:
    reported.incl(item.messageHash)
    let task = self.deliveryTasks.getOrDefault(item.messageHash)
    if not task.isNil() and task.storeAnswerPending():
      task.storeAnswer.complete()

  # A resend can wait for its timeout on a lightpush peer that
  # does not answer. The loop does not wait for the resends, so that a slow
  # lightpush peer does not stop the Store rounds of the other tasks.
  self.dropFinishedResends()
  if storeResp.paginationCursor.isSome():
    # The answer is partial: a hash that it lacks can be on the next page.
    return
  for task in tasks:
    if task.msgHash notin reported and task.storeAnswerPending():
      task.storeMissed = true
      self.startResend(task)

proc checkMsgsInStore(self: SendService, batch: seq[DeliveryTask]) {.async.} =
  ## Asks Store about one batch. The tasks that a Store peer did not report go
  ## in one query, which can ask each Store peer. The other tasks go in one
  ## query for each shard.
  let now = Moment.now()
  var missed: seq[DeliveryTask]
  var byShard: OrderedTable[PubsubTopic, seq[DeliveryTask]]
  for task in batch:
    task.lastStoreQueryTime = Opt.some(now)
    if task.storeMissed:
      missed.add(task)
    else:
      byShard.mgetOrPut(task.pubsubTopic, @[]).add(task)
  var checks: seq[Future[void]]
  if missed.len > 0:
    checks.add(self.queryStoreForTasks(@[], missed))
  for shard, tasks in byShard:
    checks.add(self.queryStoreForTasks(@[shard], tasks))
  try:
    for check in checks:
      await check
  finally:
    let running = checks.filterIt(not it.finished())
    if running.len > 0:
      await noCancel allFutures(running.mapIt(it.cancelAndWait()))

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

func isQueued(self: SendService, task: DeliveryTask): bool =
  ## True when `task` itself is in the send queue.
  return self.deliveryTasks.getOrDefault(task.msgHash) == task

proc finish(self: SendService, task: DeliveryTask) =
  ## Removes a task that got its last event, and gives back a charge that the
  ## task did not use.
  if self.isQueued(task):
    if task.chargeUnused:
      self.rateLimitManager.release(task.charge)
      task.chargeUnused = false
    self.deliveryTasks.del(task.msgHash)

proc fail(
    self: SendService,
    task: DeliveryTask,
    errorDesc: string,
    kind = MessageErrorKind.NotPropagated,
) =
  ## Fails the task with `MessageErrorEvent`, its last event. The task leaves
  ## the send queue first, so a listener of the event can send again at once.
  task.state = DeliveryState.FailedToDeliver
  task.errorDesc = errorDesc
  self.finish(task)
  MessageErrorEvent.emit(self.brokerCtx, task.msgHash.to0xHex(), kind, errorDesc)

proc failExpired(self: SendService, task: DeliveryTask): bool =
  ## Fails the task when its delivery window ended.
  if task.isDeliveryTimedOut(self.deliveryWindow):
    # A processor that leaves a task for a retry can write why in `errorDesc`,
    # as the mix processor does for a `Required` task that mix cannot attempt yet.
    # Report that reason if set.
    let errorDesc =
      if task.errorDesc.len > 0:
        task.errorDesc
      else:
        "Unable to send within the delivery window"
    error "Failed to send message",
      msgHash = task.loggedHash(), error = errorDesc, age = task.messageAge()
    self.fail(task, errorDesc)
    return true
  return false

proc reportPropagated(self: SendService, task: DeliveryTask) =
  ## Emits `MessagePropagatedEvent`, and `MessageSentEvent` for a mixed send that
  ## a plain send would confirm in Store. A task with no Store wait leaves the
  ## send queue first, so a listener of its last event can send again at once.
  if not self.awaitsStoreValidation(task):
    self.finish(task)
  # INFO lines reach log collectors, where a hash would tie this node to an
  # anonymized message; `MixSendProcessor` still logs it at DEBUG.
  info "Message successfully propagated", msgHash = task.loggedHash()
  MessagePropagatedEvent.emit(self.brokerCtx, task.msgHash.to0xHex())
  task.propagatedEventEmitted = true
  if task.propagatedAnonymously and self.storeConfirmationExpected(task):
    # The exit's reply completes a mixed send when a plain send would wait for
    # a store confirmation, so both paths end with the same event. The INFO line
    # omits the hash.
    info "Message successfully sent over mix"
    MessageSentEvent.emit(self.brokerCtx, task.msgHash.to0xHex())

proc admitAndProve(self: SendService, task: DeliveryTask): Future[bool] {.async.} =
  ## Attaches the RLN proof. `send` charged the budget, and only a new proof after
  ## a rejected one takes a new charge. A task has no queue to wait in for budget,
  ## so a new proof with no budget fails it. Returns false when the task waits
  ## for its next attempt or failed.
  if task.firstAdmittedTime.isNone():
    task.charge = self.rateLimitManager.admit().valueOr:
      debug "No rate-limit budget for a new RLN proof", msgHash = task.loggedHash()
      task.state = DeliveryState.FailedToDeliver
      task.errorDesc = "no rate-limit budget for a new RLN proof"
      return false
    task.chargeUnused = true
    task.firstAdmittedTime = Opt.some(Moment.now())

  # A new proof draws an RLN message id, and that id uses the charge.
  let drawsMessageId = self.waku.needsRlnProof(task.msg)
  # The message timestamp sets its epoch, so a backend past that epoch or out of
  # budget fails the task. Other errors wait for a retry.
  task.msg = (await self.waku.attachRlnProof(task.msg)).valueOr:
    case error.kind
    of RlnErrorKind.Permanent, RlnErrorKind.BudgetExhausted:
      task.state = DeliveryState.FailedToDeliver
      task.errorDesc = "Failed to attach RLN proof: " & $error
    of RlnErrorKind.NotReady, RlnErrorKind.Transient:
      debug "Failed to attach RLN proof, the task waits for a retry",
        msgHash = task.msgHash.to0xHex(), error = $error
    return false
  if drawsMessageId:
    task.chargeUnused = false

  return true

func needsAdmission(self: SendService, task: DeliveryTask): bool =
  ## True when the task needs an epoch budget charge or an RLN proof. A task that
  ## needs neither does not wait for another task in `admitAndProve`.
  return task.firstAdmittedTime.isNone() or self.waku.needsRlnProof(task.msg)

proc runAdmission(
    self: SendService, task: DeliveryTask
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Runs `admitAndProve` with `admissionLock` held, so the tasks get their RLN
  ## proofs one at a time, in queue order.
  await self.admissionLock.acquire()
  try:
    # The wait for the lock can use the rest of the window. A task past its
    # window gets no proof, so it draws no RLN message id.
    if task.isDeliveryTimedOut(self.deliveryWindow):
      return false
    return await self.admitAndProve(task)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    error "Exception in admission", msgHash = task.loggedHash(), error = exc.msg
    return false
  finally:
    self.admissionLock.release2()

proc retryNow(self: SendService) =
  ## Starts the next attempt of each task that waits for one.
  self.retryTick.fire()
  self.retryTick.clear()

proc retryLoop(self: SendService) {.async: (raises: [CancelledError]).} =
  ## Runs `retryNow` each `retryInterval`.
  while true:
    await sleepAsync(self.retryInterval)
    self.retryNow()

proc sendUntilPropagated(
    self: SendService, task: DeliveryTask
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Makes the first attempt at once, then one attempt at each tick of
  ## `retryLoop`, until the task propagates. Returns false when the task failed.
  while true:
    # A restart can come after the window, and validators would refuse the
    # message then, so the window is checked before each attempt too.
    if self.failExpired(task):
      return false
    if not self.needsAdmission(task) or await self.runAdmission(task):
      # A slow RLN proof can use the rest of the window, and validators would
      # refuse the message after it.
      if self.failExpired(task):
        return false
      # The attempt uses the charge.
      task.chargeUnused = false
      try:
        await self.sendProcessor.process(task)
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        # The send path returns remote errors as results, so an exception is a local
        # fault.
        error "Exception in a send attempt",
          msgHash = task.loggedHash(), error = exc.msg
    self.attempts.inc()
    case task.state
    of DeliveryState.SuccessfullyPropagated:
      self.reportPropagated(task)
      return true
    of DeliveryState.FailedToDeliver:
      # A mix exit may have published the message even though its reply was lost.
      error "Failed to send message",
        msgHash = task.loggedHash(), error = task.errorDesc
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
      info "Message successfully sent", msgHash = task.loggedHash()
      self.finish(task)
      MessageSentEvent.emit(self.brokerCtx, task.msgHash.to0xHex())
    else:
      info "Message propagated but not validated by a store node within time window; stop trying.",
        msgHash = task.msgHash.to0xHex(),
        waited = task.storeValidationWaited + (Moment.now() - started)
      recordStoreValidationTimeout()
      self.fail(
        task,
        "Propagated but not confirmed by a store node within the store validation window",
        MessageErrorKind.NotStored,
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

func refuse(kind: SendErrorKind, desc: string, retryAfter = ZeroDuration): SendError =
  return SendError.init(kind, desc, retryAfter)

proc checkSize(self: SendService, task: DeliveryTask): Result[void, SendError] =
  ## Refuses a message that, with the RLN proof it gets, exceeds the maximum
  ## message size, before it spends budget.
  let sized = self.waku.messageForSizeCheck(task.msg).valueOr:
    return err(
      refuse(
        SendErrorKind.TooLarge, "failed to determine the RLN proof size: " & $error
      )
    )
  let size = sized.encode().len
  let limit = int(self.waku.conf.maxMessageSizeBytes)
  if limit > 0 and size > limit:
    return err(
      refuse(
        SendErrorKind.TooLarge,
        "message exceeds the maximum message size: " & $size & " > " & $limit,
      )
    )
  return ok()

proc rateLimited(self: SendService, desc: string): SendError =
  ## A `RateLimited` refusal. Its text has the seconds to wait, because an FFI
  ## caller and a broker caller get only the text.
  let retryAfter = self.rateLimitManager.retryAfter()
  let seconds = max(1'i64, retryAfter.seconds)
  return refuse(
    SendErrorKind.RateLimited, desc & ", retry after " & $seconds & " s", retryAfter
  )

proc admitAtSend(self: SendService, task: DeliveryTask): Result[void, SendError] =
  ## Charges the budget of the epoch, or refuses the message. An ephemeral message
  ## is refused once the budget nears its end, so it cannot eat into the budget
  ## left for durable messages. It reads the last budget that the manager has,
  ## so it does not suspend.
  if task.isEphemeral():
    let quotaState = self.rateLimitManager.quotaState()
    if quotaState != QuotaState.Normal:
      return err(
        self.rateLimited(
          "ephemeral message refused, the rate-limit budget is: " & $quotaState
        )
      )
  task.charge = self.rateLimitManager.admit().valueOr:
    return err(self.rateLimited("the rate-limit budget of the epoch is spent"))
  task.chargeUnused = true
  task.firstAdmittedTime = Opt.some(Moment.now())
  return ok()

proc enqueue*(
    self: SendService, task: DeliveryTask
): Result[WakuMessageHash, SendError] =
  ## Charges the budget, puts `task` in the send queue and returns its message
  ## hash. It does not suspend, makes no attempt and emits no event, so the caller
  ## gets the hash first. A refused message gets no event, and the charge comes
  ## last, so a refused message takes none.
  assert(not task.isNil(), "task for enqueue must not be nil")
  if not self.deliveryTasks.getOrDefault(task.msgHash).isNil():
    debug "Message already in the send queue", msgHash = task.loggedHash()
    return err(refuse(SendErrorKind.Duplicate, "message already in flight"))
  ?self.checkSize(task)
  ?self.sendProcessor.checkBeforeSend(task)
  if self.isFull():
    info "Send queue full, message refused", msgHash = task.loggedHash()
    return err(refuse(SendErrorKind.QueueFull, "send queue full, retry later"))
  ?self.admitAtSend(task)

  info "Task added to the send queue", msgHash = task.msgHash.to0xHex()
  self.deliveryTasks[task.msgHash] = task
  self.startDeliverSoon(task)
  return ok(task.msgHash)

proc startSendService*(self: SendService) =
  ## Starts each task. Call it after `stopSendService` ends. A call while the
  ## service runs does nothing.
  if self.running:
    return
  self.running = true
  for task in self.deliveryTasks.values:
    self.startDeliverSoon(task)
  self.retryLoopHandle = self.retryLoop()
  if self.checkStoreForMessages:
    self.storeValidationHandle = self.storeValidationLoop()

proc stopSendService*(self: SendService) {.async: (raises: []).} =
  ## Cancels each `deliver`, `retryLoop`, the Store validation loop and each
  ## resend. The tasks stay in the send queue with no event, and
  ## `startSendService` starts them again.
  self.running = false
  var handles: seq[Future[void]]
  for handle in [self.retryLoopHandle, self.storeValidationHandle]:
    if not handle.isNil():
      handles.add(handle)
  self.retryLoopHandle = nil
  self.storeValidationHandle = nil
  for resend in self.resends.values:
    if not resend.finished():
      handles.add(resend)
  self.resends.clear()
  for task in self.deliveryTasks.values:
    if task.isRunning():
      handles.add(task.deliverHandle)
  await cancelAndWait(handles)

## The send service. It runs one `deliver` for each queued message, and `deliver` runs
## the message through its delivery plan to its last event (see `delivery_plan`).
##

import std/[algorithm, sequtils, sets, tables]
import chronos, chronicles
import brokers/broker_context
import
  ./[
    delivery_plan, send_processor, relay_processor, lightpush_processor, mix_processor,
    delivery_task,
  ],
  logos_delivery/waku/[waku_core, waku_store/common],
  logos_delivery/waku/waku,
  logos_delivery/waku/api/[store, publish],
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager
import logos_delivery/api/events/messaging_client_events
import logos_delivery/api/conf/modes
import logos_delivery/messaging/messaging_metrics

export delivery_plan, send_processor

{.push raises: [].}

logScope:
  topics = "send service"

const DeliveryWindow* = chronos.minutes(1)
  ## The delivery window: how long an admitted task tries before it fails with no
  ## propagation (`Preferred` gets two, see `maxDeliveryTime`). Also the mix
  ## window at `Preferred` and the default Store validation window.

proc maxDeliveryTime*(anonymityLevel: AnonymityLevel): timer.Duration =
  ## `Preferred` gets two windows: one for mix, then one for the plain path.
  if anonymityLevel == AnonymityLevel.Preferred:
    DeliveryWindow + DeliveryWindow
  else:
    DeliveryWindow

const NoBudgetForNewProofReason* = "No rate-limit budget for a new RLN proof"

const RetryInterval* = chronos.seconds(1)
  ## The pause between two ticks of `retryLoop`, and between two Store validation
  ## rounds.

const ResendTimeout = chronos.seconds(5)
  ## Cancels a resend that gets no answer in this time.

const MaxValidationAgeLimit* = chronos.hours(7 * 24)
  ## The longest Store validation window that `SendService.new` takes.

const ArchiveTime = chronos.seconds(3)
  ## The time a Store node needs to archive a message. A task is asked about in
  ## Store only after this time.

const StoreValidationQueryTimeout = chronos.seconds(15)
  ## Bounds one Store validation query with its dials. It exceeds one
  ## `DefaultDialTimeout`, so a dead Store peer leaves time for another.

const MaxStoreMissResends* = 3 ## The most resends of one message after a Store miss.

const MaxProofRefreshes* = 3
  ## The most new RLN proofs of one send after a rejection.
  ## Each one is a new charge, and a peer can reject each proof.

const MaxSendsInFlight* = 50
  ## The most messages that the service keeps, which are the sends with no last event.
  ## It bounds the memory of these messages and the open streams of this node.
  ## A task makes one attempt at a time, and a resend can add one stream to it.

type SendService* = ref object of RootObj
  brokerCtx: BrokerContext
  deliveryTasks: OrderedTable[WakuMessageHash, DeliveryTask]
    ## Each task that did not get its last event, by message hash, in queue order.
    ## A restart starts the tasks in this order.
  running: bool
    ## True while each task has its `deliver`. While false, `enqueue` keeps each
    ## task until `startSendService`.
  retryTick: AsyncEvent
    ## `retryNow` fires it, and each task that waits on it starts its next round.
  retryLoopHandle: Future[void] ## The `retryLoop`, nil while the service does not run.
  attempts: int
    ## The number of attempts that ended, in the proof step or in a send. Only tests
    ## read it.
  plan: DeliveryPlan
  processors: SendProcessors
  rateLimitManager: RateLimitManager
    ## `enqueue` charges each message against the per-epoch budget, and a new
    ## RLN proof is a new charge. The other publishes of a message are free.
  waku: Waku
  checkStoreForMessages: bool
  storeValidationHandle: Future[void]
    ## The Store validation loop. Nil when Store-based reliability is off.
  mixFallback: Opt[Trigger]
    ## Why the last task went from mix to the plain path, none once mix can
    ## attempt a task again. INFO logs each change.
  maxDeliveryTime*: timer.Duration
    ## How long an admitted task may keep trying before it is failed.
  mixWindow: timer.Duration
    ## How long after its admission mix keeps a task.
    ## Only `Preferred` has a finite one.
  maxValidationAge*: timer.Duration
    ## How long a task may wait for a Store confirmation before it fails. The
    ## time while the service is stopped does not count.
  archiveTime*: timer.Duration
    ## A task is asked about in Store only once its propagation and its last
    ## Store query are older than this, giving a Store node time to archive it.
    ## Also the pause of the Store validation loop while no Store peer is available.
  maxSendsInFlight: int
  retryInterval: timer.Duration

proc setupSendProcessors*(
    waku: Waku, anonymityLevel: AnonymityLevel
): Result[SendProcessors, string] =
  ## The send processors of the protocols that `waku` mounts.
  let brokerCtx = waku.brokerCtx
  var processors = SendProcessors()
  if anonymityLevel != AnonymityLevel.None:
    if not waku.hasLightpush():
      return err("Mix sending needs a lightpush client, which is not mounted")
    processors.mix = MixSendProcessor.new(waku, brokerCtx)
    if anonymityLevel == AnonymityLevel.Required:
      return ok(processors)
  if waku.hasRelay():
    processors.relay = RelaySendProcessor.new(waku.relayPushHandler(), brokerCtx)
  if waku.hasLightpush():
    let lightpush = LightpushSendProcessor.new(waku, brokerCtx)
    processors.lightpush = lightpush
    processors.resender = lightpush
  if processors.transports().len == 0:
    return err("No valid send processor found for the delivery task")
  return ok(processors)

proc new*(
    T: typedesc[SendService],
    preferP2PReliability: bool,
    waku: Waku,
    rateLimitManager: RateLimitManager,
    processors: SendProcessors,
    anonymityLevel: AnonymityLevel = AnonymityLevel.None,
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
  # The Store wait adds the window to the clock, and a window near `InfiniteDuration`
  # overflows that sum.
  if maxValidationAge > MaxValidationAgeLimit:
    return err("maxValidationAge must be at most " & $MaxValidationAgeLimit)

  let plan = ?buildDeliveryPlan(
    anonymityLevel, processors.transports(), not processors.resender.isNil()
  )
  let checkStoreForMessages = preferP2PReliability and waku.isStoreMounted()

  let sendService = SendService(
    brokerCtx: waku.brokerCtx,
    deliveryTasks: initOrderedTable[WakuMessageHash, DeliveryTask](),
    retryTick: newAsyncEvent(),
    plan: plan,
    processors: processors,
    rateLimitManager: rateLimitManager,
    waku: waku,
    checkStoreForMessages: checkStoreForMessages,
    maxDeliveryTime: maxDeliveryTime(anonymityLevel),
    mixWindow:
      if anonymityLevel == AnonymityLevel.Preferred:
        DeliveryWindow
      else:
        InfiniteDuration,
    maxValidationAge: maxValidationAge,
    archiveTime: ArchiveTime,
    maxSendsInFlight: maxSendsInFlight,
    retryInterval: retryInterval,
  )

  return ok(sendService)

func loggedHash(self: SendService, task: DeliveryTask): string =
  ## The hash of `task` for the INFO and ERROR records of the send service.
  ## A node whose plan starts with mix withholds it from the first record of a task.
  ## A record with the hash, also one before the first attempt, ties this node to the message.
  if self.plan.chain[0] == DeliveryState.Mix:
    "withheld"
  else:
    task.loggedHash()

func isFull*(self: SendService): bool =
  return self.deliveryTasks.len >= self.maxSendsInFlight

func mixFallback*(self: SendService): Opt[Trigger] =
  self.mixFallback

proc storeConfirmationExpected(self: SendService, task: DeliveryTask): bool =
  ## True when a plain send of this task would wait for a store confirmation:
  ## reliability is on and the message is not ephemeral.
  return self.checkStoreForMessages and not task.isEphemeral()

func awaitsStoreValidation*(task: DeliveryTask): bool =
  ## True while a propagated task waits for a store node to confirm it. A task
  ## that went out over mix never does: the store query would carry its hash in
  ## clear from this node's own address.
  ## A task that a Store node reported is in no later Store batch.
  return
    task.state in StoreWaitStates and not task.propagatedAnonymously and
    not task.storeReported

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
    if not task.awaitsStoreValidation():
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

proc acceptStoreResponse(
    self: SendService, tasks: seq[DeliveryTask], response: StoreQueryResponse
) =
  ## Sets the Store answer of each task from the response to a query about `tasks`.
  ## Each hash of the response counts at the time of this call.
  let receivedAt = Moment.now()
  # The Store peer decides which hashes its answer lists.
  # It can list hashes that this node did not ask about.
  # Only a task that waits for a Store confirmation takes a hash from the answer.
  # Thus a message sent over mix is never confirmed.
  var reported: HashSet[WakuMessageHash]
  for item in response.messages:
    reported.incl(item.messageHash)
    let task = self.deliveryTasks.getOrDefault(item.messageHash)
    if not task.isNil() and not task.storeAnswer.isNil():
      task.acceptStoreReport(receivedAt)

  if response.paginationCursor.isSome():
    # The answer is partial: a hash that it lacks can be on the next page.
    return
  for task in tasks:
    if task.msgHash notin reported and not task.storeAnswer.isNil() and
        not task.storeReported:
      task.storeMissed = true
      task.acceptStoreMiss()

proc queryStoreForTasks(
    self: SendService, shards: seq[PubsubTopic], tasks: seq[DeliveryTask]
) {.async.} =
  ## Sends one Store query about `tasks`, whose messages are in `shards`.
  ## Sets the Store answer of each task.
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

  self.acceptStoreResponse(tasks, storeResp)

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
        toSeq(self.deliveryTasks.values).filterIt(not it.storeAnswer.isNil()),
        Moment.now(),
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

func errorText*(report: StepReport): string =
  ## The text of the error event of a send that `report` ended.
  case report.trigger
  of WindowElapsed:
    "Unable to send within retry time window"
  of OverBudget:
    NoBudgetForNewProofReason
  of StoreWindowElapsed:
    "Propagated but not confirmed by a store node within the store validation window"
  of TooLargeForMix:
    MixTooLargeReason & ": " & report.desc
  of ProofSizeUnknown:
    "Failed to determine RLN proof size: " & report.desc
  of ProofPermanent, ProofBudgetExhausted:
    "Failed to attach RLN proof: " & report.desc
  of MixUnusableTriggers:
    mixUnusableText(report.trigger)
  of NoRelayPeers, ZeroPeers:
    "No relay peer to publish the message to"
  of Rejected, ProofRejected:
    report.desc
  else:
    $report.trigger

func errorText*(task: DeliveryTask): string =
  ## The text of the error event of a task that failed.
  let report = task.lastReport.valueOr:
    return ""
  return report.errorText()

func needsProof(self: SendService, task: DeliveryTask): bool =
  ## True when the task needs an RLN proof, or a charge for a new one.
  return task.firstAdmittedTime.isNone() or self.waku.needsRlnProof(task.msg)

proc takeCharge(self: SendService, task: DeliveryTask): bool =
  ## Charges `task` against the epoch budget. False when the budget is spent.
  task.charge = self.rateLimitManager.admit().valueOr:
    return false
  task.chargeUnused = true
  task.firstAdmittedTime = Opt.some(Moment.now())
  return true

proc prove(self: SendService, task: DeliveryTask): Future[StepReport] {.async.} =
  ## Attaches the RLN proof. `enqueue` took the charge of the first proof.
  ## A proof refresh clears the charge, and the new proof takes a new one here.
  if self.plan.level == AnonymityLevel.Required:
    self.processors.processorOf(self.plan.chain[0]).checkBeforeAdmission(task).isOkOr:
      return error

  if task.firstAdmittedTime.isNone() and not self.takeCharge(task):
    debug "No rate-limit budget for a new RLN proof", msgHash = task.msgHash.to0xHex()
    return StepReport.init(Trigger.OverBudget)

  # The message timestamp sets its epoch, so a backend past that epoch or out of
  # budget fails the task. Other errors wait for a retry.
  let drawsMessageId = self.waku.needsRlnProof(task.msg)
  task.msg = (await self.waku.attachRlnProof(task.msg)).valueOr:
    let trigger =
      case error.kind
      of RlnErrorKind.Permanent: Trigger.ProofPermanent
      of RlnErrorKind.BudgetExhausted: Trigger.ProofBudgetExhausted
      of RlnErrorKind.NotReady: Trigger.ProofNotReady
      of RlnErrorKind.Transient: Trigger.ProofTransient
    debug "Failed to attach RLN proof",
      msgHash = task.msgHash.to0xHex(), trigger = trigger, error = $error
    return StepReport.init(trigger, $error)
  if drawsMessageId:
    task.chargeUnused = false

  return StepReport.init(Trigger.Proved)

proc proveStep(
    self: SendService, task: DeliveryTask
): Future[StepReport] {.async: (raises: [CancelledError]).} =
  try:
    return await self.prove(task)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    error "Exception in the proof step",
      msgHash = self.loggedHash(task), error = exc.msg
    return StepReport.init(Trigger.StepRaised, exc.msg)

proc cancelPending(futures: seq[FutureBase]) {.async: (raises: []).} =
  var pending: seq[Future[void]]
  for future in futures:
    if not future.isNil() and not future.finished():
      pending.add(future.cancelAndWait())
  await noCancel allFutures(pending)

proc runAttempt(
    self: SendService,
    task: DeliveryTask,
    attempt: Future[StepReport],
    timeout = InfiniteDuration,
): Future[StepReport] {.async: (raises: [CancelledError]).} =
  ## Waits for `attempt`, for at most `timeout`.
  ## A processor returns a remote error as a result, so an exception is a local fault.
  ## `wait` cancels the attempt at the end of `timeout`, and when the step gets a cancel.
  ## It still returns a report that came in spite of that cancel.
  ## Thus a stop keeps a publish that was done.
  try:
    return await attempt.wait(timeout)
  except AsyncTimeoutError:
    debug "Send attempt timed out", msgHash = task.msgHash.to0xHex()
    return StepReport.init(Trigger.AttemptTimedOut)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    error "Exception in a send attempt",
      msgHash = self.loggedHash(task), error = exc.msg
    return StepReport.init(Trigger.StepRaised, exc.msg)

proc transportStep(
    self: SendService, task: DeliveryTask, state: DeliveryState
): Future[StepReport] {.async: (raises: [CancelledError]).} =
  ## One attempt over the transport of `state`, after checks with no network call.
  let processor = self.processors.processorOf(state)
  let overMix = state == DeliveryState.Mix
  processor.checkBeforeAttempt(task).isOkOr:
    return error
  if overMix and self.mixFallback.isSome():
    self.mixFallback = Opt.none(Trigger)
    info "Mix can carry messages again"
  if task.isDeliveryTimedOut(self.maxDeliveryTime):
    return StepReport.init(Trigger.WindowElapsed)
  if overMix and task.admissionAge() > self.mixWindow:
    return StepReport.init(Trigger.MixWindowElapsed)

  task.tryCount.inc()
  task.chargeUnused = false
  if overMix:
    # Mark before the attempt: the exit publishes before it replies, so a message
    # whose reply is lost is still on the network. From here on, the send service
    # logs no hash for this task at INFO or ERROR.
    task.anonymized = true
  return await self.runAttempt(task, processor.attempt(task))

proc storeStep(
    self: SendService, task: DeliveryTask, state: DeliveryState
): Future[StepReport] {.async: (raises: [CancelledError]).} =
  ## Waits for a Store answer until the Store validation window of the task ends.
  ## In `StoreResend`, it also sends the message once more.
  ## The end of the resend ends the step.
  ## A service node that has not seen the message relays it.
  ## An example is a Store node that joined the mesh after the first propagation.
  ## Relay is not used, as GossipSub drops a message that it already saw.
  ## A Store report or the end of the window ends the step.
  ## The step then cancels a resend that still runs.
  let answer = task.storeAnswer
  var resend: Future[StepReport].Raising([CancelledError])
  var answered, windowEnd: Future[void].Raising([CancelledError])
  try:
    while true:
      # The Store validation loop judged the report on time when it accepted it.
      if task.storeReported:
        return StepReport.init(Trigger.StoreReported)
      let left = answer.deadline - Moment.now()
      if left <= ZeroDuration:
        return StepReport.init(Trigger.StoreWindowElapsed)
      if state == DeliveryState.AwaitingStore:
        if answer.takeMiss():
          return StepReport.init(Trigger.StoreMissed)
      elif resend.isNil():
        # The lightpush peer can be gone since `CanResend` checked it.
        # A refused resend keeps the resend count.
        self.processors.resender.checkBeforeAttempt(task).isOkOr:
          return StepReport.init(Trigger.NoLightpushPeer, error.desc)
        task.resendCount.inc()
        resend =
          self.runAttempt(task, self.processors.resender.attempt(task), ResendTimeout)
        answer.resend = resend
      answer.clearSignal()
      answered = answer.waitAnswer()
      windowEnd = sleepAsync(left)
      if resend.isNil():
        discard await race(FutureBase(answered), FutureBase(windowEnd))
      else:
        discard
          await race(FutureBase(answered), FutureBase(windowEnd), FutureBase(resend))
        if resend.finished():
          # Only the resender itself cancels a resend that this step waits for.
          # That is a local fault, and it does not end the send.
          let report =
            if resend.cancelled():
              StepReport.init(Trigger.StepRaised, "the resend was cancelled")
            else:
              await resend
          debug "Resend after a Store miss finished",
            msgHash = task.msgHash.to0xHex(),
            resendCount = task.resendCount,
            trigger = report.trigger
          return report
      await cancelPending(@[FutureBase(answered), FutureBase(windowEnd)])
  finally:
    await cancelPending(
      @[FutureBase(resend), FutureBase(answered), FutureBase(windowEnd)]
    )

proc retryWaitStep(
    self: SendService, task: DeliveryTask
): Future[StepReport] {.async: (raises: [CancelledError]).} =
  if task.isDeliveryTimedOut(self.maxDeliveryTime):
    return StepReport.init(Trigger.WindowElapsed)
  await self.retryTick.wait()
  return StepReport.init(Trigger.RetryTick)

proc refreshRlnProof*(task: DeliveryTask, waku: Waku): bool =
  ## The service refused the task's proof as RLN-invalid: its proof went stale
  ## against a moved merkle root. Schedules a background merkle-path refresh and
  ## clears the proof so the next retry regenerates one against the refreshed
  ## path; `attachRlnProof` reuses an existing proof, so without the clear the
  ## rejected bytes would be resent. Resetting admission charges the new nonce
  ## the regenerated proof draws. Without a backend refresh hook a retry would
  ## be rejected the same way, so it returns false.
  if not waku.onRlnProofRejected():
    return false
  task.msg.proof = @[]
  task.firstAdmittedTime = Opt.none(Moment)
  task.proofRefreshes.inc()
  return true

proc canResend(self: SendService, task: DeliveryTask): bool =
  return
    task.resendCount < MaxStoreMissResends and
    self.processors.resender.checkBeforeAttempt(task).isOk()

proc storeWaited(task: DeliveryTask): timer.Duration =
  ## The time that `deliver` waited for a Store answer, with the open wait.
  if task.storeAnswer.isNil():
    task.storeValidationWaited
  else:
    task.storeValidationWaited + (Moment.now() - task.storeAnswer.openedAt)

proc endStoreWait(task: DeliveryTask) =
  ## Adds the time of the Store wait to the task, so a stop keeps it.
  task.storeValidationWaited = task.storeWaited()
  task.storeAnswer = nil

proc reportPropagated(self: SendService, task: DeliveryTask) =
  if task.firstPropagatedTime.isNone():
    task.firstPropagatedTime = Opt.some(Moment.now())
  if task.propagatedEventEmitted:
    return
  # INFO lines reach log collectors.
  # A hash in them ties this node to an anonymized message.
  # `MixSendProcessor` still logs the hash at DEBUG.
  info "Message successfully propagated", msgHash = self.loggedHash(task)
  # A listener runs inside `emit`, so the task records the event first.
  task.propagatedEventEmitted = true
  MessagePropagatedEvent.emit(self.brokerCtx, task.msgHash.to0xHex())

proc reportMixFallback(self: SendService, task: DeliveryTask, trigger: Trigger) =
  debug "Handing the task from mix to the plain send path",
    msgHash = task.msgHash.to0xHex(),
    trigger = trigger,
    admissionAge = task.admissionAge()
  if trigger in MixUnusableTriggers and self.mixFallback != Opt.some(trigger):
    self.mixFallback = Opt.some(trigger)
    info "Mix cannot carry messages, sending them over the plain path instead",
      reason = mixUnusableText(trigger)

proc reportStoreTimeout(self: SendService, task: DeliveryTask) =
  info "Message propagated but not validated by a store node within time window; stop trying.",
    msgHash = self.loggedHash(task), waited = task.storeWaited()
  recordStoreValidationTimeout()

proc startStoreWait(self: SendService, task: DeliveryTask) =
  if not task.storeAnswer.isNil():
    return
  let now = Moment.now()
  let left = self.maxValidationAge - task.storeValidationWaited
  task.storeAnswer = StoreAnswer.new(now, now + left)

proc reportSent(self: SendService, task: DeliveryTask) =
  # An anonymized task gets here only through a clear republish.
  # That is a `Preferred` send that made a mix attempt in an earlier round.
  info "Message successfully sent", msgHash = self.loggedHash(task)
  MessageSentEvent.emit(self.brokerCtx, task.msgHash.to0xHex())

proc reportSentOverMix(self: SendService, task: DeliveryTask) =
  # The reply of the exit ends a mixed send, so it gets the event of a stored send.
  info "Message successfully sent over mix", msgHash = self.loggedHash(task)
  MessageSentEvent.emit(self.brokerCtx, task.msgHash.to0xHex())

proc reportNotStored(self: SendService, task: DeliveryTask, report: StepReport) =
  MessageErrorEvent.emit(self.brokerCtx, task.msgHash.to0xHex(), report.errorText())

proc reportFailed(self: SendService, task: DeliveryTask, report: StepReport) =
  # A mix exit may have published the message even though its reply was lost.
  error "Failed to send message",
    msgHash = self.loggedHash(task),
    error = report.errorText(),
    trigger = report.trigger,
    lastFailure =
      if task.lastFailure.isSome():
        $task.lastFailure.get()
      else:
        "none",
    age = task.admissionAge()
  MessageErrorEvent.emit(self.brokerCtx, task.msgHash.to0xHex(), report.errorText())

proc finish(self: SendService, task: DeliveryTask) =
  task.endStoreWait()
  if not self.isQueued(task):
    return
  if task.chargeUnused:
    self.rateLimitManager.release(task.charge)
    task.chargeUnused = false
  self.deliveryTasks.del(task.msgHash)

proc holds(self: SendService, task: DeliveryTask, guard: Guard): bool =
  case guard
  of NeedsProof:
    self.needsProof(task)
  of Reliable:
    self.storeConfirmationExpected(task)
  of CanResend:
    self.canResend(task)
  of InMixGrace:
    task.admissionAge() <= MixUnusableGrace
  of CanRefreshProof:
    task.proofRefreshes < MaxProofRefreshes and self.waku.rlnRefreshesProofs()

proc runEffect(
    self: SendService, task: DeliveryTask, effect: TransitionEffect, report: StepReport
) =
  case effect
  of ReportPropagated:
    self.reportPropagated(task)
  of ReportPropagatedOverMix:
    task.propagatedAnonymously = true
    self.reportPropagated(task)
  of ReportMixFallback:
    self.reportMixFallback(task, report.trigger)
  of ReportStoreTimeout:
    self.reportStoreTimeout(task)
  of RefreshProof:
    discard task.refreshRlnProof(self.waku)

proc runEffect(
    self: SendService, task: DeliveryTask, effect: StateEffect, report: StepReport
) =
  case effect
  of StartStoreWait:
    self.startStoreWait(task)
  of ReportSent:
    self.reportSent(task)
  of ReportSentOverMix:
    self.reportSentOverMix(task)
  of ReportNotStored:
    self.reportNotStored(task, report)
  of ReportFailed:
    self.reportFailed(task, report)
  of Finish:
    self.finish(task)

proc runStep(
    self: SendService, task: DeliveryTask, state: DeliveryState
): Future[StepReport] {.async: (raises: [CancelledError]).} =
  case state
  of Prove:
    return await self.proveStep(task)
  of Relay, Lightpush, Mix:
    return await self.transportStep(task, state)
  of StoreWaitStates:
    return await self.storeStep(task, state)
  of NextRoundRetry:
    return await self.retryWaitStep(task)
  of Initial, FinalStates:
    raiseAssert "No step runs in " & $state

proc unplanned(
    self: SendService, task: DeliveryTask, fromState: DeliveryState, trigger: Trigger
): DeliveryState =
  ## A trigger that the plan cannot take fails the send.
  ## `listed` is false for a trigger that the step of `fromState` must not report.
  error "A trigger that the delivery plan cannot take",
    msgHash = self.loggedHash(task),
    state = fromState,
    trigger = trigger,
    listed = trigger in self.plan.stepTriggers(fromState)
  if task.firstPropagatedTime.isSome():
    DeliveryState.NotStored
  else:
    DeliveryState.NotPropagated

proc move(
    self: SendService,
    task: DeliveryTask,
    fromState: DeliveryState,
    report: StepReport,
    reportable: set[Trigger],
): DeliveryState =
  ## Runs `move` of the plan.
  ## A round records why it failed, and the end of a round counts as one attempt.
  # `reportFailed` logs the last failure, so the record comes before the move.
  if fromState in RoundStates and report.trigger.isFailure():
    task.lastFailure = Opt.some(report.trigger)
  let taken = self.plan.move(self, task, fromState, report, reportable)
  if fromState in RoundStates and taken.toState notin RoundStates:
    self.attempts.inc()
  return taken.toState

proc step*(
    self: SendService, task: DeliveryTask, state: DeliveryState
): Future[DeliveryState] {.async: (raises: [CancelledError]).} =
  ## Runs the step of `state`, then moves the task along the transition of its report.
  let report = await self.runStep(task, state)
  return self.move(task, state, report, self.plan.stepTriggers(state))

proc start(self: SendService, task: DeliveryTask): DeliveryState =
  ## Fires `Started` out of the state that the task is in.
  return
    self.move(task, task.state, StepReport.init(Trigger.Started), {Trigger.Started})

proc retryNow(self: SendService) =
  ## Starts the next round of each task that waits for one.
  self.retryTick.fire()
  self.retryTick.clear()

proc retryLoop(self: SendService) {.async: (raises: [CancelledError]).} =
  ## Runs `retryNow` each `retryInterval`.
  while true:
    await sleepAsync(self.retryInterval)
    self.retryNow()

proc deliver(
    self: SendService, task: DeliveryTask
) {.async: (raises: [CancelledError]).} =
  ## Runs the steps of the task until a final state.
  ## A stop cancels it.
  ## A task that is not at a final state stays in the send queue.
  try:
    var state = self.start(task)
    # A step can end with its report after the cancel of a stop.
    # A listener of an event can also stop the service from inside a step.
    while not state.isFinal() and self.running:
      state = await self.step(task, state)
  finally:
    task.endStoreWait()

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

proc rateLimitedError(self: SendService, desc: string): SendError =
  let retryAfter = self.rateLimitManager.retryAfter()
  return SendError.init(
    SendErrorKind.RateLimited,
    desc & ", retry after " & $retryAfter.seconds & " s",
    retryAfter,
  )

proc chargeAtSend(self: SendService, task: DeliveryTask): Result[void, SendError] =
  ## Takes the charge of a new message from the epoch budget, or refuses the message.
  # Ephemeral traffic is refused near the limit, so it cannot eat into the
  # budget left for durable messages.
  if task.isEphemeral():
    let quotaState = self.rateLimitManager.quotaState()
    if quotaState != QuotaState.Normal:
      return err(
        self.rateLimitedError("Ephemeral message refused: rate limit " & $quotaState)
      )
  if not self.takeCharge(task):
    return err(self.rateLimitedError("The rate-limit budget of the epoch is spent"))
  return ok()

proc enqueue*(self: SendService, task: DeliveryTask): Result[void, SendError] =
  ## Puts `task` in the send queue and charges it against the epoch budget.
  ## It makes no attempt and emits no event, so the caller gets the result first.
  ## The hash of a message identifies its send, so a message that the send queue
  ## already has is refused. A message over the budget is refused with `RateLimited`.
  assert(not task.isNil(), "task for enqueue must not be nil")
  let queued = self.deliveryTasks.getOrDefault(task.msgHash)
  if not queued.isNil():
    debug "Send refused, the message is already in the send queue",
      msgHash = self.loggedHash(queued)
    return err(
      SendError.init(SendErrorKind.Duplicate, "The node already sends this message")
    )
  if self.isFull():
    # A burst over the limit is back-pressure for the app, and no fault of the node.
    debug "Send refused, the node has its maximum of sends with no last event",
      msgHash = self.loggedHash(task), maxSendsInFlight = self.maxSendsInFlight
    return err(SendError.init(SendErrorKind.QueueFull, "Send queue full, retry later"))
  # The charge comes last, so a refused message takes none.
  self.chargeAtSend(task).isOkOr:
    debug "Send refused by the rate limit",
      msgHash = self.loggedHash(task), error = error.desc
    return err(error)

  info "Task added to the send queue", msgHash = self.loggedHash(task)
  self.deliveryTasks[task.msgHash] = task
  self.startDeliverSoon(task)
  return ok()

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
  ## Cancels each `deliver`, `retryLoop` and the Store validation loop.
  ## A step whose report came before the cancel still moves its task.
  ## Thus a task can emit an event or end during the stop.
  ## Each other task stays in the send queue, and `startSendService` starts it again.
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

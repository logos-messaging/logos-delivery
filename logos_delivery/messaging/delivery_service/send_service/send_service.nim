## This module reinforces the publish operation with regular store-v3 requests.
##

import std/[algorithm, sequtils, tables, typetraits]
import chronos, chronicles
import brokers/broker_context
import
  ./[send_processor, relay_processor, lightpush_processor, mix_processor, delivery_task],
  logos_delivery/waku/[waku_core, waku_store/common],
  logos_delivery/waku/waku,
  logos_delivery/waku/api/[store, subscriptions, publish],
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager
import logos_delivery/api/events/[kernel_events, messaging_client_events]
import logos_delivery/api/conf/modes
import logos_delivery/messaging/messaging_metrics

logScope:
  topics = "send service"

# This useful util is missing from sequtils, this extends applyIt with predicate...
template applyItIf*(varSeq, pred, op: untyped) =
  for i in low(varSeq) .. high(varSeq):
    var it {.inject.} = varSeq[i]
    if pred:
      op
      varSeq[i] = it

template forEach*(varSeq, op: untyped) =
  for i in low(varSeq) .. high(varSeq):
    let it {.inject.} = varSeq[i]
    op

const MaxTimeInCache* = chronos.minutes(1)
  ## Messages older than this time will get completely forgotten on publication and a
  ## feedback will be given when that happens

proc maxDeliveryTime*(anonymityLevel: AnonymityLevel): timer.Duration =
  ## `Preferred` gets two windows: one for mix, then one for the plain path.
  if anonymityLevel == AnonymityLevel.Preferred:
    MaxTimeInCache + MaxTimeInCache
  else:
    MaxTimeInCache

const DefaultMaxParkedAge* = chronos.minutes(30)
  ## Parked tasks never admitted within this age (from the message timestamp)
  ## are dropped with a `MessageErrorEvent`. Spans a few default RLN epochs.

const DefaultMaxTaskCacheSize* = 1000
  ## Hard cap on tasks tracked by the send service; further sends are rejected.

const ServiceLoopInterval* = chronos.seconds(1)
  ## Interval at which we retry sends, report results and remove finished tasks.
  ## It is also the pause between two Store validation rounds.

const ArchiveTime = chronos.seconds(3)
  ## Estimation of the time we wait until we start confirming that a message has been properly
  ## received and archived by a store node

const StoreValidationQueryTimeout = chronos.seconds(15)
  ## Bounds one Store validation query with its dials. It exceeds one
  ## `DefaultDialTimeout`, so a dead Store peer leaves time for another.

const MaxSendsInFlight* = 4
  ## A service pass sends in groups of this size. The sends of a group occur at
  ## the same time. The next group starts when all of them end. A mix send can
  ## continue for a maximum of `MixReplyHopTimeout` plus `MixReplyTimeout`.

type SendService* = ref object of RootObj
  brokerCtx: BrokerContext
  taskCache: seq[DeliveryTask]
    ## Cache that contains the delivery task per message hash.
    ## This is needed to make sure the published messages are properly published

  serviceLoopHandle: Future[void] ## handle that allows to stop the async task
  stopping: bool
    ## Set by `stopSendService`. It ends a pass that a caller drives directly,
    ## which resumes from `drainInFlight` after the stop cancels its batch.
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
    ## How long after its first propagation a task may wait for store
    ## confirmation before it is failed.
  archiveTime*: timer.Duration
    ## A task is asked about in Store only once its propagation and its last
    ## Store query are older than this, giving a Store node time to archive it.
    ## Also the pause of the Store validation loop while no Store peer is available.
  maxTaskCacheSize*: int
  serviceLoopInterval: timer.Duration
  entering: seq[DeliveryTask]
    ## The tasks that `send` accepted and that are not yet in `taskCache`.
    ## `isFull` counts them, so concurrent sends cannot exceed the limit.
    ## `markSeen` reads them to find a task in its first attempt.
  seenMsgListener: MessageSeenEventListener
  subscribeOnSend: bool
    ## True only for the `None` anonymity level. A subscription sends filter and
    ## Store requests that name the content topic from the address of this node.
  inFlight: seq[tuple[task: DeliveryTask, fut: Future[void]]]
    ## Sends started by the current pass and not yet waited for, kept so
    ## `stopSendService` can cancel them: `allFutures` does not cancel its
    ## children when it is cancelled itself.

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
      MixSendProcessor.new(waku, brokerCtx, anonymityLevel, MaxTimeInCache)
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
    maxTaskCacheSize: int = DefaultMaxTaskCacheSize,
    maxValidationAge: timer.Duration = MaxTimeInCache,
    serviceLoopInterval: timer.Duration = ServiceLoopInterval,
): Result[T, string] =
  let checkStoreForMessages = preferP2PReliability and waku.isStoreMounted()

  let sendService = SendService(
    brokerCtx: waku.brokerCtx,
    taskCache: newSeq[DeliveryTask](),
    serviceLoopHandle: nil,
    stopping: false,
    sendProcessor: sendProcessor,
    rateLimitManager: rateLimitManager,
    waku: waku,
    checkStoreForMessages: checkStoreForMessages,
    maxDeliveryTime: maxDeliveryTime(anonymityLevel),
    maxParkedAge: maxParkedAge,
    maxValidationAge: maxValidationAge,
    archiveTime: ArchiveTime,
    maxTaskCacheSize: maxTaskCacheSize,
    serviceLoopInterval: serviceLoopInterval,
    subscribeOnSend: anonymityLevel == AnonymityLevel.None,
  )

  return ok(sendService)

proc addTask(self: SendService, task: DeliveryTask) =
  self.taskCache.addUnique(task)

proc isFull*(self: SendService): bool =
  return self.taskCache.len + self.entering.len >= self.maxTaskCacheSize

proc subscribesOnSend*(self: SendService): bool =
  return self.subscribeOnSend

proc isStorePeerAvailable*(sendService: SendService): bool =
  return sendService.waku.hasStorePeer()

proc storeConfirmationExpected(self: SendService, task: DeliveryTask): bool =
  ## True when a plain send of this task would wait for a store confirmation:
  ## reliability is on and the message is not ephemeral. `awaitsStoreValidation`
  ## and the mixed completion in `reportTaskResult` both read it.
  return self.checkStoreForMessages and not task.isEphemeral()

proc awaitsStoreValidation*(self: SendService, task: DeliveryTask): bool =
  ## True while a propagated task still needs a store node to confirm it. A task
  ## that went out over mix never does: the store query would carry its hash in
  ## clear from this node's own address. Every store confirmation passes here.
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
  ## waited longest come first, and ties keep cache order.
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

  let storedItems = storeResp.messages.mapIt(it.messageHash)

  # The Store peer decides which hashes its answer lists, and it can list hashes
  # that this node did not ask about. Confirm only the tasks that still wait for
  # a Store confirmation, so that a message sent over mix is never confirmed.
  self.taskCache.applyItIf(
    self.awaitsStoreValidation(it) and storedItems.contains(it.msgHash)
  ):
    it.state = DeliveryState.SuccessfullyValidated

proc storeValidationLoop(self: SendService) {.async.} =
  ## Confirms propagated tasks against Store, one batch per round, apart from the
  ## send loop, so that a slow Store peer does not delay sends.
  while true:
    var delay = self.serviceLoopInterval
    try:
      let batch = self.nextStoreValidationBatch(self.taskCache, Moment.now())
      if batch.len > 0:
        if self.isStorePeerAvailable():
          await self.checkMsgsInStore(batch)
        else:
          debug "Skipping store validation, no store peer available",
            messageCount = batch.len
          delay = self.archiveTime
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      error "Store validation round raised, the loop continues", error = exc.msg
    await sleepAsync(delay)

proc loggedHash(task: DeliveryTask): string =
  ## The hash for INFO and ERROR records, withheld once the task is anonymized.
  if task.anonymized:
    "withheld"
  else:
    task.msgHash.to0xHex()

proc completeIfSeen(task: DeliveryTask): bool =
  ## Completes a task whose message this node received from the network after an
  ## mix send attempt started, as a mix send whose reply arrived. Returns true
  ## when it completes the task.
  if not task.seenOnNetwork or task.firstPropagatedTime.isSome():
    return false
  debug "Message seen on the network, the mix send is complete",
    requestId = task.requestId, msgHash = task.msgHash.to0xHex()
  task.state = DeliveryState.SuccessfullyPropagated
  task.propagatedAnonymously = true
  task.deliveryTime = Moment.now()
  task.firstPropagatedTime = Opt.some(Moment.now())
  return true

proc reportTaskResult(self: SendService, task: DeliveryTask) =
  # A seen task is complete, also when its attempt failed or its window ended.
  discard task.completeIfSeen()
  case task.state
  of DeliveryState.SuccessfullyPropagated:
    # TODO: in case of unable to strore check messages shall we report success instead?
    if not task.propagateEventEmitted:
      # INFO lines reach log collectors, where a hash would tie this node to an
      # anonymized message; `MixSendProcessor` still logs it at DEBUG.
      info "Message successfully propagated",
        requestId = task.requestId, msgHash = task.loggedHash()
      MessagePropagatedEvent.emit(
        self.brokerCtx, task.requestId, task.msgHash.to0xHex()
      )
      task.propagateEventEmitted = true

    if task.propagatedAnonymously and not task.sentEventEmitted and
        self.storeConfirmationExpected(task):
      # The exit's reply completes a mixed send when a plain send would wait for
      # a store confirmation, so both paths end with the same event.
      # `sentEventEmitted` keeps it to one; the INFO line omits the hash.
      info "Message successfully sent over mix", requestId = task.requestId
      MessageSentEvent.emit(self.brokerCtx, task.requestId, task.msgHash.to0xHex())
      task.sentEventEmitted = true
    return
  of DeliveryState.SuccessfullyValidated:
    # An anonymized task reaches this only through the clear republish of a
    # `Preferred` send whose mix reply was lost.
    info "Message successfully sent",
      requestId = task.requestId, msgHash = task.loggedHash()
    MessageSentEvent.emit(self.brokerCtx, task.requestId, task.msgHash.to0xHex())
    task.sentEventEmitted = true
    return
  of DeliveryState.FailedToDeliver:
    # The exit may have published the message even though its reply was lost.
    error "Failed to send message",
      requestId = task.requestId, msgHash = task.loggedHash(), error = task.errorDesc
    MessageErrorEvent.emit(
      self.brokerCtx, task.requestId, task.msgHash.to0xHex(), task.errorDesc
    )
    return
  else:
    # rest of the states are intermediate and does not translate to event
    discard

  # Fail a task that passed admission and did not propagate in its window.
  # evaluateAndCleanUp fails propagated tasks that no store node confirms.
  if task.isDeliveryTimedOut(self.maxDeliveryTime):
    # A processor that leaves a task for the next round can write why in
    # `errorDesc`, as the mix processor does for a `Required` task it holds.
    # Report that reason if set.
    if task.errorDesc.len == 0:
      task.errorDesc = "Unable to send within retry time window"
    error "Failed to send message",
      requestId = task.requestId,
      msgHash = task.loggedHash(),
      error = task.errorDesc,
      age = task.admissionAge()
    task.state = DeliveryState.FailedToDeliver
    MessageErrorEvent.emit(
      self.brokerCtx, task.requestId, task.msgHash.to0xHex(), task.errorDesc
    )
  elif task.isParkedExpired(self.maxParkedAge):
    error "Failed to send message",
      requestId = task.requestId,
      msgHash = task.loggedHash(),
      error = "Parked message too old",
      age = task.messageAge()
    task.state = DeliveryState.FailedToDeliver
    MessageErrorEvent.emit(
      self.brokerCtx,
      task.requestId,
      task.msgHash.to0xHex(),
      "Rate-limit budget not available within max parked age",
    )

proc evaluateAndCleanUp*(self: SendService) =
  self.taskCache.forEach(self.reportTaskResult(it))
  self.taskCache.keepItIf(
    it.state != DeliveryState.SuccessfullyValidated and
      it.state != DeliveryState.FailedToDeliver
  )

  # remove propagated messages when no store confirmation will follow
  self.taskCache.keepItIf(
    not (
      it.state == DeliveryState.SuccessfullyPropagated and
      not self.awaitsStoreValidation(it)
    )
  )

  # Fail propagated tasks that no store node confirmed within maxValidationAge.
  # Eviction keys on the state set here, so every failed task is reported.
  let expired = self.taskCache.filterIt(
    it.firstPropagatedTime.isSome() and it.state != DeliveryState.SuccessfullyValidated and
      it.propagationAge() > self.maxValidationAge
  )
  for task in expired:
    debug "Message propagated but not validated by a store node within time window; stop trying.",
      requestId = task.requestId,
      msgHash = task.msgHash.to0xHex(),
      propagationAge = task.propagationAge()
    recordStoreValidationTimeout()
    task.state = DeliveryState.FailedToDeliver
    task.errorDesc =
      "Propagated but not confirmed by a store node within the store validation window"
    MessageErrorEvent.emit(
      self.brokerCtx, task.requestId, task.msgHash.to0xHex(), task.errorDesc
    )

  self.taskCache.keepItIf(it.state != DeliveryState.FailedToDeliver)

proc reportTaskQueued(self: SendService, task: DeliveryTask) =
  ## Announces a task parked for epoch budget, once per task. Retry rounds
  ## re-enter the same branch, so the flag is what keeps the event one-shot.
  if task.queuedEventEmitted:
    return

  info "Message queued for rate-limit budget",
    requestId = task.requestId, msgHash = task.loggedHash()
  MessageQueuedEvent.emit(self.brokerCtx, task.requestId, task.msgHash.to0xHex())
  task.queuedEventEmitted = true

proc admitAndProve(self: SendService, task: DeliveryTask): Future[bool] {.async.} =
  ## Gates a task's first transmission: charges one epoch slot, then attaches
  ## an RLN proof — strictly in that order, so an over-budget message never
  ## draws a nonce. The slot is charged at most once per task lifetime
  ## (`firstAdmittedTime`); the proof attach is retried each round until it
  ## sticks, then short-circuits, so a task charged but not yet proven never
  ## ships bare. Returns false while the task must stay parked for a later round,
  ## or once it is dropped (`FailedToDeliver`).
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

  ## A no-op when RLN is not mounted, or when a prior round already attached a
  ## proof; otherwise draws the nonce and attaches. The message's epoch is fixed
  ## by its timestamp, so a backend that has moved past that epoch, or spent its
  ## budget, fails the task: no later round can prove it. Every other kind
  ## retries next round.
  task.msg = (await self.waku.attachRlnProof(task.msg)).valueOr:
    case error.kind
    of RlnErrorKind.Permanent, RlnErrorKind.BudgetExhausted:
      task.state = DeliveryState.FailedToDeliver
      task.errorDesc = "Failed to attach RLN proof: " & $error
    of RlnErrorKind.NotReady, RlnErrorKind.Transient:
      debug "Failed to attach RLN proof, retrying next round",
        requestId = task.requestId, error = $error
    return false

  return true

proc drainInFlight(self: SendService) {.async.} =
  ## Waits for the sends of the current batch. A send whose processor raised is
  ## logged, and its task stays in the cache for the next round.
  await allFutures(self.inFlight.mapIt(it.fut))
  for send in self.inFlight:
    if send.fut.cancelled():
      continue
    if send.fut.failed():
      # The send path turns every remote error into a result, so a raise here is
      # a local fault.
      error "Send attempt raised, the task waits for the next round",
        requestId = send.task.requestId,
        msgHash = send.task.loggedHash(),
        error = send.fut.error.msg
      # A raise skips the tail of `process` that moves a hand-off to
      # `NextRoundRetry`, and no pass selects `FallbackRetry`, so move it here.
      if send.task.state == DeliveryState.FallbackRetry or
          send.task.state == DeliveryState.Entry:
        send.task.state = DeliveryState.NextRoundRetry
  self.inFlight.setLen(0)

proc trySendMessages*(self: SendService) {.async.} =
  ## One service pass, driven by the loop. When a caller drives a pass directly,
  ## `stopSendService` cancels its batch and `stopping` ends it.
  let tasksToSend = self.taskCache.filterIt(it.state == DeliveryState.NextRoundRetry)

  for task in tasksToSend:
    if self.stopping:
      # Break to the tail, which waits for the sends that this pass started.
      break
    if task.completeIfSeen():
      continue
    # Admit in order, so the epoch budget and the RLN nonce are charged in
    # order. Only the network round trips overlap, `MaxSendsInFlight` at most.
    let admitted =
      try:
        await self.admitAndProve(task)
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        # The task is not sent and stays at `NextRoundRetry`; the reapers fail it
        # with an event if admission keeps raising.
        error "Admission raised, the task waits for the next round",
          requestId = task.requestId, msgHash = task.loggedHash(), error = exc.msg
        false
    if not admitted:
      continue
    if self.stopping:
      # Read `stopping` again: `admitAndProve` suspends when it makes an RLN
      # proof, and a stop that ran meanwhile cannot cancel a send started now.
      break
    self.inFlight.add((task: task, fut: self.sendProcessor.process(task)))
    if self.inFlight.len >= MaxSendsInFlight:
      await self.drainInFlight()
  if self.inFlight.len > 0:
    await self.drainInFlight()

proc serviceLoop(self: SendService) {.async.} =
  ## Retries sends, reports results, and removes finished or expired tasks.
  while true:
    # A raise must not end the loop: nothing watches it until stop, and queued
    # tasks would never get a terminal event.
    try:
      await self.trySendMessages()
      self.evaluateAndCleanUp()
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      error "Send service pass raised, the loop continues", error = exc.msg
    ## TODO: add circuit breaker to avoid infinite looping in case of persistent failures
    ## Use OnlineStateChange observers to pause/resume the loop
    await sleepAsync(self.serviceLoopInterval)

proc markSeen(
    task: DeliveryTask,
    pubsubTopic: PubsubTopic,
    msg: WakuMessage,
    msgHash: var Opt[WakuMessageHash],
) =
  ## Marks `task` when `msg` is its message and `task` had a mix send attempt.
  ## A fallback processor sends a task in the `FallbackRetry` state, and relay
  ## gives this node its own publish, so the message does not count in that
  ## state. `msgHash` keeps the hash for the next task.
  if not task.anonymized or task.state == DeliveryState.FallbackRetry or
      task.pubsubTopic != pubsubTopic or task.msg.timestamp != msg.timestamp:
    return
  if msgHash.isNone():
    msgHash = Opt.some(computeMessageHash(pubsubTopic, msg))
  if task.msgHash == msgHash.get():
    task.seenOnNetwork = true

proc markSeen(self: SendService, pubsubTopic: PubsubTopic, msg: WakuMessage) =
  ## Marks the tasks of a message that this node received from the network.
  var msgHash: Opt[WakuMessageHash]
  for task in self.taskCache:
    task.markSeen(pubsubTopic, msg, msgHash)
  for task in self.entering:
    task.markSeen(pubsubTopic, msg, msgHash)

proc startSendService*(self: SendService) =
  self.stopping = false
  self.seenMsgListener = MessageSeenEvent.listen(
    self.brokerCtx,
    proc(event: MessageSeenEvent) {.async: (raises: []).} =
      self.markSeen(event.topic, event.message),
  ).valueOr:
    # Without the listener, only the reply of the exit completes a mix send.
    error "Failed to set the MessageSeenEvent listener", error = error
    MessageSeenEventListener()
  self.serviceLoopHandle = self.serviceLoop()
  if self.checkStoreForMessages:
    self.storeValidationHandle = self.storeValidationLoop()

proc stopSendService*(self: SendService) {.async.} =
  self.stopping = true
  var loops: seq[Future[void]]
  for handle in [self.serviceLoopHandle, self.storeValidationHandle]:
    if not handle.isNil():
      loops.add(handle)
  await cancelAndWait(loops)
  self.serviceLoopHandle = nil
  self.storeValidationHandle = nil
  # `cancelAndWait` on the loop leaves the batch running, so cancel the sends
  # here. Take the batch first: a pass in `drainInFlight` empties `inFlight` when
  # its last send finishes, which happens inside one of these cancels.
  let sends = self.inFlight
  self.inFlight.setLen(0)
  for send in sends:
    if not send.fut.finished():
      await send.fut.cancelAndWait()
    # No pass selects `Entry` or `FallbackRetry`, and the drain of the owning
    # pass sees an empty batch, so move a cancelled task to `NextRoundRetry` here.
    if send.task.state == DeliveryState.FallbackRetry or
        send.task.state == DeliveryState.Entry:
      send.task.state = DeliveryState.NextRoundRetry
  await MessageSeenEvent.dropListener(self.brokerCtx, self.seenMsgListener)
  self.seenMsgListener = MessageSeenEventListener()

proc send*(self: SendService, task: DeliveryTask) {.async.} =
  assert(not task.isNil(), "task for send must not be nil")

  debug "SendService.send: processing delivery task",
    requestId = task.requestId, msgHash = task.msgHash.to0xHex()

  if self.isFull():
    error "Failed to send message",
      requestId = task.requestId, msgHash = task.loggedHash(), error = "Send queue full"
    MessageErrorEvent.emit(
      self.brokerCtx, task.requestId, task.msgHash.to0xHex(), "Send queue full"
    )
    return

  self.entering.add(task)
  defer:
    let i = self.entering.find(task)
    if i >= 0:
      self.entering.delete(i)

  try:
    # Yield once, so no event reaches the caller before its request id: the
    # messaging API returns the id when `send` suspends, and chronos runs this
    # expired timer after the queued callbacks that carry the id back. Counted
    # before the yield, so the API's `isFull()` sees every send of a burst.
    await sleepAsync(ZeroDuration)

    if self.subscribeOnSend:
      self.waku.subscribe(task.msg.contentTopic, weak = true).isOkOr:
        debug "SendService.send: failed to subscribe to content topic",
          contentTopic = task.msg.contentTopic, error = error

    if not (await self.admitAndProve(task)):
      if task.state == DeliveryState.FailedToDeliver:
        self.reportTaskResult(task)
        return
      debug "SendService.send: parking task for a later round",
        requestId = task.requestId, msgHash = task.msgHash.to0xHex()
      task.state = DeliveryState.NextRoundRetry
      self.addTask(task)
      return

    await self.sendProcessor.process(task)
  except CancelledError:
    # Do not re-raise: the messaging API `asyncSpawn`s `send`, and chronos turns
    # a cancelled spawned future into a `FutureDefect`. Put the task back in the
    # cache, also during a stop, so its request id still gets a terminal event.
    task.state = DeliveryState.NextRoundRetry
    self.addTask(task)
    debug "Send cancelled", requestId = task.requestId
    return
  except CatchableError as exc:
    # A raise must not leave `send`: chronos turns a failed spawned future into
    # a `FutureDefect` that ends the process. Keep the task for the next round.
    error "Send attempt raised, the task waits for the next round",
      requestId = task.requestId, msgHash = task.loggedHash(), error = exc.msg
    if task.state == DeliveryState.FallbackRetry or task.state == DeliveryState.Entry:
      task.state = DeliveryState.NextRoundRetry
    # Fall through to the tail, so a task that reached a terminal state before
    # the raise still reports it.
  reportTaskResult(self, task)
  if task.state != DeliveryState.FailedToDeliver:
    self.addTask(task)

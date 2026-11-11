## The send service accepts or refuses each message of `send`.
## It sends each accepted message one time, and it keeps no message for a later send.
## The caller sends a message that failed again, with a new `send`.

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
  ## How long the send of a task can take, with its RLN proof.
  ## A task with no result at the end of the window fails.

const StoreValidationWindow* = chronos.minutes(1)

const StoreValidationInterval* = chronos.seconds(1)

const ArchiveTime = chronos.seconds(3)
  ## The time a Store node needs to archive a message. A task is asked about in
  ## Store only after this time.

const StoreValidationQueryTimeout = chronos.seconds(15)
  ## Bounds one Store validation query with its dials. It exceeds one
  ## `DefaultDialTimeout`, so a dead Store peer leaves time for another.

const MaxSendsInFlight* = 50
  ## The most sends that the service has with no last event.
  ## It bounds the memory of the held messages and the open streams of this node.

const MessageTooLargeReason* = "Message size exceeded"
  ## The start of the error text of a message above `maxMessageSizeBytes`.

const DeliveryWindowElapsedReason* = "No result of the send within the delivery window"

const ServiceStoppedReason* = "The node stopped before the send ended"

type SendService* = ref object of RootObj
  brokerCtx: BrokerContext
  deliveryTasks: OrderedTable[WakuMessageHash, DeliveryTask]
    ## Each task that did not get its last event, by message hash.
  running: bool
  maxSendsInFlight: int
  sendsEnded: int ## Only tests read it.
  sendProcessor: BaseSendProcessor
  rateLimitManager: RateLimitManager
    ## Charges each accepted message against the per-epoch budget.

  waku: Waku
  checkStoreForMessages: bool
  storeValidationHandle: Future[void]
    ## The Store validation loop. Nil when Store-based reliability is off.
  deliveryWindow*: timer.Duration
  maxValidationAge*: timer.Duration
    ## How long a task may wait for a Store confirmation before it fails.
  archiveTime*: timer.Duration
    ## A task is asked about in Store only once its propagation and its last
    ## Store query are older than this, giving a Store node time to archive it.
    ## Also the pause of the Store validation loop while no Store peer is available.
  storeValidationInterval: timer.Duration

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
      MixSendProcessor.new(waku, brokerCtx, anonymityLevel)
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
    deliveryWindow: timer.Duration = DeliveryWindow,
    maxValidationAge: timer.Duration = StoreValidationWindow,
    storeValidationInterval: timer.Duration = StoreValidationInterval,
    maxSendsInFlight: int = MaxSendsInFlight,
): Result[T, string] =
  # With zero, the Store validation loop runs with no pause.
  if storeValidationInterval <= ZeroDuration:
    return err("storeValidationInterval must be positive")
  if maxSendsInFlight <= 0:
    return err("maxSendsInFlight must be positive")

  let checkStoreForMessages = preferP2PReliability and waku.isStoreMounted()

  let sendService = SendService(
    brokerCtx: waku.brokerCtx,
    deliveryTasks: initOrderedTable[WakuMessageHash, DeliveryTask](),
    maxSendsInFlight: maxSendsInFlight,
    sendProcessor: sendProcessor,
    rateLimitManager: rateLimitManager,
    waku: waku,
    checkStoreForMessages: checkStoreForMessages,
    deliveryWindow: deliveryWindow,
    maxValidationAge: maxValidationAge,
    archiveTime: ArchiveTime,
    storeValidationInterval: storeValidationInterval,
  )

  return ok(sendService)

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

proc queryStoreForTasks(
    self: SendService, shards: seq[PubsubTopic], tasks: seq[DeliveryTask]
) {.async.} =
  ## Sends one Store query about `tasks`, whose messages are in `shards`.
  ## Confirms the tasks that the answer reports, and marks the others as missed.
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

  if storeResp.paginationCursor.isSome():
    # The answer is partial: a hash that it lacks can be on the next page.
    return
  for task in tasks:
    if task.msgHash notin reported and task.storeAnswerPending():
      task.storeMissed = true

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
    var delay = self.storeValidationInterval
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

func isInFlight(self: SendService, task: DeliveryTask): bool =
  return self.deliveryTasks.getOrDefault(task.msgHash) == task

func finish(self: SendService, task: DeliveryTask) =
  ## Removes a task that got its last event.
  if self.isInFlight(task):
    self.deliveryTasks.del(task.msgHash)

proc fail(
    self: SendService, task: DeliveryTask, kind: MessageErrorKind, errorDesc: string
) =
  ## Fails the task with `MessageErrorEvent`, its last event.
  task.state = DeliveryState.FailedToDeliver
  task.errorDesc = errorDesc
  MessageErrorEvent.emit(self.brokerCtx, task.msgHash.to0xHex(), kind, errorDesc)
  self.finish(task)

proc reportPropagated(self: SendService, task: DeliveryTask) =
  ## Emits `MessagePropagatedEvent`, and `MessageSentEvent` for a mixed send that
  ## a plain send would confirm in Store.
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

proc checkMessageSize(self: SendService, task: DeliveryTask): Result[void, SendError] =
  ## Refuses a message that is too large with its RLN proof.
  let message = self.waku.messageForSizeCheck(task.msg).valueOr:
    debug "No valid proof size, checking the size of the message without its proof",
      msgHash = task.msgHash.to0xHex(), error = $error
    task.msg
  let size = message.encodedSize()
  if uint64(size) <= self.waku.maxMessageSizeBytes:
    return ok()
  return err(
    SendError.init(
      SendErrorKind.TooLarge,
      MessageTooLargeReason & ": the message has " & $size & " bytes",
    )
  )

proc rateLimitedError(self: SendService, desc: string): SendError =
  let retryAfter = self.rateLimitManager.retryAfter()
  return SendError.init(
    SendErrorKind.RateLimited,
    desc & ", retry after " & $retryAfter.seconds & " s",
    retryAfter,
  )

proc checkAcceptable(self: SendService, task: DeliveryTask): Result[void, SendError] =
  if not self.running:
    return err(SendError.init(SendErrorKind.Other, "The send service does not run"))
  if task.msgHash in self.deliveryTasks:
    return err(
      SendError.init(SendErrorKind.Duplicate, "The node already sends this message")
    )
  if self.deliveryTasks.len >= self.maxSendsInFlight:
    return err(
      SendError.init(
        SendErrorKind.QueueFull,
        "The node has " & $self.maxSendsInFlight & " sends with no last event",
      )
    )
  ?self.sendProcessor.checkBeforeAdmission(task)
  ?self.checkMessageSize(task)
  if not self.sendProcessor.chainHasSendPeer(task):
    let reason = self.sendProcessor.noSendPeerReason(task)
    return err(
      SendError.init(
        SendErrorKind.NotConnected,
        if reason.len > 0:
          reason
        else:
          "The node has no peer to send the message through",
      )
    )

  let quotaState = self.rateLimitManager.quotaState()
  # Ephemeral traffic is refused near the limit, so it cannot eat into the
  # budget left for durable messages.
  if task.isEphemeral() and quotaState != QuotaState.Normal:
    return
      err(self.rateLimitedError("Ephemeral message refused: rate limit " & $quotaState))
  return ok()

proc attachProof(self: SendService, task: DeliveryTask): Future[bool] {.async.} =
  ## Returns false when the task failed.
  task.msg = (await self.waku.attachRlnProof(task.msg)).valueOr:
    self.rateLimitManager.release(task.charge)
    task.state = DeliveryState.FailedToDeliver
    task.errorDesc = "Failed to attach RLN proof: " & $error
    return false
  return true

proc sendOnce(
    self: SendService, task: DeliveryTask
) {.async: (raises: [CancelledError]).} =
  try:
    if self.waku.needsRlnProof(task.msg):
      if not await self.attachProof(task):
        return
    await self.sendProcessor.process(task)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    # The send path returns remote errors as results, so an exception is a local fault.
    task.state = DeliveryState.FailedToDeliver
    task.errorDesc = "Exception in the send: " & exc.msg

proc propagate(
    self: SendService, task: DeliveryTask
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Returns false when the task failed.
  try:
    await self.sendOnce(task).wait(self.deliveryWindow)
  except AsyncTimeoutError:
    if task.state != DeliveryState.SuccessfullyPropagated:
      task.state = DeliveryState.FailedToDeliver
      task.errorDesc = DeliveryWindowElapsedReason
  self.sendsEnded.inc()

  if task.state == DeliveryState.SuccessfullyPropagated:
    self.reportPropagated(task)
    return true
  # A mix exit may have published the message even though its reply was lost.
  error "Failed to send message", msgHash = task.loggedHash(), error = task.errorDesc
  self.fail(task, MessageErrorKind.NotPropagated, task.errorDesc)
  return false

proc waitForStoreValidation(
    self: SendService, task: DeliveryTask
) {.async: (raises: [CancelledError]).} =
  task.storeAnswer = newFuture[void]("store confirmation")
  try:
    if await task.storeAnswer.withTimeout(self.maxValidationAge):
      task.state = DeliveryState.SuccessfullyValidated
      info "Message successfully sent", msgHash = task.msgHash.to0xHex()
      MessageSentEvent.emit(self.brokerCtx, task.msgHash.to0xHex())
      self.finish(task)
    else:
      info "Message propagated but not validated by a store node within time window; stop trying.",
        msgHash = task.msgHash.to0xHex()
      recordStoreValidationTimeout()
      self.fail(
        task, MessageErrorKind.NotStored,
        "Propagated but not confirmed by a store node within the store validation window",
      )
  finally:
    task.storeAnswer = nil

proc deliver(
    self: SendService, task: DeliveryTask
) {.async: (raises: [CancelledError]).} =
  if not await self.propagate(task):
    return
  if self.awaitsStoreValidation(task):
    await self.waitForStoreValidation(task)
  else:
    self.finish(task)

func isRunning(task: DeliveryTask): bool =
  ## True while the `deliver` of the task runs.
  return not task.deliverHandle.isNil() and not task.deliverHandle.finished()

proc startDeliverSoon(self: SendService, task: DeliveryTask) =
  ## Starts `deliver` in a later turn of the event loop.
  ## The caller of `enqueue` gets its result before any event of the task.
  ## A stop before that turn fails the task, so `deliver` must not start then.
  callSoon(
    proc(udata: pointer) {.gcsafe, raises: [].} =
      if self.running and self.isInFlight(task):
        task.deliverHandle = self.deliver(task)
  )

proc enqueue*(self: SendService, task: DeliveryTask): Result[void, SendError] =
  assert(not task.isNil(), "task for enqueue must not be nil")
  self.checkAcceptable(task).isOkOr:
    debug "Send refused", msgHash = task.msgHash.to0xHex(), error = $error
    return err(error)
  task.charge = self.rateLimitManager.admit().valueOr:
    return err(self.rateLimitedError("The rate-limit budget of the epoch is spent"))

  debug "Send accepted", msgHash = task.msgHash.to0xHex()
  self.deliveryTasks[task.msgHash] = task
  self.startDeliverSoon(task)
  return ok()

proc startSendService*(self: SendService) =
  if self.running:
    return
  self.running = true
  if self.checkStoreForMessages:
    self.storeValidationHandle = self.storeValidationLoop()

proc stopSendService*(self: SendService) {.async: (raises: []).} =
  ## Each task that did not get its last event fails.
  self.running = false
  var handles: seq[Future[void]]
  if not self.storeValidationHandle.isNil():
    handles.add(self.storeValidationHandle)
  self.storeValidationHandle = nil
  for task in self.deliveryTasks.values:
    if task.isRunning():
      handles.add(task.deliverHandle)
  await cancelAndWait(handles)
  for task in toSeq(self.deliveryTasks.values):
    let kind =
      if task.propagatedEventEmitted:
        MessageErrorKind.NotStored
      else:
        MessageErrorKind.NotPropagated
    self.fail(task, kind, ServiceStoppedReason)

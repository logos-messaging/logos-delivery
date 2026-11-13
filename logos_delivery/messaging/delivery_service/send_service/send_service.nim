## The send service.
## `sendAttempt` makes one attempt of a message over one transport, and waits for
## its confirmation in the time of the attempt.
## `enqueue` takes a message of `send`, and `deliver` makes the attempts of that
## message, one in each attempt interval.

import std/[algorithm, sequtils, sets, tables]
import chronos, chronicles
import brokers/broker_context
import
  ./[transports, delivery_task],
  logos_delivery/waku/[waku_core, waku_store/common],
  logos_delivery/waku/waku,
  logos_delivery/waku/api/[store, publish],
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager
import logos_delivery/api/types
import logos_delivery/api/events/messaging_client_events
import logos_delivery/api/conf/modes
import logos_delivery/messaging/messaging_metrics

{.push raises: [].}

logScope:
  topics = "send service"

const MaxSendAttempts* = 4

const SendAttemptInterval* = chronos.seconds(5)
  ## The time from the start of one attempt of `send` to the start of the next.
  ## An attempt that still runs then ends.
  ## The attempts of a message take 20 s at most, because a Store node and an RLN
  ## relay validator refuse a timestamp that is more than 20 s old.

const StoreValidationWindow* = chronos.minutes(1)

const StoreValidationInterval* = chronos.seconds(1)

const ArchiveTime = chronos.seconds(3)
  ## The time a Store node needs to archive a message. A task is asked about in
  ## Store only after this time.

const StoreValidationQueryTimeout = chronos.seconds(15)
  ## Bounds one Store validation query with its dials. It exceeds one
  ## `DefaultDialTimeout`, so a dead Store peer leaves time for another.

const MaxSendsInFlight* = 50
  ## The most messages that the service keeps.
  ## It bounds the memory of these messages and the open streams of this node.

const MessageTooLargeReason* = "Message size exceeded"
  ## The start of the error text of a message above `maxMessageSizeBytes`.

const SendWindowElapsedReason* = "Unable to send within retry time window"
  ## The error of a message of `send` that no attempt propagated, when the last
  ## attempt gave no reason.

const NoBudgetForNewProofReason* = "No rate-limit budget for a new RLN proof"

const StoreValidationTimeoutReason* =
  "Propagated but not confirmed by a store node within the store validation window"

const ServiceStoppedReason* = "The node stopped before the send ended"

type
  Confirmation* {.pure.} = enum
    NotConfirmed ## No Store node reported the message in the time of the attempt.
    Confirmed ## A Store node has the message, or the mix exit replied.
    NotExpected ## Nothing confirms this message.

  SendAttempt* = object ## How one `sendAttempt` ended.
    msgHash*: WakuMessageHash
    outcome*: AttemptOutcome
    desc*: string ## The reason of the transport, when it gave one.
    confirmation*: Confirmation ## For a `Propagated` attempt.

type SendService* = ref object of RootObj
  brokerCtx: BrokerContext
  deliveryTasks: OrderedTable[WakuMessageHash, DeliveryTask]
    ## Each message of `send` that did not get its last event, by message hash.
  running: bool
  maxSendsInFlight: int
  sendsEnded: int ## Only tests read it.
  transports: Transports
  anonymityLevel: AnonymityLevel
  rateLimitManager: RateLimitManager

  waku: Waku
  checkStoreForMessages: bool
  storeValidationHandle: Future[void]
    ## The Store validation loop. Nil when Store-based reliability is off.
  attemptInterval*: timer.Duration
  maxValidationAge*: timer.Duration ## How long a task may wait for a Store confirmation.
  archiveTime*: timer.Duration
    ## A task is asked about in Store only once its propagation and its last
    ## Store query are older than this, giving a Store node time to archive it.
    ## Also the pause of the Store validation loop while no Store peer is available.
  storeValidationInterval: timer.Duration

proc new*(
    T: typedesc[SendService],
    preferP2PReliability: bool,
    waku: Waku,
    rateLimitManager: RateLimitManager,
    transports: Transports,
    anonymityLevel: AnonymityLevel = AnonymityLevel.None,
    attemptInterval: timer.Duration = SendAttemptInterval,
    maxValidationAge: timer.Duration = StoreValidationWindow,
    storeValidationInterval: timer.Duration = StoreValidationInterval,
    maxSendsInFlight: int = MaxSendsInFlight,
): Result[T, string] =
  if attemptInterval <= ZeroDuration:
    return err("attemptInterval must be positive")
  # With zero, the Store validation loop runs with no pause.
  if storeValidationInterval <= ZeroDuration:
    return err("storeValidationInterval must be positive")
  if maxSendsInFlight <= 0:
    return err("maxSendsInFlight must be positive")

  case anonymityLevel
  of AnonymityLevel.None:
    if transports[Transport.Relay].isNone() and transports[Transport.Lightpush].isNone():
      return err("The node has no relay and no lightpush client to send with")
  of AnonymityLevel.Preferred, AnonymityLevel.Required:
    if transports[Transport.Mix].isNone():
      return err("Mix sending needs a lightpush client, which is not mounted")

  let checkStoreForMessages = preferP2PReliability and waku.isStoreMounted()

  let sendService = SendService(
    brokerCtx: waku.brokerCtx,
    deliveryTasks: initOrderedTable[WakuMessageHash, DeliveryTask](),
    maxSendsInFlight: maxSendsInFlight,
    transports: transports,
    anonymityLevel: anonymityLevel,
    rateLimitManager: rateLimitManager,
    waku: waku,
    checkStoreForMessages: checkStoreForMessages,
    attemptInterval: attemptInterval,
    maxValidationAge: maxValidationAge,
    archiveTime: ArchiveTime,
    storeValidationInterval: storeValidationInterval,
  )

  return ok(sendService)

func storeValidationKey(task: DeliveryTask): Moment =
  ## The last Store query time, or the first propagation for a task never asked.
  if task.lastStoreQueryTime.isSome():
    task.lastStoreQueryTime.get()
  else:
    task.firstPropagatedTime.get()

proc nextStoreValidationBatch*(
    self: SendService, tasks: openArray[DeliveryTask], now: Moment
): seq[DeliveryTask] =
  ## Selects up to one Store page of tasks that wait for a Store confirmation and
  ## whose propagation and last query are older than `archiveTime`. The tasks that
  ## waited longest come first.
  const batchSize = int(MaxPageSize)
  var eligible: seq[DeliveryTask]
  for task in tasks:
    if not task.awaitsStore():
      continue
    if now - task.firstPropagatedTime.get() <= self.archiveTime:
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

func hasTask(self: SendService, task: DeliveryTask): bool =
  return self.deliveryTasks.getOrDefault(task.msgHash) == task

proc remove(self: SendService, task: DeliveryTask) =
  if not self.hasTask(task):
    return
  if task.chargeUnused:
    self.rateLimitManager.release(task.charge)
  self.deliveryTasks.del(task.msgHash)

proc queryStoreForTasks(
    self: SendService, shards: seq[PubsubTopic], tasks: seq[DeliveryTask]
) {.async.} =
  ## Sends one Store query about `tasks`, whose messages are in `shards`.
  ## Confirms the tasks that the answer reports, and marks the others as missed.
  ## With no `shards`, any Store peer can answer.
  # TODO: confirm hash format for store query!!!
  let request = StoreQueryRequest(
    includeData: false,
    messageHashes: tasks.mapIt(it.msgHash),
    paginationLimit: Opt.some(uint64(tasks.len)),
  )
  let query = self.waku.storeQueryToAny(request, shards)
  if not await query.withTimeout(StoreValidationQueryTimeout):
    debug "Store validation query timed out", messageCount = tasks.len
    return

  let storeResp: StoreQueryResponse = query.read().valueOr:
    debug "Failed to get store validation for messages",
      messageCount = tasks.len, error = $error
    return

  # The Store peer decides which hashes its answer lists, and it can list hashes
  # that this node did not ask about. Only a task that waits for a Store
  # confirmation takes a hash from the answer, so a message sent over mix is never
  # confirmed.
  var reported: HashSet[WakuMessageHash]
  for item in storeResp.messages:
    reported.incl(item.messageHash)
    let task = self.deliveryTasks.getOrDefault(item.messageHash)
    if not task.isNil() and task.awaitsStore():
      task.confirmed = true
      task.storeAnswer.complete()

  if storeResp.paginationCursor.isSome():
    # The answer is partial: a hash that it lacks can be on the next page.
    return
  for task in tasks:
    if task.msgHash notin reported and task.awaitsStore():
      task.storeMissed = true

proc checkMsgsInStore(self: SendService, batch: seq[DeliveryTask]) {.async.} =
  ## Asks Store about one batch. The tasks that a Store peer did not report go in
  ## one query, which can ask each Store peer. The other tasks go in one query for
  ## each shard.
  let now = Moment.now()
  var missed: seq[DeliveryTask]
  var byShard: OrderedTable[PubsubTopic, seq[DeliveryTask]]
  var checks: seq[Future[void]]
  for task in batch:
    task.lastStoreQueryTime = Opt.some(now)
    if task.storeMissed:
      missed.add(task)
    else:
      byShard.mgetOrPut(task.pubsubTopic, @[]).add(task)
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
      let batch =
        self.nextStoreValidationBatch(toSeq(self.deliveryTasks.values), Moment.now())
      if batch.len > 0:
        if self.waku.hasStorePeer():
          await self.checkMsgsInStore(batch)
        else:
          debug "Skipping store validation, no store peer available",
            messageCount = batch.len
          delay = min(self.archiveTime, self.maxValidationAge)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      error "Exception in a Store validation round", error = exc.msg
    await sleepAsync(delay)

proc fail(
    self: SendService, task: DeliveryTask, kind: MessageErrorKind, errorDesc: string
) =
  task.state = DeliveryState.FailedToDeliver
  MessageErrorEvent.emit(self.brokerCtx, task.msgHash.to0xHex(), kind, errorDesc)
  self.remove(task)

proc checkMixSize(self: SendService, task: DeliveryTask): Result[void, SendError] =
  ## Refuses a message that is too large for one mix message.
  let message = self.waku.messageForSizeCheck(task.msg).valueOr:
    return err(
      SendError.init(
        SendErrorKind.Other, "Failed to determine RLN proof size: " & $error
      )
    )
  let (size, limit) = self.waku.mixLightpushSize(task.pubsubTopic, message)
  if size > limit:
    return err(SendError.init(SendErrorKind.TooLarge, mixTooLargeDesc(size, limit)))
  return ok()

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

proc accept(self: SendService, task: DeliveryTask): Result[void, SendError] =
  if not self.running:
    return err(SendError.init(SendErrorKind.Other, "The send service does not run"))
  ?self.checkMessageSize(task)

  if self.deliveryTasks.len >= self.maxSendsInFlight:
    return err(
      SendError.init(
        SendErrorKind.QueueFull,
        "The node has " & $self.maxSendsInFlight & " sends with no last event",
      )
    )

  # Ephemeral traffic is refused near the limit, so it cannot eat into the
  # budget left for durable messages.
  let quotaState = self.rateLimitManager.quotaState()
  if task.isEphemeral() and quotaState != QuotaState.Normal:
    return
      err(self.rateLimitedError("Ephemeral message refused: rate limit " & $quotaState))
  task.charge = self.rateLimitManager.admit().valueOr:
    return err(self.rateLimitedError("The rate-limit budget of the epoch is spent"))
  task.chargeUnused = true
  self.deliveryTasks[task.msgHash] = task
  return ok()

proc ensureProof(
    self: SendService, task: DeliveryTask
): Future[Opt[AttemptResult]] {.async: (raises: [CancelledError]).} =
  ## Attaches the RLN proof when the message needs one.
  ## Returns the result of the attempt when no proof came.
  if not self.waku.needsRlnProof(task.msg):
    return Opt.none(AttemptResult)
  if task.proofRefused:
    # The new proof draws a new RLN message id.
    task.charge = self.rateLimitManager.admit().valueOr:
      return Opt.some(AttemptResult.invalid(NoBudgetForNewProofReason))
    task.chargeUnused = true
    task.proofRefused = false
  try:
    task.msg = (await self.waku.attachRlnProof(task.msg)).valueOr:
      let desc = "Failed to attach RLN proof: " & $error
      case error.kind
      of RlnErrorKind.Permanent, RlnErrorKind.BudgetExhausted:
        return Opt.some(AttemptResult.invalid(desc))
      of RlnErrorKind.NotReady, RlnErrorKind.Transient:
        return Opt.some(AttemptResult.notPropagated(desc))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return
      Opt.some(AttemptResult.notPropagated("Exception in the proof attach: " & exc.msg))
  task.chargeUnused = false
  return Opt.none(AttemptResult)

proc checkBeforeAttempt(
    self: SendService, task: DeliveryTask, transport: Transport
): Opt[AttemptResult] =
  ## The result of an attempt that `transport` cannot make now. It makes no network call.
  let api = self.transports[transport].valueOr:
    return
      Opt.some(AttemptResult.invalid("This node has no " & $transport & " transport"))
  let sized = self.waku.messageForSizeCheck(task.msg).valueOr:
    task.msg
  return api.checkBeforeAttempt(task.pubsubTopic, sized)

proc transmit(
    self: SendService,
    task: DeliveryTask,
    transport: Transport,
    lightpushPeers: seq[RemotePeerInfo],
): Future[AttemptResult] {.async: (raises: [CancelledError]).} =
  # The message gets no proof for a transport that cannot take it now.
  let failure = self.checkBeforeAttempt(task, transport)
  if failure.isSome():
    return failure.get()
  let api = self.transports[transport].get()

  let noProof = await self.ensureProof(task)
  if noProof.isSome():
    return noProof.get()

  if transport == Transport.Mix:
    # Mark before the attempt: the exit publishes before it replies, so a message
    # whose reply is lost is still on the network. From here on, the send service
    # logs no hash for this task at INFO or ERROR.
    task.anonymized = true
  task.tryCount.inc()
  task.chargeUnused = false
  debug "Trying message delivery",
    transport, msgHash = task.msgHash.to0xHex(), tryCount = task.tryCount
  return
    await api.attempt(task.pubsubTopic, task.msg, lightpushPeers, task.relayValidated)

proc waitForStore(
    self: SendService, task: DeliveryTask, timeout: timer.Duration
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Waits for a Store node to report the message, for at most `timeout`.
  ## The Store validation loop asks the Store nodes only while a caller waits here.
  if task.confirmed:
    return true
  if timeout <= ZeroDuration or not self.hasTask(task):
    return false
  let answer = Future[void].Raising([CancelledError]).init("store answer")
  task.storeAnswer = answer
  try:
    discard await answer.withTimeout(timeout)
  finally:
    if task.storeAnswer == answer:
      task.storeAnswer = nil
  return task.confirmed

proc sendAttempt(
    self: SendService,
    task: DeliveryTask,
    transport: Transport,
    timeout: timer.Duration,
    lightpushPeers: seq[RemotePeerInfo] = @[],
): Future[SendAttempt] {.async: (raises: [CancelledError]).} =
  ## Makes one attempt of the message of `task` over `transport`. The attempt and
  ## the wait for its confirmation take `timeout` at most, and nothing of the
  ## attempt runs after the return.
  ## `task` is a message that the service accepted. The task keeps its RLN proof.
  ## So a later attempt sends the same proof and gets no new charge, unless a node
  ## refused that proof.
  ## A lightpush attempt uses the first of `lightpushPeers`. With no such peer,
  ## the node selects one.
  let deadline = Moment.now() + timeout

  var transmitted =
    try:
      await self.transmit(task, transport, lightpushPeers).wait(timeout)
    except AsyncTimeoutError:
      AttemptResult.notPropagated()

  if transmitted.validated:
    task.relayValidated = true
  if transmitted.proofRefused:
    if self.waku.onRlnProofRejected():
      task.msg.proof = @[]
      task.proofRefused = true
      task.relayValidated = false
    else:
      # No backend can refresh, so a new proof gets the same refusal.
      transmitted.outcome = AttemptOutcome.Invalid

  var attempt = SendAttempt(
    msgHash: task.msgHash, outcome: transmitted.outcome, desc: transmitted.desc
  )
  if transmitted.outcome != AttemptOutcome.Propagated:
    debug "Message not propagated",
      transport, msgHash = task.msgHash.to0xHex(), error = transmitted.desc
    return attempt

  debug "Message propagated", transport, msgHash = task.msgHash.to0xHex()
  if task.firstPropagatedTime.isNone():
    task.state = DeliveryState.SuccessfullyPropagated
    task.firstPropagatedTime = Opt.some(Moment.now())
    task.propagatedAnonymously = transport == Transport.Mix
  attempt.confirmation =
    if not self.checkStoreForMessages or task.isEphemeral():
      Confirmation.NotExpected
    elif transport == Transport.Mix:
      # The reply of the mix exit is the confirmation of a mixed send. A Store
      # query would name the message from the address of this node.
      Confirmation.Confirmed
    elif await self.waitForStore(task, deadline - Moment.now()):
      Confirmation.Confirmed
    else:
      Confirmation.NotConfirmed
  return attempt

func attemptPlan*(chain: openArray[Transport], attempts: int): seq[Transport] =
  ## The transport of each attempt of `send`. The first transport of `chain` gets
  ## the first half of the attempts, and the other transports share the second
  ## half in the same way.
  if chain.len == 0 or attempts <= 0:
    return @[]
  if chain.len == 1:
    return newSeqWith(attempts, chain[0])
  let head = max(1, attempts div 2)
  return newSeqWith(head, chain[0]) & attemptPlan(chain[1 .. ^1], attempts - head)

proc transportChain(self: SendService): seq[Transport] =
  ## The transports of this node for `send`, in the order in which it uses them.
  var nonMix: seq[Transport]
  if self.transports[Transport.Relay].isSome():
    nonMix.add(Transport.Relay)
  if self.transports[Transport.Lightpush].isSome():
    nonMix.add(Transport.Lightpush)
  case self.anonymityLevel
  of AnonymityLevel.None:
    return nonMix
  of AnonymityLevel.Required:
    return @[Transport.Mix]
  of AnonymityLevel.Preferred:
    return @[Transport.Mix] & nonMix

proc nextLightpushPeer(self: SendService, task: DeliveryTask): seq[RemotePeerInfo] =
  ## A lightpush peer for the next attempt of `task`.
  ## It is a peer that got no attempt of the task, when the node knows one.
  let peer = self.waku.selectLightpushPeer(task.pubsubTopic, task.lightpushPeersTried).valueOr:
    return @[]
  if peer.peerId notin task.lightpushPeersTried:
    task.lightpushPeersTried.add(peer.peerId)
  return @[peer]

proc deliver(
    self: SendService, task: DeliveryTask
) {.async: (raises: [CancelledError]).} =
  ## Makes the attempts of a task of `send`, one in each attempt interval.
  ## Each attempt uses one transport. A transport that cannot carry the message
  ## gets no attempt. A relay that propagated the message gives its later attempts
  ## to the next transport.
  var chain: seq[Transport]
  var reason = ""
  for transport in self.transportChain():
    let failure = self.checkBeforeAttempt(task, transport)
    # `Preferred` does not wait for a mix that cannot attempt the message now.
    let noAttempt =
      failure.isSome() and (
        failure.get().outcome == AttemptOutcome.Invalid or
        (transport == Transport.Mix and self.anonymityLevel == AnonymityLevel.Preferred)
      )
    if noAttempt:
      reason = failure.get().desc
    else:
      chain.add(transport)
  let plan = attemptPlan(chain, MaxSendAttempts)
  let started = Moment.now()
  var relayPropagated = false
  var confirmation = Confirmation.NotConfirmed

  for index in 0 ..< plan.len:
    var transports = chain[chain.find(plan[index]) .. ^1]
    if relayPropagated:
      # The peers of the relay drop a message that they already have.
      transports.keepItIf(it != Transport.Relay)
    if transports.len == 0:
      break
    let attemptStart = started + self.attemptInterval * index
    if Moment.now() < attemptStart:
      await sleepAsync(attemptStart - Moment.now())
    let left = attemptStart + self.attemptInterval - Moment.now()

    let transport = transports[0]
    let peers =
      if transport == Transport.Lightpush:
        self.nextLightpushPeer(task)
      else:
        @[]
    let res = await self.sendAttempt(task, transport, left, peers)
    case res.outcome
    of AttemptOutcome.NotPropagated:
      reason = res.desc
    of AttemptOutcome.Invalid:
      reason = res.desc
      break
    of AttemptOutcome.Propagated:
      if not task.propagatedEventEmitted:
        # INFO lines reach log collectors, where a hash would tie this node to an
        # anonymized message.
        info "Message successfully propagated", msgHash = task.loggedHash()
        MessagePropagatedEvent.emit(self.brokerCtx, task.msgHash.to0xHex())
        task.propagatedEventEmitted = true
      relayPropagated = relayPropagated or transport == Transport.Relay
      confirmation = res.confirmation
      if confirmation != Confirmation.NotConfirmed:
        break

  self.sendsEnded.inc()
  if not task.propagatedEventEmitted:
    if reason.len == 0:
      reason = SendWindowElapsedReason
    # A mix exit may have published the message even though its reply was lost.
    error "Failed to send message", msgHash = task.loggedHash(), error = reason
    self.fail(task, MessageErrorKind.NotPropagated, reason)
    return

  if confirmation == Confirmation.NotConfirmed:
    # After its last attempt, `send` only asks the Store nodes.
    let windowEnd = task.firstPropagatedTime.get() + self.maxValidationAge
    if await self.waitForStore(task, windowEnd - Moment.now()):
      confirmation = Confirmation.Confirmed

  case confirmation
  of Confirmation.Confirmed:
    task.state = DeliveryState.SuccessfullyValidated
    info "Message successfully sent", msgHash = task.loggedHash()
    MessageSentEvent.emit(self.brokerCtx, task.msgHash.to0xHex())
    self.remove(task)
  of Confirmation.NotConfirmed:
    info "Message propagated but not validated by a store node within time window; stop trying.",
      msgHash = task.loggedHash()
    recordStoreValidationTimeout()
    self.fail(task, MessageErrorKind.NotStored, StoreValidationTimeoutReason)
  of Confirmation.NotExpected:
    self.remove(task)

proc startDeliverSoon(self: SendService, task: DeliveryTask) =
  ## Starts `deliver` in a later turn of the event loop.
  ## The caller of `enqueue` gets its result before any event of the task.
  ## A stop before that turn fails the task, so `deliver` must not start then.
  callSoon(
    proc(udata: pointer) {.gcsafe, raises: [].} =
      if self.running and self.hasTask(task):
        task.deliverHandle = self.deliver(task)
  )

proc enqueue*(self: SendService, task: DeliveryTask): Result[void, SendError] =
  assert(not task.isNil(), "task for enqueue must not be nil")
  if task.msgHash in self.deliveryTasks:
    return err(
      SendError.init(SendErrorKind.Duplicate, "The node already sends this message")
    )
  if self.anonymityLevel == AnonymityLevel.Required:
    ?self.checkMixSize(task)
  self.accept(task).isOkOr:
    debug "Send refused", msgHash = task.msgHash.to0xHex(), error = $error
    return err(error)

  debug "Send accepted", msgHash = task.msgHash.to0xHex()
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
    if not task.deliverHandle.isNil() and not task.deliverHandle.finished():
      handles.add(task.deliverHandle)
  await cancelAndWait(handles)
  for task in toSeq(self.deliveryTasks.values):
    let kind =
      if task.firstPropagatedTime.isSome():
        MessageErrorKind.NotStored
      else:
        MessageErrorKind.NotPropagated
    self.fail(task, kind, ServiceStoppedReason)

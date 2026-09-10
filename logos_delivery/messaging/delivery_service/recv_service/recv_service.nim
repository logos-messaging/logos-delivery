## This module is in charge of taking care of the messages that this node is expecting to
## receive and is backed by store-v3 requests to get an additional degree of certainty
##

import results, std/[tables, sequtils, sets]
import chronos, chronicles
import brokers/broker_context
import
  ./backfill,
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/waku/persistency/persistency,
  logos_delivery/waku/[waku_core, waku_core/topics, waku_store/common],
  logos_delivery/waku/waku,
  logos_delivery/waku/api/[store, subscriptions]
import
  logos_delivery/api/events/kernel_events,
  logos_delivery/api/events/messaging_client_events # MessageReceivedEvent

const MaxMessageLife = chronos.minutes(7) ## Max time we will keep track of rx messages

const PruneOldMsgsPeriod = chronos.minutes(1)

const DelayExtra* = chronos.seconds(5)
  ## Additional security time to overlap the missing messages queries

const ActivityWriteInterval* = chronos.seconds(10)
  ## Least time between two recovery hint writes from received messages.

const CatchUpRetryPeriod* = chronos.seconds(30)
  ## Wait between two Store attempts of the startup catch-up.

const CatchUpSettlePeriod* = chronos.seconds(10)
  ## Wait for one more subscription once the startup catch-up has caught up. An
  ## app restores its subscriptions in one turn; a person takes seconds.

const
  DefaultBackfillRequestTimeout = chronos.seconds(10)
  MinBackfillRequestTimeoutSeconds = 1
  MaxBackfillRequestTimeoutSeconds = 300

type TupleHashAndMsg =
  tuple[hash: WakuMessageHash, msg: WakuMessage, pubsubTopic: PubsubTopic]

type BackfillState* = object
  ## Settings and state of the startup catch-up. `backfill.nim` has the mechanism.
  enabled*: bool
  queryTimeout*: Duration
  task: Future[void] ## the startup catch-up
  hintListener: Opt[MessageReceivedEventListener]
    ## advances the hint per received message; installed when the catch-up completes

type RecvService* = ref object of RootObj
  brokerCtx: BrokerContext
  waku: Waku
  seenMsgListener: MessageSeenEventListener
  connStatusListener: EventConnectionStatusChangeListener

  recentReceivedMsgs: Table[WakuMessageHash, Timestamp]
    ## hash of each message received in the last `MaxMessageLife`, with its
    ## local receipt time

  online: bool
    ## Whether we currently have connectivity (ConnectionStatus != Disconnected).
    ## Status events carry only the new state, so this remembers the previous one
    ## to act on edges, not every event: `PartiallyConnected`/`Connected` flicker
    ## while still online, and the bool collapses that — backfill once when we come
    ## online, stamp the gap start when we go offline.
  backfillHandler: Future[void] ## in-flight store backfill task
  msgPrunerHandler: Future[void] ## removes too old messages

  startTimeToCheck: Timestamp
  endTimeToCheck: Timestamp

  backfill: BackfillState ## the startup catch-up from the persisted hint
  stopping: bool
    ## Lets the startup catch-up exit at stop. `storeQueryToAny`, `sendStoreRequest`,
    ## `dialPeer` and the brokers request path swallow `CancelledError`, so a cancel
    ## may not reach the task. Re-raise it at those sites, then delete this.

proc getMissingMsgsFromStore(
    self: RecvService, msgHashes: seq[WakuMessageHash]
): Future[Result[seq[TupleHashAndMsg], string]] {.async.} =
  let storeResp: StoreQueryResponse = (
    await self.waku.storeQueryToAny(
      StoreQueryRequest(includeData: true, messageHashes: msgHashes)
    )
  ).valueOr:
    return err("getMissingMsgsFromStore: " & $error)

  let otherwiseMsg = WakuMessage()
  let otherwiseTopic = PubsubTopic("")
  return ok(
    storeResp.messages.mapIt(
      (
        hash: it.messageHash,
        msg: it.message.get(otherwiseMsg),
        pubsubTopic: it.pubsubTopic.get(otherwiseTopic),
      )
    )
  )

proc processIncomingMessage(
    self: RecvService, pubsubTopic: string, message: WakuMessage
): bool =
  ## Return false if the incoming message is from a non-subscribed topic,
  ## or if the message is a duplicate (recently-seen). Otherwise, save it as
  ## recently-seen, emit a MessageReceivedEvent, and return true.

  if not self.waku.isContentSubscribed(pubsubTopic, message.contentTopic):
    trace "skipping message as I am not subscribed",
      shard = pubsubTopic, contentTopic = message.contentTopic
    return false

  let msgHash = computeMessageHash(pubsubTopic, message)
  if self.recentReceivedMsgs.hasKey(msgHash):
    trace "skipping duplicate message",
      shard = pubsubTopic,
      contentTopic = message.contentTopic,
      msg_hash = msgHash.to0xHex()
    return false

  # Local receipt time: a message recovered from Store stays known for the
  # full period whatever its own timestamp.
  self.recentReceivedMsgs[msgHash] = getNowInNanosecondTime()
  info "Message received",
    msg_hash = msgHash.to0xHex(),
    contentTopic = message.contentTopic,
    pubsubTopic = pubsubTopic
  MessageReceivedEvent.emit(self.brokerCtx, msgHash.to0xHex(), message)
  return true

proc checkStore*(self: RecvService) {.async.} =
  ## Checks the store for messages that were not received directly and
  ## delivers them via MessageReceivedEvent.
  if not self.waku.isStoreMounted():
    debug "recv service has no store client mounted, skipping store check"
    return

  self.endTimeToCheck = getNowInNanosecondTime()

  ## query store and deliver new recovered messages per subscribed topic
  for (pubsubTopic, contentTopics) in self.waku.subscribedContentTopics():
    let storeResp: StoreQueryResponse = (
      await self.waku.storeQueryToAny(
        StoreQueryRequest(
          includeData: false,
          pubsubTopic: Opt.some(pubsubTopic),
          contentTopics: toSeq(contentTopics),
          startTime: Opt.some(self.startTimeToCheck - DelayExtra.nanos),
          endTime: Opt.some(self.endTimeToCheck + DelayExtra.nanos),
        )
      )
    ).valueOr:
      debug "checkStore failed to get remote msgHashes",
        pubsubTopic = pubsubTopic, cTopics = toSeq(contentTopics), error = $error
      continue

    ## compare the msgHashes seen from the store vs the ones received directly
    let msgHashesInStore = storeResp.messages.mapIt(it.messageHash)
    let missedHashes: seq[WakuMessageHash] =
      msgHashesInStore.filterIt(not self.recentReceivedMsgs.hasKey(it))

    if missedHashes.len > 0:
      info "missed messages detected, checking store for missed messages",
        pubsubTopic = pubsubTopic, missedCount = missedHashes.len

      ## Now retrieve the missing WakuMessages and deliver them
      let missingMsgsRet = await self.getMissingMsgsFromStore(missedHashes)
      if missingMsgsRet.isOk():
        for msgTuple in missingMsgsRet.get():
          if self.processIncomingMessage(msgTuple.pubsubTopic, msgTuple.msg):
            debug "recv service store-recovered message",
              msg_hash = shortLog(msgTuple.hash), pubsubTopic = msgTuple.pubsubTopic
      else:
        debug "Failed to retrieve missing messages: ", error = $missingMsgsRet.error

  ## update next check times
  self.startTimeToCheck = self.endTimeToCheck

proc onConnectionStatusChange(self: RecvService, status: ConnectionStatus) =
  ## Backfill the store over the window we were offline (`Disconnected`).
  let nowOnline = status != ConnectionStatus.Disconnected
  if nowOnline == self.online:
    return
  self.online = nowOnline

  if not nowOnline:
    self.startTimeToCheck = getNowInNanosecondTime()
    return

  # At most one backfill in flight; skip if the previous is still running.
  # Triggers are paced by health-monitor status changes, so overlap is unlikely.
  if self.backfillHandler.isNil() or self.backfillHandler.finished():
    info "recv service backfilling missed messages after coming back online"
    self.backfillHandler = self.checkStore()

proc startupCatchUp(self: RecvService, job: Job) {.async.} =
  ## The one Store catch-up of a service run, from the persisted hint.
  let startedAt = getNowInNanosecondTime() # before the first await
  let stored = (await job.readRecoveryHint()).valueOr:
    if not self.stopping:
      warn "automatic Store catch-up suspended for this run", reason = error
    return
  let hint =
    if stored.isSome():
      stored.get()
    else:
      await job.writeRecoveryHint(startedAt) # first run: the next run starts here
      startedAt
  let since = hint - BackfillOverlap
  var completed: HashSet[BackfillTopic]
  let progress = newTable[BackfillTopic, Timestamp]() # a failed topic's next page start
  var caughtUpAt = Timestamp(0)
    # the first completing pass's bound; covered for every topic
  var settleUntil: Opt[Moment] # set when there is nothing left to do
  let query: BackfillQuery = proc(
      request: StoreQueryRequest
  ): Future[Result[StoreQueryResponse, string]] {.async.} =
    if self.stopping:
      return err("receive service is stopping")
    return await self.waku.storeQueryToAny(request)
  let deliver: BackfillDeliver = proc(
      pubsubTopic: PubsubTopic, message: WakuMessage
  ): bool {.gcsafe, raises: [].} =
    if not self.waku.isContentSubscribed(pubsubTopic, message.contentTopic):
      return false
    discard self.processIncomingMessage(pubsubTopic, message)
    return true
  let subscribed = newAsyncEvent()
  let onSubscribed = proc(event: ContentTopicSubscribedEvent) {.async: (raises: []).} =
    subscribed.fire()
  let listener = ContentTopicSubscribedEvent.listen(self.brokerCtx, onSubscribed).valueOr:
    warn "automatic Store catch-up suspended for this run", reason = error
    return
  defer:
    await ContentTopicSubscribedEvent.dropListener(self.brokerCtx, listener)
  while true:
    if not job.running:
      warn "automatic Store catch-up suspended for this run",
        reason = "persistency job is closed"
      return
    let pending =
      backfillTopics(self.waku.subscribedContentTopics()).filterIt(it notin completed)
    if pending.len == 0:
      if completed.len > 0:
        # Caught up. The app may still be restoring its subscriptions: wait for
        # the next, and finish when none comes. A wake that brings no work
        # spends the same wait.
        if settleUntil.isNone():
          settleUntil = Opt.some(Moment.now() + CatchUpSettlePeriod)
        let remaining = settleUntil.get() - Moment.now()
        if remaining <= ZeroDuration or
            not await subscribed.wait().withTimeout(remaining):
          break
      else:
        await subscribed.wait() # nothing subscribed yet
      subscribed.clear()
      continue
    settleUntil = Opt.none(Moment) # new work; settle after it
    if not self.waku.hasStorePeer():
      await sleepAsync(CatchUpRetryPeriod) # nobody to ask yet
      continue
    let cutoff = getNowInNanosecondTime() # this pass's bound; live covers from here
    let exhausted = await runCatchUpPass(
      pending, progress, since, cutoff, self.backfill.queryTimeout, query, deliver
    )
    if self.stopping:
      return
    if caughtUpAt == 0 and exhausted.len > 0:
      caughtUpAt = cutoff
    for topic in exhausted:
      completed.incl(topic)
    if exhausted.len < pending.len:
      await sleepAsync(CatchUpRetryPeriod) # a topic failed; ask again
  await job.writeRecoveryHint(caughtUpAt)
  if self.stopping:
    return
  # From here every accepted message, live or recovered from Store, moves the
  # hint to now, at most once per `ActivityWriteInterval`.
  var lastWrite = Moment()
  let onReceived = proc(event: MessageReceivedEvent) {.async: (raises: []).} =
    let now = Moment.now()
    if not job.running or now - lastWrite < ActivityWriteInterval:
      return
    lastWrite = now # before the await: a burst writes once
    try:
      await job.writeRecoveryHint(getNowInNanosecondTime())
    except CancelledError:
      discard
  let receipts = MessageReceivedEvent.listen(self.brokerCtx, onReceived).valueOr:
    warn "recovery hint writes off for this run", reason = error
    return
  self.backfill.hintListener = Opt.some(receipts)

proc waitForStartupCatchUp*(self: RecvService) {.async.} =
  ## Waits for the startup catch-up to exit. Cancelling the wait leaves the
  ## catch-up running.
  if not self.backfill.task.isNil():
    await self.backfill.task.join()

proc init*(T: type BackfillState, conf: MessagingClientConf): Result[T, string] =
  ## Rejects a timeout outside `MinBackfillRequestTimeoutSeconds` ..
  ## `MaxBackfillRequestTimeoutSeconds`.
  var queryTimeout = DefaultBackfillRequestTimeout
  if conf.backfillRequestTimeoutSeconds.isSome():
    let seconds = conf.backfillRequestTimeoutSeconds.get()
    if seconds < MinBackfillRequestTimeoutSeconds or
        seconds > MaxBackfillRequestTimeoutSeconds:
      return err(
        "backfillRequestTimeoutSeconds must be between " &
          $MinBackfillRequestTimeoutSeconds & " and " & $MaxBackfillRequestTimeoutSeconds &
          ", got " & $seconds
      )
    queryTimeout = chronos.seconds(seconds)
  return ok(T(enabled: conf.backfillEnabled.get(true), queryTimeout: queryTimeout))

proc new*(T: typedesc[RecvService], waku: Waku, backfill: BackfillState): T =
  ## The storeClient will help to acquire any possible missed messages

  let now = getNowInNanosecondTime()
  var recvService = RecvService(
    waku: waku, startTimeToCheck: now, brokerCtx: waku.brokerCtx, backfill: backfill
  )

  return recvService

proc loopPruneOldMessages(self: RecvService) {.async.} =
  while true:
    let oldestAllowedTime = getNowInNanosecondTime() - MaxMessageLife.nanos
    var expired: seq[WakuMessageHash]
    for msgHash, rxTime in self.recentReceivedMsgs:
      if rxTime <= oldestAllowedTime:
        expired.add(msgHash)
    for msgHash in expired:
      self.recentReceivedMsgs.del(msgHash)
    await sleepAsync(PruneOldMsgsPeriod)

proc startRecvService*(self: RecvService, job: Job) =
  ## `job` is the messaging layer's Persistency job, nil when the layer has none.
  self.stopping = false
  self.msgPrunerHandler = self.loopPruneOldMessages()

  self.seenMsgListener = MessageSeenEvent.listen(
    self.brokerCtx,
    proc(event: MessageSeenEvent) {.async: (raises: []).} =
      discard self.processIncomingMessage(event.topic, event.message),
  ).valueOr:
    error "Failed to set MessageSeenEvent listener", error = error
    quit(QuitFailure)

  self.connStatusListener = EventConnectionStatusChange.listen(
    self.brokerCtx,
    proc(event: EventConnectionStatusChange) {.async: (raises: []).} =
      self.onConnectionStatusChange(event.connectionStatus),
  ).valueOr:
    error "Failed to set EventConnectionStatusChange listener", error = error
    quit(QuitFailure)

  if self.backfill.enabled and not job.isNil():
    self.backfill.task = self.startupCatchUp(job)

proc stopRecvService*(self: RecvService) {.async.} =
  self.stopping = true
  await MessageSeenEvent.dropListener(self.brokerCtx, self.seenMsgListener)
  await EventConnectionStatusChange.dropListener(
    self.brokerCtx, self.connStatusListener
  )
  if self.backfill.hintListener.isSome():
    await MessageReceivedEvent.dropListener(
      self.brokerCtx, self.backfill.hintListener.get()
    )
    self.backfill.hintListener = Opt.none(MessageReceivedEventListener)
  var tasks: seq[Future[void]]
  for task in [self.backfillHandler, self.msgPrunerHandler, self.backfill.task]:
    if not task.isNil():
      tasks.add(task)
  await cancelAndWait(tasks) # every cancel requested before any wait
  self.backfillHandler = nil
  self.msgPrunerHandler = nil
  self.backfill.task = nil

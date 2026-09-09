## This module is in charge of taking care of the messages that this node is expecting to
## receive and is backed by store-v3 requests to get an additional degree of certainty
##
## Relay and filter deliver live messages. Store catch-up runs once after a
## start, when the node has a Store peer. It queries every subscribed topic
## from the last time the node was online, which `backfill.nim` keeps in
## Persistency. While the node is online and every topic is caught up, the
## service advances that timestamp.

import
  std/[sequtils, sets, tables, algorithm],
  results,
  chronos,
  chronicles,
  brokers/broker_context
import
  ./backfill,
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/waku/persistency/persistency,
  logos_delivery/waku/[waku_core, waku_core/topics, waku_store/common],
  logos_delivery/waku/waku,
  logos_delivery/waku/api/[peer_manager, store, subscriptions],
  logos_delivery/api/events/kernel_events, # MessageSeenEvent
  logos_delivery/api/events/messaging_client_events # MessageReceivedEvent

const MaxMessageLife = chronos.minutes(7) ## Max time we will keep track of rx messages

const MaintenancePeriod = chronos.seconds(1)
  ## Cadence of cache pruning and of the catch-up and timestamp checks.

const LastOnlinePeriod* = chronos.seconds(10)
  ## How often the service writes the last-online timestamp while online.

const CatchUpRetryPeriod = chronos.seconds(30)
  ## Wait after a catch-up that left a topic behind before the next attempt.

const
  DefaultBackfillRequestTimeout = chronos.seconds(10)
  MaxBackfillRequestTimeoutSeconds = 300

type BackfillState* = object
  ## Store catch-up settings and progress. The mechanism is in `backfill.nim`.
  enabled*: bool
  queryTimeout*: Duration
  job: Job ## nil when disabled or storage is unavailable this run
  startedAt: Timestamp ## service start, stored when nothing is stored yet
  since: Opt[Timestamp] ## the stored timestamp at load. Catch-ups start there
  caughtUp: HashSet[BackfillTopic] ## topics caught up this run
  lastWrite: Moment
  retryAt: Moment ## no catch-up from the tick before this, after a failure
  task: Future[void] ## the catch-up in flight, if any

type RecvService* = ref object of RootObj
  brokerCtx: BrokerContext
  waku: Waku
  seenMsgListener: MessageSeenEventListener

  recentReceivedMsgs: Table[WakuMessageHash, Timestamp]
    ## hash of every message received in the last `MaxMessageLife`, with the
    ## local receipt time. A catch-up can deliver a million messages, so this
    ## is a table, not a list to scan.

  backfill: BackfillState
  maintenanceHandler: Future[void]
  stopping: bool

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

  # Local receipt time, so the cache keeps a recovered old message for the full period.
  self.recentReceivedMsgs[msgHash] = getNowInNanosecondTime()
  info "Message received",
    msg_hash = msgHash.to0xHex(),
    contentTopic = message.contentTopic,
    pubsubTopic = pubsubTopic
  MessageReceivedEvent.emit(self.brokerCtx, msgHash.to0xHex(), message)
  return true

proc subscribedTopics(self: RecvService): seq[BackfillTopic] =
  var snapshot: seq[BackfillTopic]
  for (pubsubTopic, contentTopics) in self.waku.subscribedContentTopics():
    for contentTopic in contentTopics:
      snapshot.add((pubsubTopic, contentTopic))
  snapshot.sort()
  return snapshot

proc pendingTopics(self: RecvService): seq[BackfillTopic] =
  ## Subscribed topics not caught up this run.
  self.subscribedTopics().filterIt(it notin self.backfill.caughtUp)

proc mayAdvance(self: RecvService): bool =
  ## True when a catch-up has run and every subscribed topic is caught up.
  ## With no topic caught up the timestamp stays, so a topic subscribed later
  ## still starts before this run.
  self.backfill.caughtUp.len > 0 and self.pendingTopics().len == 0

proc suspendBackfill(self: RecvService, reason: string) =
  ## The stored timestamp stays. The next start retries. At shutdown the
  ## broker reports a cancelled read as an error, which is not a failure and
  ## must not cost the final write.
  if self.stopping:
    return
  warn "automatic Store catch-up suspended for this run", reason
  self.backfill.job = nil

proc loadSince(self: RecvService): Future[Result[void, string]] {.async.} =
  ## Loads the stored timestamp once per run. Stores the service start when
  ## nothing is stored yet.
  if self.backfill.since.isSome():
    return ok()
  let stored = (await self.backfill.job.readLastOnline()).valueOr:
    return err(error)
  if stored.isSome():
    self.backfill.since = stored
    return ok()
  (await self.backfill.job.writeLastOnline(self.backfill.startedAt)).isOkOr:
    return err(error)
  self.backfill.since = Opt.some(self.backfill.startedAt)
  return ok()

proc canQueryStore(self: RecvService): Future[bool] {.async.} =
  ## A connected Store peer exists. Read fresh, and false through an outage,
  ## so the timestamp never runs ahead of what the node received.
  let peers = (await self.waku.peerIdsByProtocol(WakuStoreCodec)).valueOr:
    return false
  return peers.len > 0

proc writeLastOnlineNow(self: RecvService) {.async.} =
  ## Writes the current time and moves the start of the next catch-up with it,
  ## so a topic subscribed later queries from the last write, not from the
  ## start of the run.
  let at = getNowInNanosecondTime()
  (await self.backfill.job.writeLastOnline(at)).isOkOr:
    # One failed write is not a broken store. The timestamp stays and the
    # next attempt writes it again. At shutdown the broker reports a
    # cancelled write as an error, which is not worth a warning.
    if not self.stopping:
      warn "backfill timestamp not written", reason = error
    return
  self.backfill.lastWrite = Moment.now()
  self.backfill.since = Opt.some(at)

proc catchUpPending(self: RecvService) {.async.} =
  ## One catch-up of the topics not caught up this run. See `backfill.runCatchUp`.
  if self.stopping or self.backfill.job.isNil():
    return
  if not await self.canQueryStore():
    return # nothing to ask yet; the tick tries again when a peer connects
  (await self.loadSince()).isOkOr:
    self.suspendBackfill(error)
    return
  let pending = self.pendingTopics()
  if pending.len == 0:
    return
  let now = getNowInNanosecondTime()
  let since = self.backfill.since.get() - BackfillOverlap.nanos
  let query: BackfillQuery = proc(
      request: StoreQueryRequest
  ): Future[Result[StoreQueryResponse, string]] {.async.} =
    if self.stopping:
      return err("receive service is stopping")
    return await self.waku.storeQueryToAny(request)
  let deliver: BackfillDeliver = proc(
      pubsubTopic: PubsubTopic, message: WakuMessage
  ): bool {.gcsafe, raises: [].} =
    if self.stopping or
        not self.waku.isContentSubscribed(pubsubTopic, message.contentTopic):
      return false
    discard self.processIncomingMessage(pubsubTopic, message)
    return true
  let outcome =
    await runCatchUp(pending, since, now, self.backfill.queryTimeout, query, deliver)
  if self.stopping:
    return # shutdown owns the final write
  for topic in outcome.completedTopics:
    self.backfill.caughtUp.incl(topic)
  if outcome.completedTopics.len < pending.len:
    # A topic failed or reached the query limit. Wait before the next try.
    self.backfill.retryAt = Moment.now() + CatchUpRetryPeriod
  if outcome.queries > 0:
    debug "recv service catch-up",
      queries = outcome.queries,
      completed = outcome.completedTopics.len,
      failed = outcome.failed

proc startCatchUp(self: RecvService): Future[void] =
  ## Single flight. Explicit checks and the maintenance tick share one task.
  if self.backfill.task.isNil() or self.backfill.task.finished():
    self.backfill.task = self.catchUpPending()
  return self.backfill.task

proc checkStore*(self: RecvService) {.async.} =
  ## Runs the catch-up of the topics not caught up yet and delivers what it
  ## retrieves via MessageReceivedEvent. It returns at once when every
  ## subscribed topic is already caught up in this run.
  if self.backfill.job.isNil():
    return
  if not self.backfill.task.isNil() and not self.backfill.task.finished():
    await self.backfill.task # let a catch-up in flight finish first
  await self.startCatchUp()

proc init*(T: type BackfillState, conf: MessagingClientConf): Result[T, string] =
  ## Rejects an out-of-range timeout. Zero is not unlimited. Disable with
  ## `backfillEnabled`.
  var queryTimeout = DefaultBackfillRequestTimeout
  if conf.backfillRequestTimeoutSeconds.isSome():
    let seconds = conf.backfillRequestTimeoutSeconds.get()
    if seconds < 1 or seconds > MaxBackfillRequestTimeoutSeconds:
      return err(
        "backfillRequestTimeoutSeconds must be between 1 and " &
          $MaxBackfillRequestTimeoutSeconds & ", got " & $seconds
      )
    queryTimeout = chronos.seconds(seconds)
  ok(T(enabled: conf.backfillEnabled.get(true), queryTimeout: queryTimeout))

proc new*(T: typedesc[RecvService], waku: Waku, backfill: BackfillState): T =
  ## The storeClient will help to acquire any possible missed messages.
  RecvService(waku: waku, brokerCtx: waku.brokerCtx, backfill: backfill)

proc maintenanceLoop(self: RecvService) {.async.} =
  while not self.stopping:
    let oldest = getNowInNanosecondTime() - MaxMessageLife.nanos
    var expired: seq[WakuMessageHash]
    for msgHash, rxTime in self.recentReceivedMsgs:
      if rxTime <= oldest:
        expired.add(msgHash)
    for msgHash in expired:
      self.recentReceivedMsgs.del(msgHash)
    if not self.backfill.job.isNil() and self.backfill.since.isNone():
      # Store the service start at once, so a crash before the first
      # catch-up still leaves a timestamp for the next run.
      (await self.loadSince()).isOkOr:
        self.suspendBackfill(error)
    if not self.backfill.job.isNil() and
        (self.backfill.task.isNil() or self.backfill.task.finished()):
      if self.pendingTopics().len > 0:
        # Until every topic is caught up, the stored timestamp stays put.
        if Moment.now() >= self.backfill.retryAt:
          discard self.startCatchUp()
      elif self.mayAdvance() and
          Moment.now() - self.backfill.lastWrite >= LastOnlinePeriod and
          await self.canQueryStore():
        await self.writeLastOnlineNow()
    if self.stopping:
      return
    await sleepAsync(MaintenancePeriod)

proc openBackfillJob(self: RecvService): Job =
  ## The Persistency job for the last-online record, or nil with a warning.
  ## Live messaging continues. The next start retries.
  let persistency = GetPersistency.request(self.brokerCtx).valueOr:
    warn "automatic Store catch-up suspended: no persistency provider", reason = error
    return nil
  if persistency.rootDir == InMemoryStoragePath:
    info "automatic Store catch-up disabled: in-memory storage root keeps no history"
    return nil
  let job = persistency.openJob(BackfillJobId).valueOr:
    warn "automatic Store catch-up suspended: could not open persistency job",
      jobId = BackfillJobId, reason = $error
    return nil
  job

proc startRecvService*(self: RecvService): Result[void, string] =
  self.stopping = false
  self.backfill.job =
    if self.backfill.enabled:
      self.openBackfillJob()
    else:
      nil
  self.backfill.startedAt = getNowInNanosecondTime()
  self.backfill.since = Opt.none(Timestamp)
  self.backfill.caughtUp = initHashSet[BackfillTopic]()
  self.backfill.lastWrite = Moment()
  self.backfill.retryAt = Moment()

  self.seenMsgListener = MessageSeenEvent.listen(
    self.brokerCtx,
    proc(event: MessageSeenEvent) {.async: (raises: []).} =
      discard self.processIncomingMessage(event.topic, event.message),
  ).valueOr:
    error "Failed to set MessageSeenEvent listener", error = error
    return err("register receive listener: " & error)

  self.maintenanceHandler = self.maintenanceLoop()
  return ok()

proc stopRecvService*(self: RecvService) {.async.} =
  ## Cancels and joins the catch-up in flight before the kernel closes
  ## Persistency, then writes the last-online timestamp when the node has a
  ## Store peer and every topic is caught up.
  self.stopping = true
  await MessageSeenEvent.dropListener(self.brokerCtx, self.seenMsgListener)
  if not self.backfill.task.isNil():
    await self.backfill.task.cancelAndWait()
    self.backfill.task = nil
  if not self.maintenanceHandler.isNil():
    await self.maintenanceHandler.cancelAndWait()
    self.maintenanceHandler = nil
  if not self.backfill.job.isNil():
    let loaded = await self.loadSince()
    if loaded.isErr():
      warn "backfill timestamp not stored at stop", reason = loaded.error
    elif self.mayAdvance() and await self.canQueryStore():
      (await self.backfill.job.writeLastOnline(getNowInNanosecondTime())).isOkOr:
        warn "backfill timestamp not written at stop", reason = error
    self.backfill.job = nil

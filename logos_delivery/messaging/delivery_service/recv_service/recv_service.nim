## This module is in charge of taking care of the messages that this node is expecting to
## receive and is backed by store-v3 requests to get an additional degree of certainty
##
## Relay and filter deliver live messages. Store catch-up runs in budgeted
## cycles at the configured cadence. Each cycle resumes every subscribed topic
## from the timestamp that `backfill.nim` keeps in Persistency.

import
  std/[sequtils, sets, algorithm], results, chronos, chronicles, brokers/broker_context
import
  ./backfill,
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/waku/persistency/persistency,
  logos_delivery/waku/[waku_core, waku_core/topics, waku_store/common],
  logos_delivery/waku/waku,
  logos_delivery/waku/api/[store, subscriptions],
  logos_delivery/api/events/kernel_events,
    # MessageSeenEvent + EventConnectionStatusChange
  logos_delivery/api/events/messaging_client_events # MessageReceivedEvent

const MaxMessageLife = chronos.minutes(7) ## Max time we will keep track of rx messages

const MaintenancePeriod = chronos.seconds(1)
  ## Cadence of cache pruning and of the check for a due cycle.

const
  DefaultBackfillLookback = chronos.hours(24)
  DefaultBackfillInterval = chronos.minutes(5)
  DefaultBackfillQueriesPerCycle = 10
  DefaultBackfillRequestTimeout = chronos.seconds(10)
  MaxBackfillSeconds = int64(int32.high)
  MaxBackfillQueriesPerCycle = 1000
  MaxBackfillRequestTimeoutSeconds = 300

type RecvMessage = object
  msgHash: WakuMessageHash
  rxTime: Timestamp ## local receipt time. We will not keep the rx messages forever

type BackfillState* = object
  ## Store catch-up settings and progress. The mechanism is in `backfill.nim`.
  enabled*: bool
  maxLookback*: Duration ## oldest history a cycle queries
  interval*: Duration ## minimum spacing between cycles
  maxQueries*: int ## Store queries per cycle, shared across topics
  queryTimeout*: Duration
  job: Job ## nil when disabled or storage is unavailable this run
  previousCycleStart: Timestamp
    ## start for a topic without a record. It precedes the subscription, so
    ## the first query fetches more, not less
  lastSample: seq[BackfillTopic]
  nextTopicIndex: int ## round-robin start for the next cycle
  cycle: Future[void] ## in flight, if any
  nextCycleAt: Moment

type RecvService* = ref object of RootObj
  brokerCtx: BrokerContext
  waku: Waku
  seenMsgListener: MessageSeenEventListener
  connStatusListener: EventConnectionStatusChangeListener

  recentReceivedMsgs: seq[RecvMessage]

  backfill: BackfillState
  online: bool ## ConnectionStatus != Disconnected, tracked on edges
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
  if self.recentReceivedMsgs.anyIt(it.msgHash == msgHash):
    trace "skipping duplicate message",
      shard = pubsubTopic,
      contentTopic = message.contentTopic,
      msg_hash = msgHash.to0xHex()
    return false

  # Local receipt time, so the cache keeps a recovered old message for the full period.
  let rxMsg = RecvMessage(msgHash: msgHash, rxTime: getNowInNanosecondTime())
  self.recentReceivedMsgs.add(rxMsg)
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
  snapshot.sort(
    proc(a, b: BackfillTopic): int =
      cmp(a, b)
  )
  return snapshot

proc sampleSubscriptions(self: RecvService): bool =
  ## True when a topic entered the subscription set since the previous sample.
  let subscribed = self.subscribedTopics()
  let entered = newlySubscribed(self.backfill.lastSample, subscribed)
  self.backfill.lastSample = subscribed
  return entered.len > 0

proc suspendBackfill(self: RecvService, reason: string) =
  ## Saved records stay. The next start retries.
  warn "automatic Store catch-up suspended for this run", reason
  self.backfill.job = nil

proc runCycle(self: RecvService) {.async.} =
  ## One budgeted pass over the subscribed topics. See `backfill.runCycle`.
  if self.stopping or self.backfill.job.isNil():
    return
  if not self.waku.isStoreMounted():
    debug "recv service has no store client mounted, skipping store catch-up"
    return
  discard self.sampleSubscriptions()
  let subscribed = self.backfill.lastSample
  let cycleStart = getNowInNanosecondTime()
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
  let outcome = await self.backfill.job.runCycle(
    subscribed, cycleStart, self.backfill.previousCycleStart,
    self.backfill.nextTopicIndex, self.backfill.maxLookback, self.backfill.maxQueries,
    self.backfill.queryTimeout, query, deliver,
  )
  if self.stopping:
    # Shutdown writes the final records. A cancelled read is not a storage failure.
    return
  self.backfill.previousCycleStart = cycleStart
  if subscribed.len > 0:
    self.backfill.nextTopicIndex = (self.backfill.nextTopicIndex + 1) mod subscribed.len
  if outcome.storageFailed:
    self.suspendBackfill("a storage operation failed")
    return
  if outcome.queries > 0:
    debug "recv service catch-up cycle",
      queries = outcome.queries, completed = outcome.completed, failed = outcome.failed

proc startCycle(self: RecvService): Future[void] =
  ## Single flight. Explicit checks, online edges and the cadence share one task.
  if self.backfill.cycle.isNil() or self.backfill.cycle.finished():
    self.backfill.nextCycleAt = Moment.now() + self.backfill.interval
    self.backfill.cycle = self.runCycle()
  return self.backfill.cycle

proc checkStore*(self: RecvService) {.async.} =
  ## Runs one catch-up cycle now and delivers what it retrieves via
  ## MessageReceivedEvent.
  if self.backfill.job.isNil():
    return
  if not self.backfill.cycle.isNil() and not self.backfill.cycle.finished():
    await self.backfill.cycle # let a cycle in flight finish first
  await self.startCycle()

proc onConnectionStatusChange(self: RecvService, status: ConnectionStatus) =
  ## Runs a cycle when the node comes online, unless one is in flight.
  let nowOnline = status != ConnectionStatus.Disconnected
  if nowOnline == self.online:
    return
  self.online = nowOnline
  if nowOnline and not self.stopping:
    discard self.startCycle()

proc checkedSeconds(
    settingName: string,
    seconds: Opt[int64],
    default: Duration,
    maxSeconds = MaxBackfillSeconds,
): Result[Duration, string] =
  if seconds.isNone():
    return ok(default)
  if seconds.get() < 1 or seconds.get() > maxSeconds:
    return err(
      settingName & " must be between 1 and " & $maxSeconds & ", got " & $seconds.get()
    )
  ok(chronos.seconds(seconds.get()))

proc init*(T: type BackfillState, conf: MessagingClientConf): Result[T, string] =
  ## Rejects out-of-range settings. Zero is not unlimited. Disable with
  ## `backfillEnabled`.
  let maxQueries = conf.backfillMaxPagesPerCycle.get(DefaultBackfillQueriesPerCycle)
  if maxQueries < 1 or maxQueries > MaxBackfillQueriesPerCycle:
    return err(
      "backfillMaxPagesPerCycle must be between 1 and " & $MaxBackfillQueriesPerCycle &
        ", got " & $maxQueries
    )
  ok(
    T(
      enabled: conf.backfillEnabled.get(true),
      maxLookback: ?checkedSeconds(
        "backfillMaxLookbackSeconds", conf.backfillMaxLookbackSeconds,
        DefaultBackfillLookback,
      ),
      interval: ?checkedSeconds(
        "backfillIntervalSeconds", conf.backfillIntervalSeconds, DefaultBackfillInterval
      ),
      maxQueries: maxQueries,
      queryTimeout: ?checkedSeconds(
        "backfillRequestTimeoutSeconds", conf.backfillRequestTimeoutSeconds,
        DefaultBackfillRequestTimeout, MaxBackfillRequestTimeoutSeconds,
      ),
      previousCycleStart: getNowInNanosecondTime(),
    )
  )

proc new*(T: typedesc[RecvService], waku: Waku, backfill: BackfillState): T =
  ## The storeClient will help to acquire any possible missed messages.
  RecvService(
    waku: waku, brokerCtx: waku.brokerCtx, recentReceivedMsgs: @[], backfill: backfill
  )

proc maintenanceLoop(self: RecvService) {.async.} =
  while not self.stopping:
    let now = getNowInNanosecondTime()
    self.recentReceivedMsgs.keepItIf(it.rxTime > now - MaxMessageLife.nanos)
    if not self.backfill.job.isNil() and
        (self.backfill.cycle.isNil() or self.backfill.cycle.finished()):
      # Sample only when idle. A topic that appears during a cycle is new at
      # the next tick. A new topic makes a cycle due now.
      if self.sampleSubscriptions() or Moment.now() >= self.backfill.nextCycleAt:
        discard self.startCycle()
    await sleepAsync(MaintenancePeriod)

proc openBackfillJob(self: RecvService): Job =
  ## The Persistency job for the per-topic records, or nil with a warning.
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
  self.online = false
  self.backfill.job =
    if self.backfill.enabled:
      self.openBackfillJob()
    else:
      nil
  self.backfill.lastSample = @[]
  self.backfill.nextTopicIndex = 0
  self.backfill.nextCycleAt = Moment.now()

  self.seenMsgListener = MessageSeenEvent.listen(
    self.brokerCtx,
    proc(event: MessageSeenEvent) {.async: (raises: []).} =
      discard self.processIncomingMessage(event.topic, event.message),
  ).valueOr:
    error "Failed to set MessageSeenEvent listener", error = error
    return err("register receive listener: " & error)

  self.connStatusListener = EventConnectionStatusChange.listen(
    self.brokerCtx,
    proc(event: EventConnectionStatusChange) {.async: (raises: []).} =
      self.onConnectionStatusChange(event.connectionStatus),
  ).valueOr:
    error "Failed to set EventConnectionStatusChange listener", error = error
    discard MessageSeenEvent.dropListener(self.brokerCtx, self.seenMsgListener)
    return err("register receive listener: " & error)

  self.maintenanceHandler = self.maintenanceLoop()
  return ok()

proc stopRecvService*(self: RecvService) {.async.} =
  ## Cancels and joins the cycle in flight before the kernel closes Persistency.
  self.stopping = true
  await MessageSeenEvent.dropListener(self.brokerCtx, self.seenMsgListener)
  await EventConnectionStatusChange.dropListener(
    self.brokerCtx, self.connStatusListener
  )
  if not self.backfill.cycle.isNil():
    await self.backfill.cycle.cancelAndWait()
    self.backfill.cycle = nil
  if not self.maintenanceHandler.isNil():
    await self.maintenanceHandler.cancelAndWait()
    self.maintenanceHandler = nil
  if not self.backfill.job.isNil():
    # A topic subscribed after the last cycle has no record. Write one now, so
    # the next process resumes from it.
    for topic in self.subscribedTopics():
      (await self.backfill.job.seedTopic(topic, self.backfill.previousCycleStart)).isOkOr:
        warn "backfill record not written at stop",
          pubsubTopic = topic.pubsubTopic, contentTopic = topic.contentTopic, error
    self.backfill.job = nil

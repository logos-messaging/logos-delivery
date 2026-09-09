## This module is in charge of taking care of the messages that this node is expecting to
## receive and is backed by store-v3 requests to get an additional degree of certainty
##
## Relay and filter deliver live messages. One task per service start catches
## up from Store: it waits for a subscription and a known Store peer, queries
## every subscribed topic from the recovery hint that `backfill.nim` keeps in
## Persistency up to a cutoff fixed at its first attempt, retries until each
## topic is exhausted or unsubscribed, writes the cutoff, and exits. From then
## on an accepted live message advances the hint with its local receipt time,
## at most once per `ActivityWriteInterval`. No messages, no writes.

import
  std/[sequtils, sets, algorithm],
  results,
  chronos,
  chronicles,
  brokers/broker_context,
  libp2p/protocols/pubsub/timedcache
import
  ./backfill,
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/waku/persistency/persistency,
  logos_delivery/waku/[waku_core, waku_core/topics, waku_store/common],
  logos_delivery/waku/waku,
  logos_delivery/waku/api/[store, subscriptions],
  logos_delivery/api/events/kernel_events, # MessageSeenEvent
  logos_delivery/api/events/messaging_client_events # MessageReceivedEvent

const MaxMessageLife = chronos.minutes(7) ## Max time we will keep track of rx messages

const ActivityWriteInterval* = chronos.seconds(10)
  ## Least time between two writes of the recovery hint from live receipts.

const CatchUpRetryPeriod = chronos.seconds(30)
  ## Wait inside the startup task before it asks again, after a failed topic
  ## or while no Store peer is known.

const
  DefaultBackfillRequestTimeout = chronos.seconds(10)
  MinBackfillRequestTimeoutSeconds = 1
  MaxBackfillRequestTimeoutSeconds = 300

type BackfillState* = object
  ## Store catch-up settings and the startup task. The mechanism is in `backfill.nim`.
  enabled*: bool
  queryTimeout*: Duration
  job: Job ## nil when disabled or storage is unavailable this run
  task: Future[void] ## the startup catch-up, until it exits
  subscribed: AsyncEvent ## fired when a subscription is added
  done: bool ## the startup catch-up exited; live receipts may write the hint
  lastWrite: Moment ## throttle for live-receipt writes

type RecvService* = ref object of RootObj
  brokerCtx: BrokerContext
  waku: Waku
  seenMsgListener: MessageSeenEventListener

  recentReceivedMsgs: TimedCache[WakuMessageHash]
    ## every message received in the last `MaxMessageLife`, from its first
    ## local receipt

  backfill: BackfillState
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
  if self.recentReceivedMsgs.put(msgHash):
    trace "skipping duplicate message",
      shard = pubsubTopic,
      contentTopic = message.contentTopic,
      msg_hash = msgHash.to0xHex()
    return false

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

proc suspendBackfill(self: RecvService, reason: string) =
  ## The stored hint stays. The next start retries. At shutdown the broker
  ## reports a cancelled read as an error, which is not a failure.
  if self.stopping:
    return
  warn "automatic Store catch-up suspended for this run", reason
  self.backfill.job = nil

proc noteSubscribed*(self: RecvService) =
  ## Wakes the startup catch-up waiting for its first subscription. A no-op
  ## once it has exited.
  if not self.backfill.done and not self.backfill.subscribed.isNil():
    self.backfill.subscribed.fire()

proc noteLiveReceipt(self: RecvService, receivedAt: Timestamp) {.async: (raises: []).} =
  ## Advances the recovery hint to a live receipt once the startup catch-up
  ## has exited, at most once per `ActivityWriteInterval`.
  if not self.backfill.done or self.backfill.job.isNil() or not self.backfill.job.running:
    return
  if Moment.now() - self.backfill.lastWrite < ActivityWriteInterval:
    return
  self.backfill.lastWrite = Moment.now() # before the yield, so a burst writes once
  try:
    await self.backfill.job.writeLastOnline(receivedAt)
  except CancelledError:
    discard

proc onLiveMessage(self: RecvService, event: MessageSeenEvent) {.async: (raises: []).} =
  ## Relay and filter deliveries. The receipt time is taken before delivery.
  let receivedAt = getNowInNanosecondTime()
  if self.processIncomingMessage(event.topic, event.message):
    await self.noteLiveReceipt(receivedAt)

proc startupCatchUp(self: RecvService) {.async.} =
  ## The one catch-up of a service run. Reads or seeds the hint, waits for a
  ## subscription and a known Store peer, walks `[hint - BackfillOverlap,
  ## cutoff)` for every subscribed topic until each is exhausted or gone, then
  ## writes the cutoff and hands the hint over to live receipts.
  let job = self.backfill.job
  let startedAt = getNowInNanosecondTime() # before the first await: the service start
  let stored = (await job.readLastOnline()).valueOr:
    self.suspendBackfill(error)
    return
  let hint =
    if stored.isSome():
      stored.get()
    else:
      await job.writeLastOnline(startedAt) # a first run: the next run starts here
      startedAt
  let since = hint - BackfillOverlap.nanos
  var cutoff = Timestamp(0) # fixed at the first Store attempt
  var completed: HashSet[BackfillTopic]
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
  while true:
    if not job.running:
      self.suspendBackfill("persistency job is closed")
      return
    self.backfill.subscribed.clear()
    let subscribed = self.subscribedTopics()
    if subscribed.len == 0:
      if cutoff == 0:
        await self.backfill.subscribed.wait() # the app subscribes after start
        continue
      break # everything was unsubscribed
    let pending = subscribed.filterIt(it notin completed)
    if pending.len == 0:
      break
    if not self.waku.hasStorePeer():
      await sleepAsync(CatchUpRetryPeriod) # nobody to ask yet
      continue
    if cutoff == 0:
      cutoff = getNowInNanosecondTime()
    let outcome = await runCatchUp(
      pending, since, cutoff, self.backfill.queryTimeout, query, deliver
    )
    for topic in outcome.completedTopics:
      completed.incl(topic)
    debug "recv service catch-up pass",
      queries = outcome.queries,
      completed = outcome.completedTopics.len,
      failed = outcome.failed
    if outcome.completedTopics.len < pending.len:
      await sleepAsync(CatchUpRetryPeriod) # a topic failed; ask again
  if completed.len > 0:
    await job.writeLastOnline(cutoff) # the bound actually queried
  self.backfill.done = true

proc checkStore*(self: RecvService) {.async.} =
  ## Waits for the startup catch-up of this run, if it is still in flight. It
  ## never starts one; the next service start does.
  if not self.backfill.task.isNil():
    await self.backfill.task

proc init*(T: type BackfillState, conf: MessagingClientConf): Result[T, string] =
  ## Rejects an out-of-range timeout. Zero is not unlimited. Disable with
  ## `backfillEnabled`.
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
  ok(T(enabled: conf.backfillEnabled.get(true), queryTimeout: queryTimeout))

proc new*(T: typedesc[RecvService], waku: Waku, backfill: BackfillState): T =
  ## The storeClient will help to acquire any possible missed messages.
  RecvService(
    waku: waku,
    brokerCtx: waku.brokerCtx,
    backfill: backfill,
    recentReceivedMsgs:
      init(TimedCache[WakuMessageHash], MaxMessageLife, refreshOnPut = false),
  )

proc openBackfillJob(self: RecvService): Job =
  ## The Persistency job for the recovery hint, or nil with a warning. Live
  ## messaging continues. The next start retries.
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
  self.backfill.done = false
  self.backfill.lastWrite = Moment()
  self.backfill.subscribed = newAsyncEvent()

  let onSeen = proc(event: MessageSeenEvent) {.async: (raises: []).} =
    await self.onLiveMessage(event)
  self.seenMsgListener = MessageSeenEvent.listen(self.brokerCtx, onSeen).valueOr:
    error "Failed to set MessageSeenEvent listener", error = error
    return err("register receive listener: " & error)

  if not self.backfill.job.isNil():
    self.backfill.task = self.startupCatchUp()
  return ok()

proc stopRecvService*(self: RecvService) {.async.} =
  ## Cancels and joins the startup catch-up before the kernel closes
  ## Persistency. The hint stays where the last write put it; the kernel
  ## closes Persistency right after this, so a write here would race the
  ## worker thread's shutdown.
  self.stopping = true
  await MessageSeenEvent.dropListener(self.brokerCtx, self.seenMsgListener)
  if not self.backfill.task.isNil():
    await self.backfill.task.cancelAndWait()
    self.backfill.task = nil
  self.backfill.job = nil

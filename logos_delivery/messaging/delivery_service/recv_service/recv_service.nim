## The receive service gives the app the messages of its subscribed content
## topics. They come live from the network, or from Store for the time when
## live delivery did not deliver them.
##
## Each subscribed (shard, content topic) has one backfill record (see
## `backfill.nim`). An outage of live delivery (relay not READY on Core, or a
## shard without a healthy filter subscription on Edge) turns each record
## into a gap. One worker fills the gaps from Store when live delivery is
## back. With `backfill-enabled`, the records survive a restart, and a
## restart is an outage too. An unsubscribe deletes the record.

import results, std/[algorithm, tables]
import chronos, chronicles
import brokers/broker_context
import
  ./backfill,
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/api/events/kernel_events,
  logos_delivery/api/events/messaging_client_events, # MessageReceivedEvent
  logos_delivery/messaging/messaging_metrics,
  logos_delivery/waku/persistency/persistency,
  logos_delivery/waku/[waku_core, waku_core/topics, waku_store/common],
  logos_delivery/waku/waku,
  logos_delivery/waku/api/[store, subscriptions, health],
  logos_delivery/waku/api/events/[health_events, peer_events],
  logos_delivery/waku/requests/health_requests,
  logos_delivery/waku/node/health_monitor/health_status
from logos_delivery/waku/waku_archive/archive import MaxMessageTimestampVariance

const MaxMessageLife = chronos.minutes(20)
  ## The service keeps the hash of each received message this long.

static:
  doAssert OutageWindow + MaxMessageTimestampVariance <= MaxMessageLife.nanos div 2
  # After an outage, the worker fetches again what the node received live in
  # the `OutageWindow` (plus the variance) before the outage. The cache must
  # still hold those hashes when the outage ends. With the overlap at most half
  # the cache life, the other half is the longest outage with no duplicates.

const PruneOldMsgsPeriod = chronos.minutes(1)

const ActivityWriteInterval = chronos.seconds(10)
  ## Least time between two writes of the last received time.

const BackfillRetryPeriod = chronos.seconds(30)
  ## Longest wait of the worker before its next pass over the topics. A
  ## subscription, a peer change or a recovered live delivery ends the wait.

const
  DefaultBackfillEnabled = true
  DefaultBackfillRequestTimeout = chronos.seconds(10)
  MinBackfillRequestTimeoutSeconds = 1
  MaxBackfillRequestTimeoutSeconds = 300

type BackfillSubscriptionChange = object
  ## A subscribe or an unsubscribe of one topic, with its time.
  topic: BackfillTopic
  subscribed: bool
  at: Timestamp

type BackfillFetchOutcome = object ## The result of one Store query for one topic.
  more: bool ## the topic has more to fetch now
  readyAt: Opt[Timestamp] ## the time when the archive has the rest of the gap

type BackfillState* = object
  ## The settings and the state of the backfill. `backfill.nim` has the
  ## records, the transitions and the Store queries.
  enabled*: bool ## the records survive a restart
  queryTimeout*: Duration
  job: persistency.Job ## nil when the records stay in memory only
  records: Table[BackfillTopic, TopicRecord]
  subscribedSince: Table[BackfillTopic, Timestamp]
    ## the time of the subscribe of each subscribed topic, in this run
  live: bool ## live delivery is ready (see `hasLiveDelivery`)
  liveSince: Timestamp ## the time of the last change of `live`
  started: bool ## the records are read, and a change applies at once
  pendingSubscriptionChanges: seq[BackfillSubscriptionChange]
    ## the changes before `started`
  task: Future[void] ## the backfill worker
  wake: AsyncEvent ## a change that can give the worker work
  caughtUp: AsyncEvent ## set when the worker has no gap to fill, also in an outage
  lastReceivedAtWrite: Moment ## when the service last wrote the last received time

type RecvService* = ref object of RootObj
  brokerCtx: BrokerContext
  waku: Waku
  seenMsgListener: MessageSeenEventListener
  protocolHealthListener: EventProtocolHealthChangeListener
  shardHealthListener: EventShardTopicHealthChangeListener
  subscribedEventListener: ContentTopicSubscribedEventListener
  unsubscribedEventListener: ContentTopicUnsubscribedEventListener
  peerEventListener: WakuPeerEventListener

  recentReceivedMsgs: Table[WakuMessageHash, Timestamp]
    ## hash of each message received in the last `MaxMessageLife`, with its
    ## local receipt time

  msgPrunerHandler: Future[void] ## removes too old messages

  backfill: BackfillState
  stopping: bool
    ## Lets the worker stop at shutdown. A broker request catches
    ## `CancelledError` and does not raise it again, so a cancel may not reach
    ## the worker. Remove this flag when broker requests raise it again.

  activityWriteInterval*: Duration = ActivityWriteInterval
    ## see `ActivityWriteInterval`, shorter in tests
  delayExtra*: Duration = chronos.nanoseconds(DelayExtra)
    ## see `DelayExtra`, shorter in tests
  archiveTime*: Duration = chronos.nanoseconds(ArchiveTime)
    ## see `ArchiveTime`, shorter in tests
  timestampVariance*: Duration = chronos.nanoseconds(MaxMessageTimestampVariance)
    ## see `MaxMessageTimestampVariance`, shorter in tests

proc processIncomingMessage(
    self: RecvService, pubsubTopic: string, message: WakuMessage, source: MessageSource
): bool =
  ## Return false if the incoming message is from a non-subscribed topic,
  ## or if the message is a duplicate (recently-seen). Otherwise, save it as
  ## recently-seen, emit a MessageReceivedEvent tagged with `source`, and
  ## return true.

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
  recordReceived(source, message.payload.len)
  info "Message received",
    msg_hash = msgHash.to0xHex(),
    contentTopic = message.contentTopic,
    pubsubTopic = pubsubTopic,
    source = source
  MessageReceivedEvent.emit(self.brokerCtx, msgHash.to0xHex(), message, source)
  return true

proc hasHealthyFilterSubscription(self: RecvService): bool =
  ## Every subscribed shard has a healthy filter subscription (false with none).
  var shards = 0
  for (shard, _) in self.waku.subscribedContentTopics():
    inc shards
    let shardHealth = RequestEdgeShardHealth.request(self.brokerCtx, shard).valueOr:
      debug "Failed to read the filter subscription health of a shard",
        shard = shard, error = error
      return false
    if shardHealth.health notin
        {TopicHealth.MINIMALLY_HEALTHY, TopicHealth.SUFFICIENTLY_HEALTHY}:
      return false
  return shards > 0

proc hasLiveDelivery(self: RecvService): bool =
  ## Relay READY, or a healthy filter subscription on every subscribed shard.
  return
    self.waku.reportedProtocolHealth(WakuProtocol.RelayProtocol).health ==
    HealthStatus.READY or self.hasHealthyFilterSubscription()

proc backfillWriteRecords(self: RecvService, ops: seq[TxOp]) {.async: (raises: []).} =
  ## Writes the changes of one event as one transaction, when the records
  ## are on disk.
  if self.backfill.job.isNil() or ops.len == 0:
    return
  try:
    await self.backfill.job.writeTopicRecords(ops)
  except CancelledError:
    discard

proc backfillApplySubscriptionChange(
    self: RecvService, change: BackfillSubscriptionChange
): seq[TxOp] =
  ## Applies one subscribe or unsubscribe to the records, and returns its
  ## writes. A subscribe of a topic with no record makes a new record. A
  ## subscribe of a topic with a record changes nothing, because the worker
  ## fills its gap. An unsubscribe deletes the record.
  if change.subscribed:
    self.backfill.subscribedSince[change.topic] = change.at
    if change.topic in self.backfill.records:
      return @[]
    let record = newRecord(
      change.at, self.backfill.live, self.backfill.liveSince,
      self.timestampVariance.nanos,
    )
    self.backfill.records[change.topic] = record
    return topicRecordOp(change.topic, record)
  self.backfill.subscribedSince.del(change.topic)
  if change.topic notin self.backfill.records:
    return @[]
  self.backfill.records.del(change.topic)
  return deleteTopicRecordOp(change.topic)

proc backfillSubscriptionChanged(
    self: RecvService, change: BackfillSubscriptionChange
) {.async: (raises: []).} =
  ## Applies the change to the records, or keeps it until the records are
  ## read from the disk at start.
  if not self.backfill.started:
    self.backfill.pendingSubscriptionChanges.add(change)
    return
  await self.backfillWriteRecords(self.backfillApplySubscriptionChange(change))
  self.backfill.wake.fire()

proc backfillLiveChanged(self: RecvService, nowLive: bool) {.async: (raises: []).} =
  ## An outage turns each record into a gap, from `OutageWindow` before now.
  ## A recovery sets the time from which live delivery covers the topics
  ## again, and wakes the worker.
  if nowLive == self.backfill.live:
    return
  self.backfill.live = nowLive
  self.backfill.liveSince = getNowInNanosecondTime()
  if nowLive:
    info "Live delivery is ready"
    self.backfill.wake.fire()
    return
  info "Live delivery is down"
  var ops: seq[TxOp]
  for topic, record in self.backfill.records.mpairs():
    let after = record.inOutage(self.backfill.liveSince)
    if after == record:
      continue
    record = after
    ops.add(topicRecordOp(topic, record))
  await self.backfillWriteRecords(ops)

proc backfillOnReceipt(self: RecvService) {.async: (raises: []).} =
  ## A message from the network moves the last received time to now, at most
  ## one time per `activityWriteInterval`, while the records are on disk.
  if self.backfill.job.isNil() or not self.backfill.started:
    return # the records of the last run must be rewritten first
  let now = Moment.now()
  if now - self.backfill.lastReceivedAtWrite < self.activityWriteInterval:
    return
  self.backfill.lastReceivedAtWrite = now # before the await, so a burst writes one time
  try:
    await self.backfill.job.writeLastReceivedAt(getNowInNanosecondTime())
  except CancelledError:
    discard

proc backfillReadRecordsAtStart(
    self: RecvService
) {.async: (raises: [CancelledError]).} =
  ## Reads the records and the last received time from the disk, and applies
  ## the restart outage to each live record. Nothing when the records stay in
  ## memory only.
  let job = self.backfill.job
  if job.isNil():
    return
  let lastReceivedAt = (await job.readLastReceivedAt()).valueOr:
    if not self.stopping:
      warn "Failed to read the last received time of the backfill", error
    Opt.none(Timestamp) # the same as none stored
  let stored = (await job.readTopicRecords()).valueOr:
    if not self.stopping:
      warn "Failed to read the backfill topic records, the topics are new", error
    return
  var ops: seq[TxOp]
  for (topic, record) in stored:
    let restarted = record.atStart(lastReceivedAt)
    self.backfill.records[topic] = restarted
    if restarted != record:
      ops.add(topicRecordOp(topic, restarted))
  await job.writeTopicRecords(ops) # `backfillOnReceipt` waits for `started`

func backfillIsCandidate(self: RecvService, topic: BackfillTopic): bool =
  ## True when the worker has a gap to fill for `topic`.
  self.backfill.live and topic in self.backfill.subscribedSince and
    self.backfill.records.getOrDefault(topic).timestampToNowIsGap

func backfillCandidates(self: RecvService): seq[BackfillTopic] =
  ## The topics with a gap to fill, in a fixed order.
  var topics: seq[BackfillTopic]
  for topic in self.backfill.records.keys:
    if self.backfillIsCandidate(topic):
      topics.add(topic)
  topics.sort()
  return topics

proc backfillFetchTopic(
    self: RecvService,
    topic: BackfillTopic,
    query: BackfillQuery,
    deliver: BackfillDeliver,
): Future[Result[BackfillFetchOutcome, string]] {.async.} =
  ## One Store query for `topic`. The gap ends where live delivery covers the
  ## topic again. The worker fetches at once the part of the gap that the
  ## archive has for sure. The last part waits until the archive has it.
  let record = self.backfill.records.getOrDefault(topic)
  let now = getNowInNanosecondTime()
  let stop = coveredFrom(
    self.backfill.liveSince,
    self.backfill.subscribedSince[topic],
    self.delayExtra.nanos,
    self.timestampVariance.nanos,
  )
  let archived =
    archivedBefore(now, self.archiveTime.nanos, self.timestampVariance.nanos)
  # The time when the archive has every message before `stop`.
  let restArchivedAt = stop + self.timestampVariance.nanos + self.archiveTime.nanos
  if stop > archived and record.timestamp >= archived:
    # Only the last part is left, and the archive may not have it yet.
    return ok(BackfillFetchOutcome(readyAt: Opt.some(restArchivedAt)))
  let fetchStop = min(stop, archived)
  let next = ?await fetchPage(
    topic, record.timestamp, fetchStop, self.backfill.queryTimeout, query, deliver
  )
  if self.stopping or self.backfill.records.getOrDefault(topic) != record:
    return
      ok(BackfillFetchOutcome()) # an unsubscribe or a new subscribe changed the topic
  # Live delivery can have gone down and come back during the query. Then the
  # end of the gap moved, and the topic keeps its gap from the next page start.
  let stopNow = coveredFrom(
    self.backfill.liveSince,
    self.backfill.subscribedSince.getOrDefault(topic, now),
    self.delayExtra.nanos,
    self.timestampVariance.nanos,
  )
  let after =
    if self.backfill.live and fetchStop == stop and next >= stopNow:
      TopicRecord.live(stopNow)
    else:
      TopicRecord.gap(next)
  self.backfill.records[topic] = after
  await self.backfillWriteRecords(topicRecordOp(topic, after))
  # The old part is done, and the last part waits for the archive.
  let readyAt =
    if after.timestampToNowIsGap and next >= fetchStop and fetchStop < stop:
      Opt.some(restArchivedAt)
    else:
      Opt.none(Timestamp)
  return ok(
    BackfillFetchOutcome(
      more: after.timestampToNowIsGap and next < fetchStop, readyAt: readyAt
    )
  )

proc backfillFetchAllTopics(
    self: RecvService,
    candidates: seq[BackfillTopic],
    first: int,
    query: BackfillQuery,
    deliver: BackfillDeliver,
): Future[Duration] {.async.} =
  ## One Store query for each candidate, from `first` on. Returns the wait
  ## before the next pass. It is zero when a topic has more to fetch now, the
  ## time until the archive has the rest of a gap, or `BackfillRetryPeriod`.
  var more = false
  var waitUntil = Opt.none(Timestamp)
  for i in 0 ..< candidates.len:
    let topic = candidates[(first + i) mod candidates.len]
    if self.stopping:
      return ZeroDuration
    if not self.backfillIsCandidate(topic):
      continue # changed during this pass
    let res = await self.backfillFetchTopic(topic, query, deliver)
    if res.isErr():
      debug "Backfill query failed, the topic waits for the next pass",
        pubsubTopic = topic.pubsubTopic,
        contentTopic = topic.contentTopic,
        error = res.error
      continue
    let outcome = res.get()
    more = more or outcome.more
    if outcome.readyAt.isSome() and
        (waitUntil.isNone() or outcome.readyAt.get() < waitUntil.get()):
      waitUntil = outcome.readyAt
  if more:
    return ZeroDuration
  if waitUntil.isNone():
    return BackfillRetryPeriod
  let left = waitUntil.get() - getNowInNanosecondTime()
  return min(BackfillRetryPeriod, chronos.nanoseconds(max(left, 1'i64)))

proc backfillWorker(self: RecvService) {.async.} =
  ## Reads the records at start, applies the changes that came before, and
  ## then fills the gaps of the subscribed topics from Store, one query for
  ## one topic at a time, while live delivery is ready and a Store peer is
  ## known. A failed query makes its topic wait for the next pass.
  await self.backfillReadRecordsAtStart()
  self.backfill.started = true
  var ops: seq[TxOp]
  for change in self.backfill.pendingSubscriptionChanges:
    ops.add(self.backfillApplySubscriptionChange(change))
  self.backfill.pendingSubscriptionChanges.setLen(0)
  await self.backfillWriteRecords(ops)
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
    discard self.processIncomingMessage(pubsubTopic, message, MessageSource.History)
    return true
  var first = 0
  while not self.stopping:
    let candidates = self.backfillCandidates()
    if candidates.len == 0:
      self.backfill.caughtUp.fire()
      await self.backfill.wake.wait()
      self.backfill.wake.clear()
      continue
    self.backfill.caughtUp.clear()
    if not self.waku.hasStorePeer():
      discard await self.backfill.wake.wait().withTimeout(BackfillRetryPeriod)
        # nobody to ask yet
      self.backfill.wake.clear()
      continue
    let wait = await self.backfillFetchAllTopics(candidates, first, query, deliver)
    inc first
    if wait == ZeroDuration or self.backfillCandidates().len == 0:
      continue # more to fetch now, or idle. The top of the loop handles both.
    discard await self.backfill.wake.wait().withTimeout(wait)
    self.backfill.wake.clear()

proc backfillWaitForIdle*(self: RecvService): Future[bool] {.async.} =
  ## True when the worker is idle, because no subscribed topic has a gap, or
  ## live delivery is down. False when the worker ended first.
  let task = self.backfill.task
  if task.isNil():
    return true
  if task.finished():
    return false
  let caughtUp = self.backfill.caughtUp.wait()
  let ended = task.join()
  try:
    discard await race(caughtUp, ended)
  finally:
    caughtUp.cancelSoon()
    ended.cancelSoon()
  return caughtUp.completed()

proc updateLive(self: RecvService) {.async: (raises: []).} =
  ## Reads the state of live delivery and gives it to the backfill.
  await self.backfillLiveChanged(self.hasLiveDelivery())

proc onSubscribed(
    self: RecvService, shard: PubsubTopic, contentTopic: ContentTopic
) {.async: (raises: []).} =
  ## The subscribed shards are an input of live delivery. On Edge, a topic on
  ## a new shard has no filter subscription yet, so the node is in an outage
  ## until the shard is healthy, and the record of the topic is a gap.
  await self.updateLive()
  await self.backfillSubscriptionChanged(
    BackfillSubscriptionChange(
      topic: (shard, contentTopic), subscribed: true, at: getNowInNanosecondTime()
    )
  )

proc onUnsubscribed(
    self: RecvService, shard: PubsubTopic, contentTopic: ContentTopic
) {.async: (raises: []).} =
  await self.updateLive()
  await self.backfillSubscriptionChanged(
    BackfillSubscriptionChange(
      topic: (shard, contentTopic), subscribed: false, at: getNowInNanosecondTime()
    )
  )

proc listenForReadiness(self: RecvService, E: typedesc): auto =
  ## Re-evaluates live delivery on each `E` event. An event that changes
  ## nothing is harmless, as `updateLive` acts only on a change.
  proc onEvent(event: E) {.async: (raises: []).} =
    await self.updateLive()
    self.backfill.wake.fire() # a peer change can make a Store peer available

  let listener = E.listen(self.brokerCtx, onEvent).valueOr:
    error "Failed to set a receive readiness listener", event = $E, error = error
    quit(QuitFailure)
  return listener

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
  return ok(
    T(
      enabled: conf.backfillEnabled.get(DefaultBackfillEnabled),
      queryTimeout: queryTimeout,
    )
  )

proc new*(T: typedesc[RecvService], waku: Waku, backfill: BackfillState): T =
  return RecvService(waku: waku, brokerCtx: waku.brokerCtx, backfill: backfill)

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

proc startRecvService*(self: RecvService, job: persistency.Job) =
  ## `job` is the messaging layer's Persistency job, nil when the layer has none.
  self.stopping = false
  self.msgPrunerHandler = self.loopPruneOldMessages()

  proc onSeen(event: MessageSeenEvent) {.async: (raises: []).} =
    if self.processIncomingMessage(event.topic, event.message, MessageSource.Live):
      await self.backfillOnReceipt()

  self.seenMsgListener = MessageSeenEvent.listen(self.brokerCtx, onSeen).valueOr:
    error "Failed to set MessageSeenEvent listener", error = error
    quit(QuitFailure)

  self.backfill.records = initTable[BackfillTopic, TopicRecord]()
  self.backfill.subscribedSince = initTable[BackfillTopic, Timestamp]()
  self.backfill.started = false
  self.backfill.pendingSubscriptionChanges = @[]
  self.backfill.wake = newAsyncEvent()
  self.backfill.caughtUp = newAsyncEvent()
  self.backfill.lastReceivedAtWrite = Moment()
  let startedAt = getNowInNanosecondTime()
  self.backfill.live = self.hasLiveDelivery()
  self.backfill.liveSince = startedAt
  if self.backfill.enabled:
    self.backfill.job = job
  else:
    self.backfill.job = nil
    if not job.isNil():
      asyncSpawn job.clearBackfillState() # off resets the state on disk

  # The topics that are subscribed before the service starts.
  for topic in backfillTopics(self.waku.subscribedContentTopics()):
    self.backfill.pendingSubscriptionChanges.add(
      BackfillSubscriptionChange(topic: topic, subscribed: true, at: startedAt)
    )

  # All of these can change live delivery. Subscriptions and peers have no
  # health event.
  self.protocolHealthListener = self.listenForReadiness(EventProtocolHealthChange)
  self.shardHealthListener = self.listenForReadiness(EventShardTopicHealthChange)
  self.peerEventListener = self.listenForReadiness(WakuPeerEvent)
  proc onSubscribedEvent(event: ContentTopicSubscribedEvent) {.async: (raises: []).} =
    await self.onSubscribed(event.shard, event.contentTopic)

  self.subscribedEventListener = ContentTopicSubscribedEvent.listen(
    self.brokerCtx, onSubscribedEvent
  ).valueOr:
    error "Failed to set ContentTopicSubscribedEvent listener", error = error
    quit(QuitFailure)

  proc onUnsubscribedEvent(
      event: ContentTopicUnsubscribedEvent
  ) {.async: (raises: []).} =
    await self.onUnsubscribed(event.shard, event.contentTopic)

  self.unsubscribedEventListener = ContentTopicUnsubscribedEvent.listen(
    self.brokerCtx, onUnsubscribedEvent
  ).valueOr:
    error "Failed to set ContentTopicUnsubscribedEvent listener", error = error
    quit(QuitFailure)

  self.backfill.task = self.backfillWorker()

proc stopRecvService*(self: RecvService) {.async.} =
  self.stopping = true
  await MessageSeenEvent.dropListener(self.brokerCtx, self.seenMsgListener)
  await EventProtocolHealthChange.dropListener(
    self.brokerCtx, self.protocolHealthListener
  )
  await EventShardTopicHealthChange.dropListener(
    self.brokerCtx, self.shardHealthListener
  )
  await ContentTopicSubscribedEvent.dropListener(
    self.brokerCtx, self.subscribedEventListener
  )
  await ContentTopicUnsubscribedEvent.dropListener(
    self.brokerCtx, self.unsubscribedEventListener
  )
  await WakuPeerEvent.dropListener(self.brokerCtx, self.peerEventListener)
  var tasks: seq[Future[void]]
  for task in [self.msgPrunerHandler, self.backfill.task]:
    if not task.isNil():
      tasks.add(task)
  await cancelAndWait(tasks) # every cancel requested before any wait
  self.msgPrunerHandler = nil
  self.backfill.task = nil
  self.backfill.job = nil

## This module is in charge of taking care of the messages that this node is expecting to
## receive and is backed by store-v3 requests to get an additional degree of certainty
##
## Reconnection backfill: offline while relay is not READY (Core), any
## subscribed shard lacks a healthy filter subscription (Edge), or no Store
## peer is known. Queries Store when back online.
##

import results, std/[tables, sequtils, sets]
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

const MaxMessageLife = chronos.minutes(7) ## Max time we will keep track of rx messages

const PruneOldMsgsPeriod = chronos.minutes(1)

const DelayExtra* = chronos.seconds(5)
  ## Additional security time to overlap the missing messages queries

const ActivityWriteInterval* = chronos.seconds(10)
  ## Least time between two recovery hint writes from received messages.

const CatchUpRetryPeriod* = chronos.seconds(30)
  ## Longest wait between two Store attempts of the startup catch-up. A new
  ## subscription or a peer change ends the wait early.

const FirstRunHistory* = chronos.hours(24)
  ## The catch-up of a node with no recovery hint goes back this far.

const CatchUpSettlePeriod* = chronos.seconds(10)
  ## The wait for one more subscription after the startup catch-up is complete.

const
  DefaultBackfillEnabled = true
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
    ## advances the hint on each received message, installed after the hint is read

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

  online: bool ## receive path ready (see hasReadyReceivePath) and a Store peer known
  backfillHandler: Future[void] ## in-flight store backfill task
  msgPrunerHandler: Future[void] ## removes too old messages

  startTimeToCheck: Timestamp
  endTimeToCheck: Timestamp

  backfill: BackfillState ## the startup catch-up from the persisted hint
  stopping: bool
    ## Lets the startup catch-up exit at stop. `storeQueryToAny`, `sendStoreRequest`,
    ## `dialPeer` and the brokers request path swallow `CancelledError`, so a cancel
    ## can fail to get to the task. Re-raise it at those sites, then delete this.

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

proc checkStore*(self: RecvService) {.async.} =
  ## Checks the store for messages that were not received directly and
  ## delivers them via MessageReceivedEvent, as `MessageSource.History`.
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
          if self.processIncomingMessage(
            msgTuple.pubsubTopic, msgTuple.msg, MessageSource.History
          ):
            debug "recv service store-recovered message",
              msg_hash = shortLog(msgTuple.hash), pubsubTopic = msgTuple.pubsubTopic
      else:
        debug "Failed to retrieve missing messages: ", error = $missingMsgsRet.error

  ## update next check times
  self.startTimeToCheck = self.endTimeToCheck

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

proc hasReadyReceivePath(self: RecvService): bool =
  ## Relay READY, or a healthy filter subscription on every subscribed shard.
  return
    self.waku.reportedProtocolHealth(WakuProtocol.RelayProtocol).health ==
    HealthStatus.READY or self.hasHealthyFilterSubscription()

proc updateReceiveReadiness(self: RecvService) =
  ## Records the time the node goes offline. When the node is back online,
  ## queries Store for the messages missed while offline. Does not retry a
  ## failed Store query, so online needs a Store peer.
  let nowOnline = self.hasReadyReceivePath() and self.waku.hasStorePeer()
  if nowOnline == self.online:
    return
  self.online = nowOnline

  if not nowOnline:
    self.startTimeToCheck = getNowInNanosecondTime()
    return

  # At most one backfill in flight; skip if the previous is still running.
  if self.backfillHandler.isNil() or self.backfillHandler.finished():
    info "recv service backfilling missed messages after coming back online"
    self.backfillHandler = self.checkStore()

proc listenForReadiness(self: RecvService, E: typedesc): auto =
  ## Re-evaluates `online` on each `E` event. An event that changes nothing
  ## is harmless, as `updateReceiveReadiness` acts only on a change.
  let listener = E.listen(
    self.brokerCtx,
    proc(event: E) {.async: (raises: []).} =
      self.updateReceiveReadiness(),
  ).valueOr:
    error "Failed to set a receive readiness listener", event = $E, error = error
    quit(QuitFailure)
  return listener

proc listenForReceipts(
    brokerCtx: BrokerContext, job: persistency.Job
): Result[MessageReceivedEventListener, string] =
  ## Every accepted message, live or from Store, moves the hint to now, at
  ## most one time per `ActivityWriteInterval`.
  var lastWrite = Moment()
  let onReceived = proc(event: MessageReceivedEvent) {.async: (raises: []).} =
    let now = Moment.now()
    if not job.running or now - lastWrite < ActivityWriteInterval:
      return
    lastWrite = now # before the await, so a burst writes one time
    try:
      await job.writeRecoveryHint(getNowInNanosecondTime())
    except CancelledError:
      discard
  return MessageReceivedEvent.listen(brokerCtx, onReceived)

proc startupCatchUp(self: RecvService, job: persistency.Job) {.async.} =
  ## Run once at startup to fetch missed messages from Store.
  ## Received messages update the saved time on disk. This catch-up keeps
  ## using the value it read at startup. If the time is missing or cannot
  ## be read, query from 24 hours before startup.
  let startedAt = getNowInNanosecondTime() # before the first await
  let stored = (await job.readRecoveryHint()).valueOr:
    if self.stopping:
      return
    warn "Failed to read the Store catch-up recovery hint", reason = error
    Opt.none(Timestamp) # the same as no hint
  let since =
    if stored.isSome():
      stored.get() - BackfillOverlap
    else:
      await job.writeRecoveryHint(startedAt)
        # a first run stores its start for the next run
      startedAt - FirstRunHistory.nanos
  let receipts = listenForReceipts(self.brokerCtx, job).valueOr:
    warn "Store catch-up aborted", reason = error
    return
  self.backfill.hintListener = Opt.some(receipts)
  var completed: HashSet[BackfillTopic]
  let progress = newTable[BackfillTopic, Timestamp]() # a failed topic's next page start
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
    discard self.processIncomingMessage(pubsubTopic, message, MessageSource.History)
    return true
  let wake = newAsyncEvent() # a new subscription or a peer change
  let onSubscribed = proc(event: ContentTopicSubscribedEvent) {.async: (raises: []).} =
    wake.fire()
  let onPeerEvent = proc(event: WakuPeerEvent) {.async: (raises: []).} =
    wake.fire() # any peer change can make a Store peer available
  let subscriptions = ContentTopicSubscribedEvent.listen(self.brokerCtx, onSubscribed).valueOr:
    warn "Store catch-up aborted", reason = error
    return
  defer:
    await ContentTopicSubscribedEvent.dropListener(self.brokerCtx, subscriptions)
  let peers = WakuPeerEvent.listen(self.brokerCtx, onPeerEvent).valueOr:
    warn "Store catch-up aborted", reason = error
    return
  defer:
    await WakuPeerEvent.dropListener(self.brokerCtx, peers)
  while true:
    if not job.running:
      warn "Store catch-up aborted", reason = "persistency job is closed"
      return
    let pending =
      backfillTopics(self.waku.subscribedContentTopics()).filterIt(it notin completed)
    if pending.len == 0:
      if completed.len > 0:
        # Caught up. The app can subscribe more topics after this. Wait for the
        # next subscription, and stop when none comes. A wake that brings no
        # work does not extend the wait.
        if settleUntil.isNone():
          settleUntil = Opt.some(Moment.now() + CatchUpSettlePeriod)
        let remaining = settleUntil.get() - Moment.now()
        if remaining <= ZeroDuration or not await wake.wait().withTimeout(remaining):
          break
      else:
        await wake.wait() # nothing subscribed yet
      wake.clear()
      continue
    settleUntil = Opt.none(Moment) # new work, the settle wait starts after it
    if not self.waku.hasStorePeer():
      discard await wake.wait().withTimeout(CatchUpRetryPeriod) # nobody to ask yet
      wake.clear()
      continue
    let cutoff = getNowInNanosecondTime()
      # the end of this pass, from here the messages come live
    let exhausted = await runCatchUpPass(
      pending, progress, since, cutoff, self.backfill.queryTimeout, query, deliver
    )
    if self.stopping:
      return
    for topic in exhausted:
      completed.incl(topic)
    if exhausted.len < pending.len:
      discard
        await wake.wait().withTimeout(CatchUpRetryPeriod) # a topic failed, ask again
      wake.clear()

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
  return ok(
    T(
      enabled: conf.backfillEnabled.get(DefaultBackfillEnabled),
      queryTimeout: queryTimeout,
    )
  )

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

proc startRecvService*(self: RecvService, job: persistency.Job) =
  ## `job` is the messaging layer's Persistency job, nil when the layer has none.
  self.stopping = false
  self.msgPrunerHandler = self.loopPruneOldMessages()

  self.seenMsgListener = MessageSeenEvent.listen(
    self.brokerCtx,
    proc(event: MessageSeenEvent) {.async: (raises: []).} =
      discard
        self.processIncomingMessage(event.topic, event.message, MessageSource.Live),
  ).valueOr:
    error "Failed to set MessageSeenEvent listener", error = error
    quit(QuitFailure)

  # All of these can change `online`. Subscriptions and peers have no health event.
  self.protocolHealthListener = self.listenForReadiness(EventProtocolHealthChange)
  self.shardHealthListener = self.listenForReadiness(EventShardTopicHealthChange)
  self.subscribedEventListener = self.listenForReadiness(ContentTopicSubscribedEvent)
  self.unsubscribedEventListener =
    self.listenForReadiness(ContentTopicUnsubscribedEvent)
  self.peerEventListener = self.listenForReadiness(WakuPeerEvent)

  # The initial read starts no backfill.
  self.online = self.hasReadyReceivePath()

  if self.backfill.enabled and not job.isNil():
    self.backfill.task = self.startupCatchUp(job)

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

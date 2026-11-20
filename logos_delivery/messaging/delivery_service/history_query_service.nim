## Runs the app's history queries, with Store nodes as the source of the history.
## A query gets the messages of one content topic in a time range, page by page.
## The service tries a page again when its Store request fails.
## It emits a `HistoryQueryMessageEvent` for each message.
## Then it emits a `HistoryQueryCompletedEvent` or a `HistoryQueryErrorEvent`.
##
## The first pass can miss a message of the last part of the range.
## An archive can get such a message up to `ArchiveTime` after it is sent.
## Also, a sender's clock can be up to `MaxMessageTimestampVariance` behind.
## The second pass gets the last part again, when the archive has all of it.
{.push raises: [].}

import std/[sequtils, tables], chronos, chronicles, results, brokers/broker_context
import
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/messaging/messaging_metrics,
  logos_delivery/messaging/delivery_service/recv_service/backfill,
  logos_delivery/waku/waku_core
from logos_delivery/waku/waku_archive/archive import MaxMessageTimestampVariance

logScope:
  topics = "history query"

const
  MaxHistoryQueryDays = 30
  MaxHistoryQueryRange* = chronos.days(MaxHistoryQueryDays).nanos
    ## A range costs at least one Store request for each `MaxQueryTimeRange` (24 hours).
  MaxActiveHistoryQueries* = 100
  MaxPagesInFlight* = 4
    ## The number of page requests in flight at the same time, for all the queries.
    ## This limits the Store load and the memory of the pages.
  DefaultPageAttempts = 5 ## each try can go to a different Store node
  DefaultPageRetryDelay = chronos.seconds(3)

type
  ActiveQuery = ref object
    requestId: RequestId
    contentTopic: ContentTopic
    shards: seq[PubsubTopic]
    startTime: Timestamp
    endTime: Timestamp ## the range ends before this timestamp
    lastPartStart: Timestamp ## the start of the part that the second pass gets again
    readyAt: Moment ## when the archive has every message before `endTime`
    found: Table[WakuMessageHash, Timestamp]
      ## The messages that a later page or the second pass can give again, by hash.
      ## Such a message gets no second event.
    messageCount: int

  HistoryQueryService* = ref object
    brokerCtx: BrokerContext
    queryToAny: BackfillQuery
      ## sends one Store request to a Store node that the Store client selects
    clock: proc(): Timestamp {.gcsafe, raises: [].} ## the source of the present time
    running: bool
    tasks: Table[string, Future[void]] ## the active queries, by request id
    pageSlots: AsyncSemaphore ## one slot for each page request in flight
    pageAttempts*: int = DefaultPageAttempts
    retryDelay*: Duration = DefaultPageRetryDelay
    queryTimeout: Duration
    archiveTime*: Duration = chronos.nanoseconds(ArchiveTime)
      ## see `ArchiveTime`, shorter in tests
    timestampVariance*: Duration = chronos.nanoseconds(MaxMessageTimestampVariance)
      ## see `MaxMessageTimestampVariance`, shorter in tests

func timeRange*(
    query: HistoryQuery, now, variance: Timestamp
): Result[tuple[startTime, endTime: Timestamp], string] =
  ## No end time means `now + variance`, because a sender's clock can be ahead.
  ## A later end time is an error, because no archive can have a message that late yet.
  if query.startTime < 0:
    return err("startTime must not be negative")
  let latest = now + variance
  let endTime = query.endTime.get(latest)
  if endTime > latest:
    return err(
      "endTime must not be more than " & $chronos.nanoseconds(variance) &
        " after the current time"
    )
  if endTime <= query.startTime:
    if query.endTime.isNone():
      return err(
        "startTime must be before the current time plus " &
          $chronos.nanoseconds(variance)
      )
    return err("endTime must be after startTime")
  if query.startTime < endTime - MaxHistoryQueryRange:
    if query.endTime.isNone():
      return err(
        "startTime must not be more than " & $MaxHistoryQueryDays &
          " days before the current time plus " & $chronos.nanoseconds(variance)
      )
    return
      err("the time range must not be longer than " & $MaxHistoryQueryDays & " days")
  return ok((query.startTime, endTime))

func new*(
    T: type HistoryQueryService,
    brokerCtx: BrokerContext,
    queryToAny: BackfillQuery,
    queryTimeout: Duration,
    clock: proc(): Timestamp {.gcsafe, raises: [].} = getNowInNanosecondTime,
): T =
  return HistoryQueryService(
    brokerCtx: brokerCtx,
    queryToAny: queryToAny,
    queryTimeout: queryTimeout,
    clock: clock,
    pageSlots: newAsyncSemaphore(MaxPagesInFlight),
  )

proc pruneFound(active: ActiveQuery, before: Timestamp) =
  var expired: seq[WakuMessageHash]
  for hash, at in active.found:
    if at < before:
      expired.add(hash)
  for hash in expired:
    active.found.del(hash)

proc fetchShard(
    self: HistoryQueryService, active: ActiveQuery, shard: PubsubTopic, start: Timestamp
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  ## Gets the messages of `shard` from `start` to the end of the range, page by page.
  let topic: BackfillTopic = (shard, active.contentTopic)
  let deliver: BackfillDeliver = proc(
      pubsubTopic: PubsubTopic, message: WakuMessage
  ): bool {.gcsafe, raises: [].} =
    if not self.running:
      return false
    if message.contentTopic != active.contentTopic:
      debug "History query skipped a message of another content topic",
        requestId = active.requestId, contentTopic = message.contentTopic
      return true
    let hash = computeMessageHash(pubsubTopic, message)
    if hash in active.found:
      return true
    active.found[hash] = message.timestamp
    inc active.messageCount
    recordHistoryQueryMessage(message.payload.len)
    let hashHex = hash.to0xHex()
    info "History query found a message",
      requestId = active.requestId, msg_hash = hashHex, pubsubTopic
    HistoryQueryMessageEvent.emit(self.brokerCtx, active.requestId, hashHex, message)
    return true
  var next = start
  var failures = 0
  var prunedBefore = start # the cutoff of the last prune in this pass
  while next < active.endTime:
    await self.pageSlots.acquire()
    let fetched =
      try:
        await fetchPage(
          topic, next, active.endTime, self.queryTimeout, self.queryToAny, deliver
        )
      finally:
        self.pageSlots.release2()
    if not self.running:
      return err("the history query service stopped")
    if fetched.isOk():
      next = fetched.get()
      failures = 0
      # The cutoff stops at `lastPartStart`.
      # A prune at the same cutoff finds nothing, so the loop skips it.
      let cutoff = min(next, active.lastPartStart)
      if cutoff > prunedBefore:
        active.pruneFound(cutoff)
        prunedBefore = cutoff
      continue
    inc failures
    debug "History query page failed",
      requestId = active.requestId, shard, attempt = failures, error = fetched.error
    if failures >= self.pageAttempts:
      return err(fetched.error)
    await sleepAsync(self.retryDelay)
  return ok()

proc fetchAll(
    self: HistoryQueryService, active: ActiveQuery
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  ## Gets the range, then its last part again when the archive has all of it.
  for shard in active.shards:
    ?await self.fetchShard(active, shard, active.startTime)
  if active.endTime <= active.lastPartStart:
    return ok() # the archive had all of the range at the call
  let left = active.readyAt - Moment.now()
  if left > ZeroDuration:
    await sleepAsync(left)
  for shard in active.shards:
    ?await self.fetchShard(active, shard, active.lastPartStart)
  return ok()

proc runQuery(
    self: HistoryQueryService, active: ActiveQuery
) {.async: (raises: [CancelledError]).} =
  ## Runs `active` until its last event, or until the service stops it.
  defer:
    self.tasks.del($active.requestId)
  # A zero timer lets the caller get the request id before the first event.
  await sleepAsync(ZeroDuration)
  let fetched = await self.fetchAll(active)
  if not self.running:
    return
  fetched.isOkOr:
    error "History query failed",
      requestId = active.requestId,
      contentTopic = active.contentTopic,
      messageCount = active.messageCount,
      error
    HistoryQueryErrorEvent.emit(self.brokerCtx, active.requestId, error)
    return
  info "History query completed",
    requestId = active.requestId,
    contentTopic = active.contentTopic,
    messageCount = active.messageCount
  HistoryQueryCompletedEvent.emit(self.brokerCtx, active.requestId, active.messageCount)

proc startQuery*(
    self: HistoryQueryService,
    requestId: RequestId,
    query: HistoryQuery,
    shards: seq[PubsubTopic],
): Result[void, string] =
  ## Starts `query` on `shards` in the background, with no event before it returns.
  if not self.running:
    return err("the history query service is not running")
  if shards.len == 0:
    return err("the content topic has no shard")
  if self.tasks.len >= MaxActiveHistoryQueries:
    return err("too many history queries are in progress, retry later")
  let now = self.clock()
  let variance = self.timestampVariance.nanos
  let archiveTime = self.archiveTime.nanos
  let (startTime, endTime) = ?query.timeRange(now, variance)
  info "History query started",
    requestId, contentTopic = query.contentTopic, shards, startTime, endTime
  let active = ActiveQuery(
    requestId: requestId,
    contentTopic: query.contentTopic,
    shards: shards,
    startTime: startTime,
    endTime: endTime,
    lastPartStart: max(startTime, archivedBefore(now, archiveTime, variance)),
    # `readyAt` is on the monotonic clock, so a wall clock jump does not change it.
    readyAt: Moment.now() + chronos.nanoseconds(endTime + variance + archiveTime - now),
  )
  let task = self.runQuery(active)
  if not task.finished():
    self.tasks[$requestId] = task
  return ok()

func activeQueryCount*(self: HistoryQueryService): int =
  return self.tasks.len

proc startHistoryQueryService*(self: HistoryQueryService) =
  self.running = true

proc stopHistoryQueryService*(self: HistoryQueryService) {.async: (raises: []).} =
  ## Cancels each active query, and a cancelled query emits no more events.
  self.running = false
  let tasks = toSeq(self.tasks.values)
  self.tasks.clear()
  await cancelAndWait(tasks)

{.pop.}

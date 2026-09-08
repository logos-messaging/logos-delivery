## Store catch-up of missed messages across process restarts.
##
## Each cycle asks Store nodes for messages on the subscribed topics. It saves
## a timestamp per topic on disk through Persistency. The next process resumes
## retrieval from that timestamp after a restart.
##
## Each query starts at the saved timestamp, clipped to the configured lookback.
## Returned messages go through the normal receive path. Then the cycle saves
## its progress. A query budget limits the work in each cycle.
{.push raises: [].}

import std/sets, chronos, chronicles, results, libp2p/protobuf/minprotobuf
import
  logos_delivery/waku/[waku_core, waku_store/common],
  logos_delivery/waku/common/paging,
  logos_delivery/waku/persistency/persistency
from logos_delivery/waku/waku_archive/archive import MaxMessageTimestampVariance

logScope:
  topics = "recv backfill"

const
  BackfillJobId* = "messaging-recv"
  BackfillCategory = "recv.backfill.v1"
  BackfillOverlap* = chronos.nanoseconds(MaxMessageTimestampVariance)
    ## Tail of an exhausted range that the next cycle queries again. Equal to
    ## the archive's late-timestamp window.
  WriteConfirmTimeout = chronos.seconds(5)

type
  BackfillTopic* = tuple[pubsubTopic: PubsubTopic, contentTopic: ContentTopic]

  BackfillQuery* = proc(
    request: StoreQueryRequest
  ): Future[Result[StoreQueryResponse, string]] {.gcsafe, raises: [].}
  BackfillDeliver* =
    proc(pubsubTopic: PubsubTopic, message: WakuMessage): bool {.gcsafe, raises: [].}
    ## False means the caller refused the message, for example after an unsubscribe.

  BackfillCycleOutcome* = object
    queries*: int
    completed*: int ## topics with an exhausted range
    failed*: int ## queries that failed or returned an invalid page
    storageFailed*: bool ## a storage operation failed. The caller suspends catch-up

  TopicScan = object
    topic: BackfillTopic
    resumeAt: Timestamp
    done: bool ## exhausted, failed, or at the cycle start. No more queries this cycle

func newlySubscribed*(
    previousTopics, currentTopics: openArray[BackfillTopic]
): seq[BackfillTopic] =
  ## Topics in `currentTopics` that are absent from `previousTopics`.
  var seen: HashSet[BackfillTopic]
  for topic in previousTopics:
    seen.incl(topic)
  var res: seq[BackfillTopic]
  for topic in currentTopics:
    if topic notin seen:
      res.add(topic)
  res

proc topicKey(topic: BackfillTopic): Result[Key, string] =
  if topic.pubsubTopic.len > StringLenMax or topic.contentTopic.len > StringLenMax:
    return err("backfill topic exceeds persistency key limit")
  ok(key(topic.pubsubTopic, topic.contentTopic))

proc encodeResumeAt(resumeAt: Timestamp): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, uint64(resumeAt))
  pb.finish()
  pb.buffer

proc decodeResumeAt(bytes: seq[byte]): Result[Timestamp, string] =
  let pb = initProtoBuffer(bytes)
  var raw: uint64
  let present = pb.getField(1, raw).valueOr:
    return err("resume timestamp: " & $error)
  if not present or raw == 0 or raw > uint64(int64.high):
    return err("resume timestamp is missing or out of range")
  ok(Timestamp(raw))

proc readResumeAt*(
    job: Job, topic: BackfillTopic
): Future[Result[Opt[Timestamp], string]] {.async: (raises: [CancelledError]).} =
  ## The stored timestamp, or none when the topic has no readable record.
  ## An unreadable record logs a warning and counts as none.
  if job.isNil() or not job.running:
    return err("backfill persistency job is closed")
  let k = ?topicKey(topic)
  let stored =
    try:
      (await job.get(BackfillCategory, k)).valueOr:
        return err("read backfill record: " & $error)
    except CancelledError as e:
      raise e
    except CatchableError as e:
      return err("read backfill record: " & e.msg)
  if stored.isNone():
    return ok(Opt.none(Timestamp))
  let at = decodeResumeAt(stored.get()).valueOr:
    warn "unreadable backfill record; catch-up for this topic restarts from the previous cycle",
      pubsubTopic = topic.pubsubTopic, contentTopic = topic.contentTopic, error
    return ok(Opt.none(Timestamp))
  return ok(Opt.some(at))

proc writeResumeAt(
    job: Job, topic: BackfillTopic, resumeAt: Timestamp
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  ## Persists `resumeAt` and reads it back until the stored bytes match.
  if job.isNil() or not job.running:
    return err("backfill persistency job is closed")
  let k = ?topicKey(topic)
  let payload = encodeResumeAt(resumeAt)
  try:
    await job.persistPut(BackfillCategory, k, payload)
    let deadline = Moment.now() + WriteConfirmTimeout
    while true:
      let stored = (await job.get(BackfillCategory, k)).valueOr:
        return err("read back backfill record: " & $error)
      if stored.isSome() and stored.get() == payload:
        return ok()
      if Moment.now() >= deadline:
        return err("timed out persisting backfill record")
      await sleepAsync(10.milliseconds)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    return err("persist backfill record: " & e.msg)

proc seedTopic*(
    job: Job, topic: BackfillTopic, resumeAt: Timestamp
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  ## Writes `resumeAt` if the topic has no record.
  if resumeAt <= 0:
    return err("invalid backfill seed")
  let stored = (await job.readResumeAt(topic)).valueOr:
    return err(error)
  if stored.isSome():
    return ok()
  return await job.writeResumeAt(topic, resumeAt)

proc queryPage(
    query: BackfillQuery, request: StoreQueryRequest, queryTimeout: Duration
): Future[Result[StoreQueryResponse, string]] {.async: (raises: [CancelledError]).} =
  try:
    let fut = query(request)
    if not await fut.withTimeout(queryTimeout):
      return err("store query timed out")
    return fut.read()
  except CancelledError as e:
    raise e
  except CatchableError as e:
    return err("store query: " & e.msg)

proc acceptPage(
    topic: BackfillTopic,
    queryStart, queryStop: Timestamp,
    response: StoreQueryResponse,
    deliver: BackfillDeliver,
): Result[Opt[Timestamp], string] =
  ## Validates and delivers one page. Returns the timestamp of the last
  ## message, or none when the range is exhausted.
  if response.statusCode != uint32(StatusCode.SUCCESS):
    return err("store response " & $response.statusCode & " " & response.statusDesc)
  if uint64(response.messages.len) > MaxPageSize:
    return err("store response exceeds the page size")
  var last = queryStart
  for row in response.messages:
    if row.message.isNone() or row.pubsubTopic != Opt.some(topic.pubsubTopic):
      return err("store response is missing data or has the wrong shard")
    let message = row.message.get()
    if message.contentTopic != topic.contentTopic or message.timestamp < last or
        message.timestamp >= queryStop or
        computeMessageHash(topic.pubsubTopic, message) != row.messageHash:
      return err("store response contains an invalid message")
    last = message.timestamp
  for row in response.messages:
    if not deliver(topic.pubsubTopic, row.message.get()):
      return err("delivery declined; subscription removed or stopping")
  if response.messages.len == 0:
    if response.paginationCursor.isSome():
      return err("store page is empty but claims more")
    return ok(Opt.none(Timestamp))
  if response.paginationCursor.isNone():
    return ok(Opt.none(Timestamp))
  if last == queryStart:
    # The next query returns this page again.
    return err("store page does not advance past " & $last)
  ok(Opt.some(last))

proc runCycle*(
    job: Job,
    subscribedTopics: seq[BackfillTopic],
    cycleStart: Timestamp,
    fallbackStart: Timestamp,
    firstTopicIndex: int,
    maxLookback: Duration,
    maxQueries: int,
    queryTimeout: Duration,
    query: BackfillQuery,
    deliver: BackfillDeliver,
): Future[BackfillCycleOutcome] {.async: (raises: [CancelledError]).} =
  ## Queries topics in turn, within the lookback and query budget.
  ## Saves progress. Failed topics wait for the next cycle.
  var outcome: BackfillCycleOutcome
  if subscribedTopics.len == 0:
    return outcome
  var scans: seq[TopicScan]
  for i in 0 ..< subscribedTopics.len:
    let topic = subscribedTopics[(firstTopicIndex + i) mod subscribedTopics.len]
    if topicKey(topic).isErr():
      debug "backfill skips a topic whose name exceeds the persistency key limit",
        pubsubTopicLength = topic.pubsubTopic.len,
        contentTopicLength = topic.contentTopic.len
      continue
    let stored = (await job.readResumeAt(topic)).valueOr:
      debug "backfill record read failed; cycle stopped",
        pubsubTopic = topic.pubsubTopic, contentTopic = topic.contentTopic, error
      outcome.storageFailed = true
      return outcome
    if stored.isNone():
      (await job.writeResumeAt(topic, fallbackStart)).isOkOr:
        outcome.storageFailed = true
        return outcome
    scans.add(TopicScan(topic: topic, resumeAt: stored.get(fallbackStart)))
  var remaining = maxQueries
  var progressed = true
  while remaining > 0 and progressed:
    progressed = false
    for i in 0 ..< scans.len:
      if remaining <= 0:
        break
      if scans[i].done:
        continue
      let topic = scans[i].topic
      let queryStart = max(scans[i].resumeAt, cycleStart - maxLookback.nanos)
      if queryStart >= cycleStart:
        scans[i].done = true
        continue
      dec remaining
      inc outcome.queries
      progressed = true
      let request = StoreQueryRequest(
        includeData: true,
        pubsubTopic: Opt.some(topic.pubsubTopic),
        contentTopics: @[topic.contentTopic],
        startTime: Opt.some(queryStart),
        endTime: Opt.some(cycleStart - 1), # inclusive on the wire
        paginationForward: PagingDirection.FORWARD,
        paginationLimit: Opt.some(MaxPageSize),
      )
      let response = await queryPage(query, request, queryTimeout)
      let accepted =
        if response.isOk():
          acceptPage(topic, queryStart, cycleStart, response.get(), deliver)
        else:
          Result[Opt[Timestamp], string].err(response.error)
      let next = accepted.valueOr:
        debug "backfill query failed; topic rests until the next cycle",
          pubsubTopic = topic.pubsubTopic, contentTopic = topic.contentTopic, error
        inc outcome.failed
        scans[i].done = true
        continue
      let resumeAt =
        if next.isSome():
          next.get()
        else:
          max(scans[i].resumeAt, cycleStart - BackfillOverlap.nanos)
      (await job.writeResumeAt(topic, resumeAt)).isOkOr:
        debug "backfill record write not confirmed; cycle stopped",
          pubsubTopic = topic.pubsubTopic, contentTopic = topic.contentTopic, error
        outcome.storageFailed = true
        return outcome
      scans[i].resumeAt = resumeAt
      if next.isNone():
        scans[i].done = true
        inc outcome.completed
  return outcome

{.pop.}

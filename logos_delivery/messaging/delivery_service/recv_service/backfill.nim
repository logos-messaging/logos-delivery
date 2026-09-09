## Store catch-up of missed messages after a stop.
##
## The node keeps one timestamp in Persistency, the last time it was online.
## A catch-up queries every subscribed topic from that timestamp to now, one
## page at a time, and delivers the pages through the normal receive path.
## Delivery is at-least-once: a restart re-queries the overlap, and the
## receive cache that drops duplicates starts empty. The Store node's own
## retention bounds how far back a query reaches.
{.push raises: [].}

import chronos, chronicles, results, libp2p/protobuf/minprotobuf
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
    ## Queried again before the stored timestamp. Equal to the archive's
    ## late-timestamp window.
  WriteConfirmTimeout = chronos.seconds(5)
  MaxQueriesPerCatchUp* = 10_000
    ## One catch-up asks no more than this, so a Store node that answers with
    ## tiny steps forever cannot hold the worker. Topics are done in order and
    ## finished ones are remembered, so the next catch-up carries on.

type
  BackfillTopic* = tuple[pubsubTopic: PubsubTopic, contentTopic: ContentTopic]

  BackfillQuery* = proc(
    request: StoreQueryRequest
  ): Future[Result[StoreQueryResponse, string]] {.gcsafe, raises: [].}
  BackfillDeliver* =
    proc(pubsubTopic: PubsubTopic, message: WakuMessage): bool {.gcsafe, raises: [].}
    ## False means the caller refused the message, for example after an unsubscribe.

  BackfillOutcome* = object
    queries*: int
    completedTopics*: seq[BackfillTopic] ## topics with an exhausted range
    failed*: int ## queries that failed or returned an invalid page

proc lastOnlineKey(): Key =
  key("last-online")

proc encodeTimestamp(at: Timestamp): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, uint64(at))
  pb.finish()
  pb.buffer

proc decodeTimestamp(bytes: seq[byte]): Result[Timestamp, string] =
  let pb = initProtoBuffer(bytes)
  var raw: uint64
  let present = pb.getField(1, raw).valueOr:
    return err("timestamp: " & $error)
  if not present or raw == 0 or raw > uint64(int64.high):
    return err("timestamp is missing or out of range")
  ok(Timestamp(raw))

proc readLastOnline*(
    job: Job
): Future[Result[Opt[Timestamp], string]] {.async: (raises: [CancelledError]).} =
  ## The last time the node was online, or none when nothing is stored. An
  ## unreadable record logs a warning and counts as none.
  if job.isNil() or not job.running:
    return err("backfill persistency job is closed")
  let stored =
    try:
      (await job.get(BackfillCategory, lastOnlineKey())).valueOr:
        return err("read last-online record: " & $error)
    except CancelledError as e:
      raise e
    except CatchableError as e:
      return err("read last-online record: " & e.msg)
  if stored.isNone():
    return ok(Opt.none(Timestamp))
  let at = decodeTimestamp(stored.get()).valueOr:
    warn "unreadable last-online record; catch-up starts from the service start", error
    return ok(Opt.none(Timestamp))
  return ok(Opt.some(at))

proc writeLastOnline*(
    job: Job, at: Timestamp
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  ## Persists `at` and reads it back until the stored bytes match.
  if job.isNil() or not job.running:
    return err("backfill persistency job is closed")
  if at <= 0:
    return err("invalid last-online timestamp")
  let payload = encodeTimestamp(at)
  try:
    await job.persistPut(BackfillCategory, lastOnlineKey(), payload)
    let deadline = Moment.now() + WriteConfirmTimeout
    while true:
      let stored = (await job.get(BackfillCategory, lastOnlineKey())).valueOr:
        return err("read back last-online record: " & $error)
      if stored.isSome() and stored.get() == payload:
        return ok()
      if Moment.now() >= deadline:
        return err("timed out persisting last-online record")
      await sleepAsync(100.milliseconds)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    return err("persist last-online record: " & e.msg)

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
  if response.paginationCursor.isNone():
    return ok(Opt.none(Timestamp)) # the range is exhausted
  if response.messages.len == 0:
    return err("store page is empty but claims more")
  if last == queryStart:
    # Every message in the page shares the query start, so the next query by
    # time returns this same page. Step past that instant. Any message beyond
    # this page at that instant is not fetched.
    warn "backfill steps past a timestamp that fills a page",
      pubsubTopic = topic.pubsubTopic,
      contentTopic = topic.contentTopic,
      timestamp = last
    return ok(Opt.some(last + 1))
  ok(Opt.some(last))

proc runCatchUp*(
    subscribedTopics: seq[BackfillTopic],
    since: Timestamp,
    now: Timestamp,
    queryTimeout: Duration,
    query: BackfillQuery,
    deliver: BackfillDeliver,
): Future[BackfillOutcome] {.async: (raises: [CancelledError]).} =
  ## Queries the topics in order over `[since, now)`, page by page, until each
  ## one is exhausted or fails. The catch-up stops at `MaxQueriesPerCatchUp`;
  ## the caller keeps the completed topics and asks again later.
  var outcome: BackfillOutcome
  for topic in subscribedTopics:
    var start = since
    var completed = false
    while outcome.queries < MaxQueriesPerCatchUp:
      if start >= now:
        completed = true
        break
      inc outcome.queries
      let request = StoreQueryRequest(
        includeData: true,
        pubsubTopic: Opt.some(topic.pubsubTopic),
        contentTopics: @[topic.contentTopic],
        startTime: Opt.some(start),
        endTime: Opt.some(now - 1), # inclusive on the wire
        paginationForward: PagingDirection.FORWARD,
        paginationLimit: Opt.some(MaxPageSize),
      )
      let response = await queryPage(query, request, queryTimeout)
      let accepted =
        if response.isOk():
          acceptPage(topic, start, now, response.get(), deliver)
        else:
          Result[Opt[Timestamp], string].err(response.error)
      let next = accepted.valueOr:
        debug "backfill query failed; topic rests until the next catch-up",
          pubsubTopic = topic.pubsubTopic, contentTopic = topic.contentTopic, error
        inc outcome.failed
        break
      if next.isNone():
        completed = true
        break
      start = next.get()
    if completed:
      outcome.completedTopics.add(topic)
    elif outcome.queries >= MaxQueriesPerCatchUp:
      debug "backfill reached its query limit; the rest waits for the next catch-up",
        queries = outcome.queries
      break
  return outcome

{.pop.}

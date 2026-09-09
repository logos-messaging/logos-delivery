## Store catch-up of missed messages after a stop.
##
## The node keeps one timestamp in Persistency, the last time it was online.
## A catch-up queries every subscribed topic from that timestamp to now, one
## page at a time, and delivers the pages through the normal receive path. A
## restart re-queries the 20 s before the timestamp, and the receive cache
## starts empty, so messages near it arrive again. The Store node's own
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
    failed*: int ## queries that failed or returned an unusable row

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

proc writeLastOnline*(job: Job, at: Timestamp) {.async: (raises: [CancelledError]).} =
  ## Hands `at` to Persistency. The write is fire-and-forget, as its API is; a
  ## write that is lost costs extra history at the next start.
  try:
    await job.persistPut(BackfillCategory, lastOnlineKey(), encodeTimestamp(at))
  except CancelledError as e:
    raise e
  except CatchableError as e:
    warn "last-online timestamp not written", error = e.msg

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
  ## Delivers one page in order. Returns the timestamp of the last message,
  ## or none when the range is exhausted. A row that cannot be used ends the
  ## page; the rows before it are delivered.
  var last = queryStart
  for row in response.messages:
    let message = row.message.valueOr:
      return err("store row without a message")
    if message.timestamp < last or message.timestamp >= queryStop:
      return err("store row out of order or outside the range")
    if not deliver(topic.pubsubTopic, message):
      return err("delivery declined; subscription removed or stopping")
    last = message.timestamp
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
  ## one is exhausted or fails.
  var outcome: BackfillOutcome
  for topic in subscribedTopics:
    var start = since
    var completed = true
    while start < now:
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
        completed = false
        break
      if next.isNone():
        break
      start = next.get()
    if completed:
      outcome.completedTopics.add(topic)
  return outcome

{.pop.}

## Store catch-up of missed messages after a stop.
{.push raises: [].}

import std/[algorithm, sets, tables]
import chronos, chronicles, results, libp2p/protobuf/minprotobuf
import
  logos_delivery/waku/[waku_core, waku_store/common],
  logos_delivery/waku/common/paging,
  logos_delivery/waku/persistency/persistency
from logos_delivery/waku/waku_archive/archive import MaxMessageTimestampVariance

logScope:
  topics = "recv backfill"

const
  BackfillCategory* = "recv.backfill.v1"
    ## the receive service's category in the messaging layer's Persistency job
  LastOnlineKey* = key("last-online")
  BackfillOverlap* = 2 * MaxMessageTimestampVariance
    ## Start the query 40 seconds before the saved time. Allow 20 seconds for
    ## messages that reach the archive late and 20 seconds for differences
    ## between this node's clock and the archive's clock.

type
  BackfillTopic* = tuple[pubsubTopic: PubsubTopic, contentTopic: ContentTopic]

  BackfillQuery* = proc(
    request: StoreQueryRequest
  ): Future[Result[StoreQueryResponse, string]] {.gcsafe, raises: [].}
  BackfillDeliver* =
    proc(pubsubTopic: PubsubTopic, message: WakuMessage): bool {.gcsafe, raises: [].}
    ## True accepts the message, duplicates included. False ends the topic.

proc backfillTopics*(
    subscriptions: seq[(PubsubTopic, HashSet[ContentTopic])]
): seq[BackfillTopic] =
  ## The subscribed (shard, content topic) pairs, sorted for a stable pass order.
  var topics: seq[BackfillTopic]
  for (pubsubTopic, contentTopics) in subscriptions:
    for contentTopic in contentTopics:
      topics.add((pubsubTopic, contentTopic))
  topics.sort()
  return topics

proc encodeTimestamp(at: Timestamp): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, uint64(at))
  pb.finish()
  return pb.buffer

proc decodeTimestamp(bytes: seq[byte]): Result[Timestamp, string] =
  let pb = initProtoBuffer(bytes)
  var raw: uint64
  let present = pb.getField(1, raw).valueOr:
    return err("timestamp: " & $error)
  if not present or raw == 0 or raw > uint64(int64.high):
    return err("timestamp is missing or out of range")
  return ok(Timestamp(raw))

proc readRecoveryHint*(
    job: persistency.Job
): Future[Result[Opt[Timestamp], string]] {.async: (raises: [CancelledError]).} =
  ## The stored recovery hint. An unreadable record logs a warning and reads
  ## as none.
  if job.isNil() or not job.running:
    return err("backfill persistency job is closed")
  let stored =
    try:
      (await job.get(BackfillCategory, LastOnlineKey)).valueOr:
        return err("read recovery hint: " & $error)
    except CancelledError as e:
      raise e
    except CatchableError as e:
      return err("read recovery hint: " & e.msg)
  if stored.isNone():
    return ok(Opt.none(Timestamp))
  let at = decodeTimestamp(stored.get()).valueOr:
    warn "Failed to decode the Store catch-up recovery hint", error
    return ok(Opt.none(Timestamp))
  return ok(Opt.some(at))

proc writeRecoveryHint*(
    job: persistency.Job, at: Timestamp
) {.async: (raises: [CancelledError]).} =
  ## Fire-and-forget, as the Persistency write API is. A lost write costs
  ## extra history at the next start.
  try:
    await job.persistPut(BackfillCategory, LastOnlineKey, encodeTimestamp(at))
  except CancelledError as e:
    raise e
  except CatchableError as e:
    warn "Failed to write the Store catch-up recovery hint", error = e.msg

proc queryPage(
    query: BackfillQuery, request: StoreQueryRequest, queryTimeout: Duration
): Future[Result[StoreQueryResponse, string]] {.async: (raises: [CancelledError]).} =
  try:
    let pending = query(request)
    if not await pending.withTimeout(queryTimeout): # cancels the query
      return err("store query timed out")
    return pending.read()
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
  ## or none when the range has no more rows. A bad row fails the page, and
  ## the rows before it stay delivered.
  var last = queryStart
  for row in response.messages:
    let message = row.message.valueOr:
      return err("store row without a message")
    if message.timestamp < last or message.timestamp >= queryStop:
      return err("store row out of order or outside the range")
    if not deliver(topic.pubsubTopic, message):
      return err("delivery declined")
    last = message.timestamp
  if response.paginationCursor.isNone():
    return ok(Opt.none(Timestamp)) # the range is exhausted
  if response.messages.len == 0:
    return err("store page is empty but claims more")
  if last == queryStart:
    # Every message in the page shares the query start, so a query from that
    # instant returns this same page. Step past the instant. The catch-up does
    # not deliver the messages at that instant beyond this page.
    debug "Store catch-up steps past a timestamp that fills a page",
      pubsubTopic = topic.pubsubTopic,
      contentTopic = topic.contentTopic,
      timestamp = last
    return ok(Opt.some(last + 1))
  return ok(Opt.some(last))

proc runCatchUpPass*(
    subscribedTopics: seq[BackfillTopic],
    progress: TableRef[BackfillTopic, Timestamp],
    since: Timestamp,
    cutoff: Timestamp,
    queryTimeout: Duration,
    query: BackfillQuery,
    deliver: BackfillDeliver,
): Future[seq[BackfillTopic]] {.async: (raises: [CancelledError]).} =
  ## One pass. Queries the topics in order over `[since, cutoff)`, page by
  ## page, until each one has no more rows or fails. A failed topic leaves its
  ## next page start in `progress` and continues from there in the next pass.
  ## Returns the topics that have no more rows.
  var exhausted: seq[BackfillTopic]
  for topic in subscribedTopics:
    var start = progress.getOrDefault(topic, since)
    var completed = true
    while start < cutoff:
      let request = StoreQueryRequest(
        includeData: true,
        pubsubTopic: Opt.some(topic.pubsubTopic),
        contentTopics: @[topic.contentTopic],
        startTime: Opt.some(start),
        endTime: Opt.some(cutoff - 1), # inclusive on the wire
        paginationForward: PagingDirection.FORWARD,
        paginationLimit: Opt.some(MaxPageSize),
      )
      let response = await queryPage(query, request, queryTimeout)
      let accepted =
        if response.isOk():
          acceptPage(topic, start, cutoff, response.get(), deliver)
        else:
          Result[Opt[Timestamp], string].err(response.error)
      let next = accepted.valueOr:
        debug "Store catch-up query failed, the topic retries next pass",
          pubsubTopic = topic.pubsubTopic, contentTopic = topic.contentTopic, error
        progress[topic] = start
        completed = false
        break
      if next.isNone():
        break
      start = next.get()
    if completed:
      exhausted.add(topic)
      progress.del(topic)
  return exhausted

{.pop.}

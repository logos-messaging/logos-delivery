## The backfill of the messages that the node missed on its subscribed topics.
##
## Each subscribed (shard, content topic) has one `TopicRecord`. An outage of
## live delivery (relay, or the filter subscriptions on Edge), or a restart,
## turns its gap bit on. The backfill worker turns it off after Store gives the
## messages up to the time when live delivery covered the topic again. An
## unsubscribe deletes the record.
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
    ## the time of the last received message, written while the backfill
    ## state is on disk
  TopicKeyTag = "topic"
  TopicKeyPrefix = key(TopicKeyTag)
  ArchiveTime* = chronos.seconds(20).nanos
    ## A message is in the archive at most this long after its publication.
  DelayExtra* = chronos.seconds(5).nanos
    ## Live delivery can need this long after a subscribe or a reconnection
    ## before it delivers a topic, for the filter loop on Edge or the mesh on
    ## Core.
  OutageWindow* = chronos.minutes(5).nanos
    ## An outage that the node detects now started at most this long before. It
    ## covers the lag of the health signal and the variance of the timestamps.

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
    ## True accepts the message, duplicates included. False fails the page.

  TopicRecord* = object
    ## The backfill state of one (shard, content topic) that the app
    ## subscribed. With `timestampToNowIsGap` off, live delivery covers the
    ## topic from `timestamp`. With it on, the app lacks the messages of the
    ## topic from `timestamp`, and Store has them.
    timestamp*: Timestamp
    timestampToNowIsGap*: bool

func live*(T: type TopicRecord, timestamp: Timestamp): TopicRecord =
  TopicRecord(timestamp: timestamp, timestampToNowIsGap: false)

func gap*(T: type TopicRecord, timestamp: Timestamp): TopicRecord =
  TopicRecord(timestamp: timestamp, timestampToNowIsGap: true)

func backfillTopics*(
    subscriptions: seq[(PubsubTopic, HashSet[ContentTopic])]
): seq[BackfillTopic] =
  ## The subscribed (shard, content topic) pairs, sorted.
  var topics: seq[BackfillTopic]
  for (pubsubTopic, contentTopics) in subscriptions:
    for contentTopic in contentTopics:
      topics.add((pubsubTopic, contentTopic))
  topics.sort()
  return topics

func newRecord*(
    at: Timestamp,
    live: bool,
    liveSince: Timestamp,
    variance = MaxMessageTimestampVariance,
): TopicRecord =
  ## The record of a topic subscribed at `at`. When live delivery is ready now
  ## and did not change after the subscribe, it covers the topic from the
  ## subscribe, and the topic gets no history. Otherwise the record is a gap from
  ## the subscribe. The archive accepts a timestamp `variance` away from its
  ## clock, so the bound is `variance` below the subscribe.
  if live and liveSince <= at:
    return TopicRecord.live(at - variance)
  return TopicRecord.gap(at - variance)

func inOutage*(record: TopicRecord, detectedAt: Timestamp): TopicRecord =
  ## The record after an outage of live delivery that the node detects at
  ## `detectedAt`. The outage started at most `OutageWindow` before. A record
  ## with a gap keeps its bound.
  if record.timestampToNowIsGap:
    return record
  return TopicRecord.gap(max(record.timestamp, detectedAt - OutageWindow))

func atStart*(record: TopicRecord, lastReceivedAt: Opt[Timestamp]): TopicRecord =
  ## The record at a service start. A restart is an outage that the node
  ## detects at the time of the last received message. With no such time, the
  ## record is a gap from its own timestamp.
  if record.timestampToNowIsGap:
    return record
  if lastReceivedAt.isNone():
    return TopicRecord.gap(record.timestamp)
  return record.inOutage(lastReceivedAt.get())

func coveredFrom*(
    liveSince, subscribedSince: Timestamp,
    delayExtra = DelayExtra,
    variance = MaxMessageTimestampVariance,
): Timestamp =
  ## The time from which live delivery covers a topic. It is the later of the
  ## last recovery and the subscribe, plus `delayExtra` and `variance`. The
  ## gap of a topic ends here.
  return max(liveSince, subscribedSince) + delayExtra + variance

func archivedBefore*(
    now: Timestamp, archiveTime = ArchiveTime, variance = MaxMessageTimestampVariance
): Timestamp =
  ## The archive has every message with a timestamp before this time.
  return now - variance - archiveTime

func encodeTimestamp(at: Timestamp): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, uint64(at))
  pb.finish()
  return pb.buffer

func decodeTimestamp(bytes: seq[byte]): Result[Timestamp, string] =
  let pb = initProtoBuffer(bytes)
  var raw: uint64
  let present = pb.getField(1, raw).valueOr:
    return err("timestamp: " & $error)
  if not present or raw == 0 or raw > uint64(int64.high):
    return err("timestamp is missing or out of range")
  return ok(Timestamp(raw))

func topicKey(topic: BackfillTopic): Opt[Key] =
  ## None when a name is too long for a key.
  if topic.pubsubTopic.len > StringLenMax or topic.contentTopic.len > StringLenMax:
    return Opt.none(Key)
  return Opt.some(key(TopicKeyTag, topic.pubsubTopic, topic.contentTopic))

func encodeTopicRecord(topic: BackfillTopic, record: TopicRecord): seq[byte] =
  ## The row of a topic. It carries the topic, so a read of the rows needs
  ## no decode of the keys.
  var pb = initProtoBuffer()
  pb.write(1, uint64(record.timestamp))
  pb.write(2, uint64(ord(record.timestampToNowIsGap)))
  pb.write(3, topic.pubsubTopic)
  pb.write(4, topic.contentTopic)
  pb.finish()
  return pb.buffer

func decodeTopicRecord(bytes: seq[byte]): Result[(BackfillTopic, TopicRecord), string] =
  let pb = initProtoBuffer(bytes)
  var timestamp, isGap: uint64
  var pubsubTopic, contentTopic: string
  let hasTimestamp = pb.getField(1, timestamp).valueOr:
    return err("topic record: " & $error)
  let hasIsGap = pb.getField(2, isGap).valueOr:
    return err("topic record: " & $error)
  let hasShard = pb.getField(3, pubsubTopic).valueOr:
    return err("topic record: " & $error)
  let hasContentTopic = pb.getField(4, contentTopic).valueOr:
    return err("topic record: " & $error)
  if not hasTimestamp or not hasIsGap or not hasShard or not hasContentTopic:
    return err("topic record is incomplete")
  if timestamp == 0 or timestamp > uint64(int64.high) or isGap > 1:
    return err("topic record is out of range")
  let record =
    TopicRecord(timestamp: Timestamp(timestamp), timestampToNowIsGap: isGap == 1)
  return ok(((pubsubTopic, contentTopic), record))

func topicRecordOp*(topic: BackfillTopic, record: TopicRecord): seq[TxOp] =
  ## The write of a topic record. Empty for a topic whose names are too long
  ## for a key. Such a topic has no record, so it is new at each start.
  let recordKey = topicKey(topic).valueOr:
    return @[]
  return @[
    TxOp(
      category: BackfillCategory,
      key: recordKey,
      kind: txPut,
      payload: encodeTopicRecord(topic, record),
    )
  ]

func deleteTopicRecordOp*(topic: BackfillTopic): seq[TxOp] =
  ## The delete of a topic record. Empty for a topic that has no key.
  let recordKey = topicKey(topic).valueOr:
    return @[]
  return @[TxOp(category: BackfillCategory, key: recordKey, kind: txDelete)]

proc readLastReceivedAt*(
    job: persistency.Job
): Future[Result[Opt[Timestamp], string]] {.async: (raises: [CancelledError]).} =
  ## The stored time of the last received message. An unreadable record
  ## logs a warning and reads as none.
  if job.isNil() or not job.running:
    return err("backfill persistency job is closed")
  let stored =
    try:
      (await job.get(BackfillCategory, LastOnlineKey)).valueOr:
        return err("read the last received time: " & $error)
    except CancelledError as e:
      raise e
    except CatchableError as e:
      return err("read the last received time: " & e.msg)
  if stored.isNone():
    return ok(Opt.none(Timestamp))
  let at = decodeTimestamp(stored.get()).valueOr:
    warn "Failed to decode the last received time of the backfill", error
    return ok(Opt.none(Timestamp))
  return ok(Opt.some(at))

proc writeLastReceivedAt*(
    job: persistency.Job, at: Timestamp
) {.async: (raises: [CancelledError]).} =
  ## Fire-and-forget, as the Persistency write API is. A lost write costs
  ## extra history at the next start.
  try:
    await job.persistPut(BackfillCategory, LastOnlineKey, encodeTimestamp(at))
  except CancelledError as e:
    raise e
  except CatchableError as e:
    warn "Failed to write the last received time of the backfill", error = e.msg

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

proc readTopicRecords*(
    job: persistency.Job
): Future[Result[seq[(BackfillTopic, TopicRecord)], string]] {.
    async: (raises: [CancelledError])
.} =
  ## The stored topic records. A record that does not decode logs a warning
  ## and is left out, so its topic is new at its next subscribe.
  if job.isNil() or not job.running:
    return err("backfill persistency job is closed")
  let rows =
    try:
      (await job.scanPrefix(BackfillCategory, TopicKeyPrefix)).valueOr:
        return err("read topic records: " & $error)
    except CancelledError as e:
      raise e
    except CatchableError as e:
      return err("read topic records: " & e.msg)
  var records: seq[(BackfillTopic, TopicRecord)]
  for row in rows:
    let decoded = decodeTopicRecord(row.payload).valueOr:
      warn "Failed to decode a backfill topic record", error
      continue
    records.add(decoded)
  return ok(records)

proc writeTopicRecords*(
    job: persistency.Job, ops: seq[TxOp]
) {.async: (raises: [CancelledError]).} =
  ## Fire-and-forget, as one transaction. The writes of a job apply in order.
  if ops.len == 0:
    return
  try:
    await job.persist(ops)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    warn "Failed to write the backfill topic records", error = e.msg

proc clearBackfillState*(job: persistency.Job) {.async: (raises: [CancelledError]).} =
  ## Deletes the topic records and the last received time. A start with the
  ## restart backfill off resets its state, so a later start with it on
  ## starts clean.
  if job.isNil() or not job.running:
    return
  try:
    await job.persist(
      @[
        TxOp(category: BackfillCategory, key: TopicKeyPrefix, kind: txDeletePrefix),
        TxOp(category: BackfillCategory, key: LastOnlineKey, kind: txDelete),
      ]
    )
  except CancelledError as e:
    raise e
  except CatchableError as e:
    warn "Failed to clear the backfill state", error = e.msg

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
    # instant returns this same page. Step past the instant. The backfill does
    # not deliver the messages at that instant beyond this page.
    debug "Backfill steps past a timestamp that fills a page",
      pubsubTopic = topic.pubsubTopic,
      contentTopic = topic.contentTopic,
      timestamp = last
    return ok(Opt.some(last + 1))
  return ok(Opt.some(last))

proc fetchPage*(
    topic: BackfillTopic,
    start, stop: Timestamp,
    queryTimeout: Duration,
    query: BackfillQuery,
    deliver: BackfillDeliver,
): Future[Result[Timestamp, string]] {.async: (raises: [CancelledError]).} =
  ## One Store query for `topic` from `start`, in a window no longer than
  ## the Store's `MaxQueryTimeRange` and not past `stop`. Delivers the page
  ## and returns the next start. The next start is the timestamp of the last
  ## message, or the end of the window when the window has no more rows.
  let windowStop = min(stop, start + MaxQueryTimeRange)
  let request = StoreQueryRequest(
    includeData: true,
    pubsubTopic: Opt.some(topic.pubsubTopic),
    contentTopics: @[topic.contentTopic],
    startTime: Opt.some(start),
    endTime: Opt.some(windowStop), # exclusive on the wire
    paginationForward: PagingDirection.FORWARD,
    paginationLimit: Opt.some(MaxPageSize),
  )
  let response = ?await queryPage(query, request, queryTimeout)
  let next = ?acceptPage(topic, start, windowStop, response, deliver)
  return ok(next.get(windowStop))

proc runCatchUpPass*(
    subscribedTopics: seq[BackfillTopic],
    progress: TableRef[BackfillTopic, Timestamp],
    since: Timestamp,
    cutoff: Timestamp,
    queryTimeout: Duration,
    query: BackfillQuery,
    deliver: BackfillDeliver,
): Future[seq[BackfillTopic]] {.async: (raises: [CancelledError]).} =
  ## One pass. Queries the topics in order over `[since, cutoff)`, in windows
  ## no longer than the Store's `MaxQueryTimeRange` and page by page, until
  ## each one has no more rows or fails. A failed topic leaves its
  ## next page start in `progress` and continues from there in the next pass.
  ## Returns the topics that have no more rows.
  var exhausted: seq[BackfillTopic]
  for topic in subscribedTopics:
    var start = progress.getOrDefault(topic, since)
    var completed = true
    while start < cutoff:
      let windowStop = min(cutoff, start + MaxQueryTimeRange)
      let request = StoreQueryRequest(
        includeData: true,
        pubsubTopic: Opt.some(topic.pubsubTopic),
        contentTopics: @[topic.contentTopic],
        startTime: Opt.some(start),
        endTime: Opt.some(windowStop), # exclusive on the wire
        paginationForward: PagingDirection.FORWARD,
        paginationLimit: Opt.some(MaxPageSize),
      )
      let response = await queryPage(query, request, queryTimeout)
      let accepted =
        if response.isOk():
          acceptPage(topic, start, windowStop, response.get(), deliver)
        else:
          Result[Opt[Timestamp], string].err(response.error)
      let next = accepted.valueOr:
        debug "Store catch-up query failed, the topic retries next pass",
          pubsubTopic = topic.pubsubTopic, contentTopic = topic.contentTopic, error
        progress[topic] = start
        completed = false
        break
      start = next.valueOr:
        windowStop # the window is exhausted, move to the next one
    if completed:
      exhausted.add(topic)
      progress.del(topic)
  return exhausted

{.pop.}

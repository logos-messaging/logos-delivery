{.used.}

## Few multi-phase cases. Each `test` block costs three GC-tracked globals, and
## the refc runtime caps the test binary at 3500.

import std/[os, tempfiles, sequtils, strutils, tables]
import chronos, results, testutils/unittests
import stew/byteutils

import ../testlib/testasync
import logos_delivery/messaging/delivery_service/recv_service/backfill
import logos_delivery/messaging/delivery_service/recv_service/recv_service
import logos_delivery/messaging/messaging_client_lifecycle
import logos_delivery/api/conf/messaging_conf
import logos_delivery/api/conf/logos_delivery_conf_json
import logos_delivery/waku/[waku_core, waku_store/common]
import logos_delivery/waku/persistency/persistency
from logos_delivery/waku/waku_archive/archive import MaxMessageTimestampVariance

const
  Base = 1_700_000_000_000_000_000'i64 ## 2023-11-14
  QueryTimeout = chronos.seconds(10)
  Hour = chronos.hours(1).nanos
  Minute = chronos.minutes(1).nanos
  Second = chronos.seconds(1).nanos
  TestTopic: BackfillTopic = ("/waku/2/rs/3/0", "/backfill/1/restart/proto")
  OtherTopic: BackfillTopic = ("/waku/2/rs/3/0", "/backfill/1/other/proto")

proc rowAt(timestamp: Timestamp, index: int, topic = TestTopic): WakuMessageKeyValue =
  let message = WakuMessage(
    payload: ("msg-" & $index).toBytes(),
    contentTopic: topic.contentTopic,
    timestamp: timestamp,
  )
  return WakuMessageKeyValue(
    messageHash: computeMessageHash(topic.pubsubTopic, message),
    message: Opt.some(message),
    pubsubTopic: Opt.some(topic.pubsubTopic),
  )

proc page(
    rows: seq[WakuMessageKeyValue], hasMore = false
): Result[StoreQueryResponse, string] =
  ## `hasMore` sets the cursor, as a Store does when the range holds more rows.
  let cursor =
    if hasMore and rows.len > 0:
      Opt.some(rows[^1].messageHash)
    else:
      Opt.none(WakuMessageHash)
  return
    ok(StoreQueryResponse(statusCode: 200, messages: rows, paginationCursor: cursor))

proc accept(pubsubTopic: PubsubTopic, message: WakuMessage): bool =
  return true

proc fetchAll(
    topic: BackfillTopic,
    start, stop: Timestamp,
    query: BackfillQuery,
    deliver: BackfillDeliver = accept,
    queryTimeout = QueryTimeout,
): Future[Result[int, string]] {.async.} =
  ## Fetches `[start, stop)` of one topic page by page, as the worker does
  ## over its turns. The number of queries, or the error of the query that
  ## failed.
  var next = start
  var queries = 0
  while next < stop:
    next = ?await fetchPage(topic, next, stop, queryTimeout, query, deliver)
    inc queries
  return ok(queries)

proc fetchFrom(
    topic: BackfillTopic, start, stop: Timestamp, query: BackfillQuery
): Future[tuple[completed: bool, next: Timestamp]] {.async.} =
  ## As `fetchAll`, and gives the next start after a failure, as the record
  ## of the worker keeps it.
  var next = start
  while next < stop:
    let res = await fetchPage(topic, next, stop, QueryTimeout, query, accept)
    if res.isErr():
      return (false, next)
    next = res.get()
  return (true, next)

proc waitStored(
    job: Job, category: string, recordKey: Key, expected: seq[byte]
) {.async.} =
  let deadline = Moment.now() + 2.seconds
  while (await job.get(category, recordKey)).get() != Opt.some(expected):
    doAssert Moment.now() < deadline
    await sleepAsync(10.milliseconds)

proc waitLastReceivedAt(job: Job, expected: Opt[Timestamp]) {.async.} =
  ## Writes are fire-and-forget. Waits until the record reads as `expected`.
  let deadline = Moment.now() + 2.seconds
  while (await job.readLastReceivedAt()).get() != expected:
    doAssert Moment.now() < deadline
    await sleepAsync(10.milliseconds)

proc names(payloads: openArray[string]): seq[string] =
  return payloads.deduplicate()

suite "Receive backfill":
  asyncTest "the last received time survives a Persistency reopen; bad records count as none":
    let root = createTempDir("recv-backfill-", "")
    defer:
      removeDir(root)
    block:
      let persistency = Persistency.new(root).get()
      let job = persistency.openJob(MessagingJobId).get()
      check (await job.readLastReceivedAt()).get().isNone()
      await job.writeLastReceivedAt(Base)
      await job.waitLastReceivedAt(Opt.some(Base))
      persistency.close()
    block:
      let persistency = Persistency.new(root).get()
      defer:
        persistency.close()
      let job = persistency.openJob(MessagingJobId).get()
      check (await job.readLastReceivedAt()).get() == Opt.some(Base)
      for badRecord in [
        @[0x08'u8, 0x00],
        @[0xff'u8, 0x01, 0x02],
        @[0x08'u8, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01],
      ]:
        await job.persistPut(BackfillCategory, LastOnlineKey, badRecord)
        await job.waitStored(BackfillCategory, LastOnlineKey, badRecord)
        check (await job.readLastReceivedAt()).get().isNone()
      await job.writeLastReceivedAt(Base + Hour)
      await job.waitLastReceivedAt(Opt.some(Base + Hour))
      persistency.closeJob(MessagingJobId)
      check (await job.readLastReceivedAt()).isErr()

  asyncTest "backfill: page progress, range bounds, failures":
    let t0 = Base
    let t1 = Base + Hour
    # The fake Store applies the time bounds, answers one page in forward
    # order, and sets a cursor when the range holds more rows. Six rows in
    # the first hour, two at the same instant, three per page. A query from a
    # shared timestamp returns that row again, a duplicate that the receive
    # service drops.
    var content: Table[BackfillTopic, seq[WakuMessageKeyValue]]
    var pageSize = 3
    var calls = 0
    var seen: seq[(Timestamp, Timestamp)]
    let query: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      inc calls
      doAssert request.paginationCursor.isNone()
      seen.add((request.startTime.get(), request.endTime.get()))
      let topic: BackfillTopic = (request.pubsubTopic.get(), request.contentTopics[0])
      let inRange = content.getOrDefault(topic).filterIt(
          it.message.get().timestamp >= request.startTime.get() and
            it.message.get().timestamp < request.endTime.get()
        )
      let pageLen = min(inRange.len, pageSize)
      return page(inRange[0 ..< pageLen], hasMore = inRange.len > pageLen)
    var got: seq[string]
    let collect: BackfillDeliver = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): bool =
      got.add(string.fromBytes(message.payload))
      return true
    content[TestTopic] = @[
      rowAt(t0 + Minute, 1),
      rowAt(t0 + 10 * Minute, 2),
      rowAt(t0 + 10 * Minute, 3),
      rowAt(t0 + 20 * Minute, 4),
      rowAt(t0 + 30 * Minute, 5),
      rowAt(t0 + 40 * Minute, 6),
    ]

    # Phase 1: a topic runs to completion page by page. A page continues from
    # the timestamp of the last delivered message.
    check (await fetchAll(TestTopic, t0, t1, query, collect)).get() == 3
    check got.names() == toSeq(1 .. 6).mapIt("msg-" & $it)
    check got.len == 9 # msg-2..4 twice: shared instant, boundary
    check seen[0] == (t0, t1)
    # Phase 2: the range includes the start and excludes the stop. An empty
    # range makes no query.
    got = @[]
    let edges: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      return page(
        @[rowAt(request.startTime.get(), 30), rowAt(request.endTime.get() - 1, 31)]
      )
    check (await fetchAll(TestTopic, t0, t1, edges, collect)).get() == 1
    check got == @["msg-30", "msg-31"]
    calls = 0
    check (await fetchAll(TestTopic, t1, t1, query)).get() == 0 and calls == 0
    # Phase 3: a topic with more pages than one advances page by page. The
    # sixth row sits at `t1`, the exclusive end, so five rows are in range.
    let busy: BackfillTopic = ("/waku/2/rs/3/1", "/backfill/1/busy/proto")
    content[busy] = toSeq(1 .. 6).mapIt(rowAt(t0 + int64(it) * 10 * Minute, it, busy))
    pageSize = 2
    got = @[]
    check (await fetchAll(busy, t0, t1, query, collect)).get() == 4
    check got.names() == toSeq(1 .. 5).mapIt("msg-" & $it)
    check got.count("msg-1") == 1
    # Phase 4: a failure ends the fetch. An error, a timeout, a raising
    # query, a declined delivery, and malformed pages.
    calls = 0
    let failing: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      inc calls
      return err("peer gone")
    check (await fetchAll(TestTopic, t0, t1, failing)).isErr() and calls == 1
    var cancelled = false
    # The stub propagates the cancel; the Store client's `catch:` sites do not,
    # so against a real peer the timeout ends the attempt, not the wait.
    let slow: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      try:
        await sleepAsync(1.hours)
      except CancelledError as e:
        cancelled = true
        raise e
      return page(@[])
    check (
      await fetchAll(TestTopic, t0, t1, slow, queryTimeout = chronos.milliseconds(50))
    ).isErr()
    check cancelled
    let raising: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      raise newException(ValueError, "boom")
    check (await fetchAll(TestTopic, t0, t1, raising)).isErr()
    var offered: seq[string]
    let declineSecond: BackfillDeliver = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): bool =
      offered.add(string.fromBytes(message.payload))
      return offered.len == 1
    let twoRows: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      return page(@[rowAt(t0 + Minute, 20), rowAt(t0 + 2 * Minute, 21)])
    check (await fetchAll(TestTopic, t0, t1, twoRows, declineSecond)).isErr()
    check offered == @["msg-20", "msg-21"]
    # A bad row fails the page. The rows before it stay delivered.
    for scenario in 0 .. 3:
      got = @[]
      let bad: BackfillQuery = proc(
          request: StoreQueryRequest
      ): Future[Result[StoreQueryResponse, string]] {.async.} =
        let good = rowAt(t0 + 30 * Second, 8)
        var row = rowAt(t0 + Minute, 9)
        case scenario
        of 0:
          row.message = Opt.none(WakuMessage)
        of 1:
          row = rowAt(t1, 9) # exactly the exclusive end of the range
        of 2:
          row = rowAt(t0 + 20 * Second, 10) # earlier than the row before it
        else:
          return page(@[rowAt(t0 - Second, 12)]) # before the query start
        return page(@[good, row])
      check (await fetchAll(TestTopic, t0, t1, bad, collect)).isErr()
      check got.len == (if scenario == 3: 0 else: 1)
    let emptyClaimsMore: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      var response = StoreQueryResponse(statusCode: 200)
      response.paginationCursor = Opt.some(rowAt(t0, 1).messageHash)
      return ok(response)
    check (await fetchAll(TestTopic, t0, t1, emptyClaimsMore)).isErr()
    # A failed topic keeps its progress. The next query starts where the last
    # good page ended.
    var pageCalls = 0
    var pageStarts: seq[Timestamp]
    let failsSecondPage: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      inc pageCalls
      let start = request.startTime.get()
      pageStarts.add(start)
      if pageCalls == 2:
        return err("peer gone")
      return page(
        @[rowAt(start + Minute, 40), rowAt(start + 2 * Minute, 41)],
        hasMore = pageCalls == 1,
      )
    let first = await fetchFrom(TestTopic, t0, t1, failsSecondPage)
    check not first.completed and first.next == t0 + 2 * Minute
    let second = await fetchFrom(TestTopic, first.next, t1, failsSecondPage)
    check second.completed and pageStarts == @[t0, t0 + 2 * Minute, t0 + 2 * Minute]
    # A page whose messages all sit at the query start is delivered once, and
    # the next query starts one nanosecond later.
    var starts: seq[Timestamp]
    got = @[]
    let sameInstant: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      starts.add(request.startTime.get())
      if starts.len == 1:
        return page(@[rowAt(t0, 14), rowAt(t0, 15)], hasMore = true)
      return page(@[])
    check (await fetchAll(TestTopic, t0, t1, sameInstant, collect)).get() == 2
    check got == @["msg-14", "msg-15"] and starts == @[t0, t0 + 1]
    # A full last page of 100 rows completes the topic.
    got = @[]
    let fullPage: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      let start = request.startTime.get()
      return page(toSeq(1 .. int(MaxPageSize)).mapIt(rowAt(start + int64(it), it)))
    check (await fetchAll(TestTopic, t0, t1, fullPage, collect)).get() == 1
    check got.len == int(MaxPageSize)

  asyncTest "backfill: a range longer than the Store limit is split into windows":
    let t0 = Base
    let rows =
      @[rowAt(t0 + Hour, 1), rowAt(t0 + 30 * Hour, 2), rowAt(t0 + 49 * Hour, 3)]
    var seen: seq[(Timestamp, Timestamp)]
    let query: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      let (start, stop) = (request.startTime.get(), request.endTime.get())
      seen.add((start, stop))
      if stop - start > MaxQueryTimeRange:
        return err("time range exceeds 24h")
      return page(
        rows.filterIt(
          it.message.get().timestamp >= start and it.message.get().timestamp < stop
        )
      )
    var got: seq[string]
    let collect: BackfillDeliver = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): bool =
      got.add(string.fromBytes(message.payload))
      return true

    check (await fetchAll(TestTopic, t0, t0 + 50 * Hour, query, collect)).get() == 3
    check:
      got == @["msg-1", "msg-2", "msg-3"]
      seen ==
        @[
          (t0, t0 + 24 * Hour),
          (t0 + 24 * Hour, t0 + 48 * Hour),
          (t0 + 48 * Hour, t0 + 50 * Hour),
        ]

  test "topic records: the transitions":
    let now = Base + Hour
    let variance = MaxMessageTimestampVariance
    # A first subscribe is live from the subscribe, or a gap from it when live
    # delivery is in an outage, or when it went down after the subscribe. The
    # bound is below the subscribe by the variance of the timestamps.
    let fresh = newRecord(now, true, Base)
    let freshInOutage = newRecord(now, false, Base)
    let downSince = newRecord(now, true, now + Minute)
    check fresh.timestamp == now - variance and not fresh.timestampToNowIsGap
    check freshInOutage.timestamp == now - variance and freshInOutage.timestampToNowIsGap
    check downSince.timestamp == now - variance and downSince.timestampToNowIsGap
    # An outage detected now started at most `OutageWindow` before. A record
    # with a gap keeps its bound. A bound never goes below the record's own.
    let live = TopicRecord.live(Base)
    let outageLate = live.inOutage(now)
    let outageEarly = live.inOutage(Base + Minute)
    check outageLate.timestamp == now - OutageWindow and outageLate.timestampToNowIsGap
    check outageEarly.timestamp == Base and outageEarly.timestampToNowIsGap
    check TopicRecord.gap(Base).inOutage(now).timestamp == Base
    # A restart is an outage at the time of the last received message.
    let restarted = live.atStart(Opt.some(now))
    check restarted.timestamp == now - OutageWindow and restarted.timestampToNowIsGap
    let noLastReceivedAt = live.atStart(Opt.none(Timestamp))
    check noLastReceivedAt.timestamp == Base and noLastReceivedAt.timestampToNowIsGap
    check TopicRecord.gap(Base).atStart(Opt.some(now)).timestamp == Base
    # The gap of a topic ends when live delivery covers it, after the later
    # of the last recovery and the subscribe, plus `DelayExtra`.
    check coveredFrom(Base, now) == now + DelayExtra + variance
    check coveredFrom(now, Base) == now + DelayExtra + variance
    # The archive has every message from before this time.
    check archivedBefore(now) == now - variance - ArchiveTime

  asyncTest "topic records: the codec, the writes and the deletes":
    let root = createTempDir("recv-records-", "")
    defer:
      removeDir(root)
    let persistency = Persistency.new(root).get()
    defer:
      persistency.close()
    let job = persistency.openJob(MessagingJobId).get()
    var stored = (await job.readTopicRecords()).get()
    check stored.len == 0
    let liveRecord = TopicRecord.live(Base)
    let gapRecord = TopicRecord.gap(Base + Hour)
    let liveOp = topicRecordOp(TestTopic, liveRecord)[0]
    let gapOp = topicRecordOp(OtherTopic, gapRecord)[0]
    await job.writeTopicRecords(@[liveOp, gapOp])
    await job.waitStored(BackfillCategory, gapOp.key, gapOp.payload)
    stored = (await job.readTopicRecords()).get()
    let byTopic = stored.toTable()
    check byTopic.len == 2
    check byTopic.getOrDefault(TestTopic) == liveRecord
    check byTopic.getOrDefault(OtherTopic) == gapRecord
    # A record that does not decode is left out, so its topic is new.
    let badTopic: BackfillTopic = ("/waku/2/rs/3/0", "/backfill/1/bad/proto")
    let badKey = topicRecordOp(badTopic, liveRecord)[0].key
    let badRecord = @[0x08'u8, 0x00]
    await job.persistPut(BackfillCategory, badKey, badRecord)
    await job.waitStored(BackfillCategory, badKey, badRecord)
    stored = (await job.readTopicRecords()).get()
    check stored.len == 2
    # An unsubscribe deletes the record.
    await job.writeTopicRecords(deleteTopicRecordOp(TestTopic))
    checkUntilTimeoutCustom(2.seconds, 10.milliseconds):
      (await job.readTopicRecords()).get().len == 1
    stored = (await job.readTopicRecords()).get()
    check stored[0][0] == OtherTopic
    # A start with the restart backfill off deletes the records and the time.
    await job.writeLastReceivedAt(Base)
    await job.waitLastReceivedAt(Opt.some(Base))
    await job.clearBackfillState()
    checkUntilTimeoutCustom(2.seconds, 10.milliseconds):
      (await job.readTopicRecords()).get().len == 0
      (await job.readLastReceivedAt()).get().isNone()
    # A topic whose names are too long for a key has no record.
    let longName = 'x'.repeat(StringLenMax + 1)
    let tooLong: BackfillTopic = ("/waku/2/rs/3/0", longName)
    check topicRecordOp(tooLong, liveRecord).len == 0
    check deleteTopicRecordOp(tooLong).len == 0

  test "settings: defaults, range checks, JSON":
    let defaults = BackfillState.init(MessagingClientConf()).get()
    check defaults.enabled and defaults.queryTimeout == chronos.seconds(10)
    let custom = BackfillState
      .init(
        MessagingClientConf(
          backfillEnabled: Opt.some(false),
          backfillRequestTimeoutSeconds: Opt.some(300'i64),
        )
      )
      .get()
    check not custom.enabled and custom.queryTimeout == chronos.minutes(5)
    for bad in [
      MessagingClientConf(backfillRequestTimeoutSeconds: Opt.some(0'i64)),
      MessagingClientConf(backfillRequestTimeoutSeconds: Opt.some(301'i64)),
    ]:
      check BackfillState.init(bad).isErr()
    let parsed = parseLogosDeliveryConf(
      """{"messagingOverrides": {"backfill-enabled": false,
           "backfillRequestTimeoutSeconds": 7}}"""
    ).valueOr:
      raiseAssert error
    let messagingConf = parsed.messagingConf.get()
    check messagingConf.backfillEnabled == Opt.some(false)
    check messagingConf.backfillRequestTimeoutSeconds == Opt.some(7'i64)
    check parseLogosDeliveryConf(
      """{"messagingOverrides": {"backfillRequestTimeoutSeconds": "many"}}"""
    )
      .isErr()

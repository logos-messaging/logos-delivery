{.used.}

## Few multi-phase cases. Each `test` block costs three GC-tracked globals, and
## the refc runtime caps the waku test binary at 3500.

import std/[os, osproc, tempfiles, sequtils, strutils, tables]
import chronos, results, testutils/unittests
import stew/byteutils

import logos_delivery/messaging/delivery_service/recv_service/backfill
import logos_delivery/messaging/delivery_service/recv_service/recv_service
import logos_delivery/api/conf/messaging_conf
import logos_delivery/api/conf/logos_delivery_conf_json
import logos_delivery/waku/[waku_core, waku_store/common]
import logos_delivery/waku/persistency/persistency

const
  Base = 1_700_000_000_000_000_000'i64 ## 2023-11-14
  Hour = chronos.hours(1).nanos
  Minute = chronos.minutes(1).nanos
  Second = chronos.seconds(1).nanos
  Overlap = BackfillOverlap.nanos
  TestTopic: BackfillTopic = ("/waku/2/rs/3/0", "/backfill/1/restart/proto")
  OtherTopic: BackfillTopic = ("/waku/2/rs/3/0", "/backfill/1/other/proto")
  BackfillCategory = "recv.backfill.v1"

proc rowAt(timestamp: Timestamp, index: int, topic = TestTopic): WakuMessageKeyValue =
  let message = WakuMessage(
    payload: ("msg-" & $index).toBytes(),
    contentTopic: topic.contentTopic,
    timestamp: timestamp,
  )
  WakuMessageKeyValue(
    messageHash: computeMessageHash(topic.pubsubTopic, message),
    message: Opt.some(message),
    pubsubTopic: Opt.some(topic.pubsubTopic),
  )

proc page(
    rows: seq[WakuMessageKeyValue], hasMore = false
): Result[StoreQueryResponse, string] =
  ## `hasMore` sets the cursor, as a Store does when the range holds more than one page.
  let cursor =
    if hasMore and rows.len > 0:
      Opt.some(rows[^1].messageHash)
    else:
      Opt.none(WakuMessageHash)
  ok(StoreQueryResponse(statusCode: 200, messages: rows, paginationCursor: cursor))

proc emptyQuery(
    request: StoreQueryRequest
): Future[Result[StoreQueryResponse, string]] {.async.} =
  return page(@[])

proc accept(pubsubTopic: PubsubTopic, message: WakuMessage): bool =
  true

proc cycle(
    job: Job,
    topics: seq[BackfillTopic],
    cycleStart: Timestamp,
    query: BackfillQuery,
    maxQueries = 10,
    maxLookback = chronos.hours(24),
    queryTimeout = chronos.seconds(10),
    firstTopicIndex = 0,
    deliver: BackfillDeliver = accept,
    fallbackStart = Base,
): Future[BackfillCycleOutcome] {.async.} =
  return await job.runCycle(
    topics, cycleStart, fallbackStart, firstTopicIndex, maxLookback, maxQueries,
    queryTimeout, query, deliver,
  )

proc resumeAt(job: Job, topic: BackfillTopic): Future[Timestamp] {.async.} =
  return (await job.readResumeAt(topic)).get().get()

proc waitStored(
    job: Job, category: string, recordKey: Key, expected: seq[byte]
) {.async.} =
  let deadline = Moment.now() + 2.seconds
  while (await job.get(category, recordKey)).get() != Opt.some(expected):
    doAssert Moment.now() < deadline
    await sleepAsync(10.milliseconds)

proc names(payloads: openArray[string]): seq[string] =
  payloads.deduplicate()

proc processSession(root: string, recover: bool) {.async.} =
  ## Two processes on one disk root. The first stops after one page and records
  ## the timestamp of its last message. The second resumes from that timestamp.
  let p = Persistency.new(root).expect("open Persistency in child")
  let job = p.openJob(BackfillJobId).expect("open receive job")
  let t0 = Base
  let t1 = Base + Hour
  let t2 = Base + 2 * Hour
  if not recover:
    (await job.seedTopic(TestTopic, t0)).expect("seed")
    doAssert (await job.resumeAt(TestTopic)) == t0
    let first = rowAt(t0 + Minute, 1)
    let query: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      doAssert request.startTime.get() == t0 and request.endTime.get() == t1 - 1
      doAssert request.paginationCursor.isNone()
      return page(@[first], hasMore = true)
    let outcome = await job.cycle(@[TestTopic], t1, query, maxQueries = 1)
    doAssert outcome.queries == 1 and outcome.completed == 0 and outcome.failed == 0,
      $outcome
    doAssert (await job.resumeAt(TestTopic)) == t0 + Minute
    # No p.close(). Confirmed records must survive process exit.
  else:
    doAssert (await job.resumeAt(TestTopic)) == t0 + Minute
    var seenStart = Timestamp(0)
    let query: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      seenStart = request.startTime.get()
      doAssert request.paginationCursor.isNone()
      return page(@[rowAt(t0 + 2 * Minute, 2)])
    let outcome = await job.cycle(@[TestTopic], t2, query, maxQueries = 1)
    doAssert outcome.completed == 1, $outcome
    doAssert seenStart == t0 + Minute
    doAssert (await job.resumeAt(TestTopic)) == t2 - Overlap
    let again = p.openJob(BackfillJobId).get()
    doAssert (await again.resumeAt(TestTopic)) == t2 - Overlap

if paramCount() == 2 and paramStr(1) in ["--backfill-seed", "--backfill-recover"]:
  waitFor processSession(paramStr(2), paramStr(1) == "--backfill-recover")
  quit(QuitSuccess)

suite "Receive backfill across sessions":
  test "a separate process resumes from the recorded timestamp":
    let root = createTempDir("recv-backfill-process-", "")
    defer:
      removeDir(root)
    for mode in ["--backfill-seed", "--backfill-recover"]:
      let child = startProcess(
        getAppFilename(), args = @[mode, root], options = {poParentStreams}
      )
      check child.waitForExit(30_000) == 0
      child.close()

  asyncTest "cycles: budget, fairness, resumption, overlap, lookback, progress, failures":
    let p = Persistency.new(InMemoryStoragePath).get()
    defer:
      p.close()
    let job = p.openJob(BackfillJobId).get()
    let t0 = Base
    let t1 = Base + Hour
    # The fake Store applies the time bounds, answers one page in forward
    # order, and sets a cursor only when the range holds more. Six rows per
    # topic in the first hour, two at the same instant, three per page. A
    # query from a shared timestamp returns that row again. Duplicates, never
    # a skipped message.
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
      let all = content.getOrDefault(topic).filterIt(
          it.message.get().timestamp >= request.startTime.get() and
            it.message.get().timestamp <= request.endTime.get()
        )
      let n = min(all.len, pageSize)
      return page(all[0 ..< n], hasMore = all.len > n)
    var delivered: Table[BackfillTopic, seq[string]]
    let deliver: BackfillDeliver = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): bool =
      let topic: BackfillTopic = (pubsubTopic, message.contentTopic)
      delivered.mgetOrPut(topic, @[]).add(string.fromBytes(message.payload))
      true
    let topics = @[TestTopic, OtherTopic]
    for topic in topics:
      content[topic] = @[
        rowAt(t0 + Minute, 1, topic),
        rowAt(t0 + 10 * Minute, 2, topic),
        rowAt(t0 + 10 * Minute, 3, topic),
        rowAt(t0 + 20 * Minute, 4, topic),
        rowAt(t0 + 30 * Minute, 5, topic),
        rowAt(t0 + 40 * Minute, 6, topic),
      ]
      check (await job.seedTopic(topic, t0)).isOk()
    # A seed does not move an existing record.
    check (await job.seedTopic(TestTopic, t1)).isOk()
    check (await job.resumeAt(TestTopic)) == t0

    # Phase 1: five queries go round-robin A, B, A, B, A. A's third page is
    # its last. B resumes later from its last delivered timestamp.
    var outcome = await job.cycle(topics, t1, query, maxQueries = 5, deliver = deliver)
    check outcome.queries == 5 and outcome.completed == 1 and outcome.failed == 0
    check delivered[TestTopic].names() == toSeq(1 .. 6).mapIt("msg-" & $it)
    check delivered[TestTopic].len == 9 # msg-2..4 twice: shared instant, boundary
    check delivered[OtherTopic].names() == toSeq(1 .. 4).mapIt("msg-" & $it)
    check (await job.resumeAt(TestTopic)) == t1 - Overlap
    check (await job.resumeAt(OtherTopic)) == t0 + 20 * Minute
    # Phase 2: the next cycle starts at B and resumes it from its timestamp.
    # A queries only its overlap, which is empty.
    outcome = await job.cycle(
      topics, t1, query, maxQueries = 5, firstTopicIndex = 1, deliver = deliver
    )
    check outcome.queries == 2 and outcome.completed == 2
    check delivered[OtherTopic].names() == toSeq(1 .. 6).mapIt("msg-" & $it)
    for topic in topics:
      check (await job.resumeAt(topic)) == t1 - Overlap
    # Phase 3: the overlap delivers a message that reached Store late.
    let t2 = t1 + Hour
    content[TestTopic].add(rowAt(t1 - 2 * Second, 7))
    seen = @[]
    outcome = await job.cycle(@[TestTopic], t2, query, deliver = deliver)
    check outcome.completed == 1 and seen == @[(t1 - Overlap, t2 - 1)]
    check delivered[TestTopic][^1] == "msg-7"
    check (await job.resumeAt(TestTopic)) == t2 - Overlap
    # Phase 4: the lookback clips a record 900 days old. The record moves past
    # the skipped history.
    let third: BackfillTopic = ("/waku/2/rs/3/1", "/backfill/1/third/proto")
    check (await job.seedTopic(third, Base - 900 * 24 * Hour)).isOk()
    seen = @[]
    outcome = await job.cycle(@[third], t2, query, maxLookback = chronos.hours(24))
    check outcome.completed == 1 and seen == @[(t2 - 24 * Hour, t2 - 1)]
    check (await job.resumeAt(third)) == t2 - Overlap
    # Phase 5: a topic with more history than one budget advances every cycle
    # to its last delivered timestamp, at any position of the window.
    let busy: BackfillTopic = ("/waku/2/rs/3/1", "/backfill/1/busy/proto")
    content[busy] = toSeq(1 .. 6).mapIt(rowAt(t2 + int64(it) * 10 * Minute, it, busy))
    pageSize = 2
    check (await job.seedTopic(busy, t2)).isOk()
    var got: seq[string]
    let collect: BackfillDeliver = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): bool =
      got.add(string.fromBytes(message.payload))
      true
    var cycles = 0
    var completed = 0
    while completed == 0 and cycles < 8:
      inc cycles
      outcome = await job.cycle(
        @[busy],
        t2 + 70 * Minute + int64(cycles) * 5 * Minute,
        query,
        maxQueries = 1,
        maxLookback = chronos.hours(2),
        deliver = collect,
      )
      completed += outcome.completed
    check cycles == 5
    check got.names() == toSeq(1 .. 6).mapIt("msg-" & $it)
    check got.count("msg-1") == 1
    # Phase 6: a failure does not move the timestamp and costs one query per
    # topic per cycle. An error, a timeout, a raising query, a declined
    # delivery, and malformed pages.
    let t3 = t2 + Hour
    let before = await job.resumeAt(TestTopic)
    calls = 0
    let failing: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      inc calls
      return err("peer gone")
    outcome = await job.cycle(topics, t3, failing, maxQueries = 6)
    check outcome.queries == 2 and outcome.failed == 2 and calls == 2
    check (await job.resumeAt(TestTopic)) == before
    var cancelled = false
    let slow: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      try:
        await sleepAsync(1.hours)
      except CancelledError as e:
        cancelled = true
        raise e
      return page(@[])
    outcome = await job.cycle(
      @[TestTopic], t3, slow, maxQueries = 3, queryTimeout = chronos.milliseconds(50)
    )
    check outcome.queries == 1 and outcome.failed == 1 and cancelled
    let raising: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      raise newException(ValueError, "boom")
    outcome = await job.cycle(@[TestTopic], t3, raising, maxQueries = 3)
    check outcome.queries == 1 and outcome.failed == 1
    check (await job.resumeAt(TestTopic)) == before
    # A page declined midway does not move the record.
    var offered: seq[string]
    let declineSecond: BackfillDeliver = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): bool =
      offered.add(string.fromBytes(message.payload))
      offered.len == 1
    let twoRows: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      return page(@[rowAt(t2 + Minute, 20), rowAt(t2 + 2 * Minute, 21)])
    outcome = await job.cycle(
      @[TestTopic], t3, twoRows, maxQueries = 3, deliver = declineSecond
    )
    check outcome.queries == 1 and outcome.failed == 1
    check offered == @["msg-20", "msg-21"] and (await job.resumeAt(TestTopic)) == before
    # A malformed page delivers nothing, its valid rows included.
    for scenario in 0 .. 10:
      var count = 0
      got = @[]
      let bad: BackfillQuery = proc(
          request: StoreQueryRequest
      ): Future[Result[StoreQueryResponse, string]] {.async.} =
        inc count
        let good = rowAt(t2 + 30 * Second, 8)
        var row = rowAt(t2 + Minute, 9)
        var response = StoreQueryResponse(statusCode: 200)
        case scenario
        of 0:
          response.statusCode = 503
        of 1:
          row.message = Opt.none(WakuMessage)
        of 2:
          row.pubsubTopic = Opt.some(PubsubTopic("wrong-shard"))
        of 3:
          row = rowAt(t3, 9) # exactly the exclusive end of the range
        of 4:
          row.messageHash[0] = row.messageHash[0] xor 0xff
        of 5:
          row = rowAt(t2 + 20 * Second, 10) # earlier than the row before it
        of 6:
          # One timestamp equal to the query start, with more to come. The
          # cycle delivers the row, then rejects the page as no progress.
          return page(@[rowAt(before, 11)], hasMore = true)
        of 7:
          response.paginationCursor = Opt.some(row.messageHash) # empty, claims more
          return ok(response)
        of 8:
          row = rowAt(t2 + Minute, 9, OtherTopic) # right shard, other topic
        of 9:
          response.messages =
            toSeq(1 .. int(MaxPageSize) + 1).mapIt(rowAt(t2 + int64(it) * Second, it))
          return ok(response)
        else:
          return page(@[rowAt(before - Second, 12)]) # before the query start
        response.messages = @[good, row]
        return ok(response)
      outcome =
        await job.cycle(@[TestTopic], t3, bad, maxQueries = 3, deliver = collect)
      check outcome.failed == 1 and outcome.queries == 1 and count == 1
      check got.len == (if scenario == 6: 1 else: 0)
      check (await job.resumeAt(TestTopic)) == before
    # Phase 7: exact range bounds, a full last page, an exhausted range, no
    # topics, a record ahead of the cycle, an over-long topic name.
    got = @[]
    let edges: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      return
        page(@[rowAt(request.startTime.get(), 30), rowAt(request.endTime.get(), 31)])
    outcome = await job.cycle(@[TestTopic], t3, edges, deliver = collect)
    check outcome.completed == 1 and got == @["msg-30", "msg-31"]
    check (await job.resumeAt(TestTopic)) == t3 - Overlap
    got = @[]
    let t4 = t3 + Minute
    let fullPage: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      let start = request.startTime.get()
      return page(toSeq(1 .. int(MaxPageSize)).mapIt(rowAt(start + int64(it), it)))
    outcome = await job.cycle(@[TestTopic], t4, fullPage, deliver = collect)
    check outcome.completed == 1 and got.len == int(MaxPageSize)
    check (await job.resumeAt(TestTopic)) == t4 - Overlap
    let t5 = t4 + Minute
    outcome = await job.cycle(@[TestTopic], t5, emptyQuery)
    check outcome.completed == 1 and (await job.resumeAt(TestTopic)) == t5 - Overlap
    outcome = await job.cycle(@[], t5, emptyQuery)
    check outcome == BackfillCycleOutcome()
    let ahead: BackfillTopic = ("/waku/2/rs/3/1", "/backfill/1/ahead/proto")
    check (await job.seedTopic(ahead, t5 + Hour)).isOk()
    outcome = await job.cycle(@[ahead], t5, emptyQuery)
    check outcome == BackfillCycleOutcome() and (await job.resumeAt(ahead)) == t5 + Hour
    let huge: BackfillTopic = (TestTopic.pubsubTopic, ContentTopic('x'.repeat(70_000)))
    outcome = await job.cycle(@[huge, TestTopic], t5 + Minute, emptyQuery)
    check outcome.queries == 1 and outcome.completed == 1 and not outcome.storageFailed

  asyncTest "storage faults and configuration: closed job, lost write, absent rows, JSON":
    # Phase 1: a closed job records nothing and asks nothing of Store.
    block:
      let p = Persistency.new(InMemoryStoragePath).get()
      let job = p.openJob(BackfillJobId).get()
      p.close()
      check (await job.seedTopic(TestTopic, Base)).isErr()
      var calls = 0
      let query: BackfillQuery = proc(
          request: StoreQueryRequest
      ): Future[Result[StoreQueryResponse, string]] {.async.} =
        inc calls
        return page(@[])
      let outcome = await job.cycle(@[TestTopic], Base + Hour, query)
      check outcome.storageFailed and outcome.queries == 0 and calls == 0
    # Phase 2: an unconfirmed write stops the cycle at once, for any budget.
    block:
      let p = Persistency.new(InMemoryStoragePath).get()
      defer:
        p.close()
      let job = p.openJob(BackfillJobId).get()
      check (await job.seedTopic(TestTopic, Base)).isOk()
      check (await job.seedTopic(OtherTopic, Base)).isOk()
      var calls = 0
      let query: BackfillQuery = proc(
          request: StoreQueryRequest
      ): Future[Result[StoreQueryResponse, string]] {.async.} =
        inc calls
        p.closeJob(BackfillJobId) # storage goes away under the cycle
        let topic: BackfillTopic = (request.pubsubTopic.get(), request.contentTopics[0])
        return page(@[rowAt(Base + Minute, 1, topic)])
      let outcome =
        await job.cycle(@[TestTopic, OtherTopic], Base + Hour, query, maxQueries = 6)
      check outcome.storageFailed and outcome.queries == 1 and calls == 1
    # Phase 3: a topic without a record, or with an unreadable one, gets a
    # record at the fallback start before its first query. A failed query
    # keeps that record.
    block:
      let p = Persistency.new(InMemoryStoragePath).get()
      defer:
        p.close()
      let job = p.openJob(BackfillJobId).get()
      let k = key(TestTopic.pubsubTopic, TestTopic.contentTopic)
      let zero = @[0x08'u8, 0x00] # field 1 = 0: not a timestamp
      await job.persistPut(BackfillCategory, k, zero)
      await job.waitStored(BackfillCategory, k, zero)
      check (await job.readResumeAt(TestTopic)).get().isNone()
      let wide = @[0x08'u8, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]
      await job.persistPut(BackfillCategory, k, wide)
      await job.waitStored(BackfillCategory, k, wide)
      check (await job.readResumeAt(TestTopic)).get().isNone()
      let bad = @[0xff'u8, 0x01, 0x02]
      await job.persistPut(BackfillCategory, k, bad)
      await job.waitStored(BackfillCategory, k, bad)
      check (await job.readResumeAt(TestTopic)).get().isNone()
      check (await job.seedTopic(TestTopic, 0)).isErr()
      check (await job.seedTopic(OtherTopic, Base)).isOk()
      let third: BackfillTopic = ("/waku/2/rs/3/1", "/backfill/1/third/proto")
      var seen: seq[Timestamp]
      let query: BackfillQuery = proc(
          request: StoreQueryRequest
      ): Future[Result[StoreQueryResponse, string]] {.async.} =
        seen.add(request.startTime.get())
        return page(@[])
      let now = Base + Hour
      let earlier = Base - Minute
      let outcome = await job.cycle(
        @[TestTopic, OtherTopic, third], now, query, fallbackStart = earlier
      )
      check outcome.completed == 3 and seen == @[earlier, Base, earlier]
      for topic in [TestTopic, OtherTopic, third]:
        check (await job.resumeAt(topic)) == now - Overlap
      let fourth: BackfillTopic = ("/waku/2/rs/3/1", "/backfill/1/fourth/proto")
      let failing: BackfillQuery = proc(
          request: StoreQueryRequest
      ): Future[Result[StoreQueryResponse, string]] {.async.} =
        return err("store down")
      discard await job.cycle(@[fourth], now, failing, fallbackStart = earlier)
      check (await job.resumeAt(fourth)) == earlier
    # Phase 4: settings. Defaults, range checks, and JSON by field or switch name.
    block:
      let defaults = BackfillState.init(MessagingClientConf()).get()
      check defaults.enabled and defaults.maxLookback == chronos.hours(24)
      check defaults.interval == chronos.minutes(5) and defaults.maxQueries == 10
      check defaults.queryTimeout == chronos.seconds(10)
      let custom = BackfillState
        .init(
          MessagingClientConf(
            backfillEnabled: Opt.some(false),
            backfillMaxLookbackSeconds: Opt.some(60'i64),
            backfillIntervalSeconds: Opt.some(3600'i64),
            backfillMaxPagesPerCycle: Opt.some(1000),
            backfillRequestTimeoutSeconds: Opt.some(300'i64),
          )
        )
        .get()
      check not custom.enabled and custom.maxLookback == chronos.minutes(1)
      check custom.interval == chronos.hours(1) and custom.maxQueries == 1000
      check custom.queryTimeout == chronos.minutes(5)
      for bad in [
        MessagingClientConf(backfillMaxLookbackSeconds: Opt.some(0'i64)),
        MessagingClientConf(backfillIntervalSeconds: Opt.some(-1'i64)),
        MessagingClientConf(backfillMaxLookbackSeconds: Opt.some(int64.high)),
        MessagingClientConf(backfillMaxPagesPerCycle: Opt.some(0)),
        MessagingClientConf(backfillMaxPagesPerCycle: Opt.some(1001)),
        MessagingClientConf(backfillRequestTimeoutSeconds: Opt.some(301'i64)),
      ]:
        check BackfillState.init(bad).isErr()
      let lc = parseLogosDeliveryConf(
        """{"messagingOverrides": {"backfill-max-pages-per-cycle": 3,
             "backfillEnabled": false, "backfillIntervalSeconds": 7}}"""
      ).valueOr:
        raiseAssert error
      let mc = lc.messagingConf.get()
      check mc.backfillEnabled == Opt.some(false)
      check mc.backfillMaxPagesPerCycle == Opt.some(3)
      check mc.backfillIntervalSeconds == Opt.some(7'i64)
      check mc.backfillMaxLookbackSeconds.isNone()
      check parseLogosDeliveryConf(
        """{"messagingOverrides": {"backfillMaxLookbackSeconds": "many"}}"""
      )
        .isErr()
    # Phase 5: a topic entering the subscription set makes a cycle due at once.
    block:
      check newlySubscribed(@[TestTopic], @[TestTopic, OtherTopic]) == @[OtherTopic]
      check newlySubscribed(@[TestTopic], @[]).len == 0
      check newlySubscribed(@[], @[TestTopic]) == @[TestTopic]
      check newlySubscribed(@[TestTopic, OtherTopic], @[TestTopic]).len == 0
      check newlySubscribed(@[TestTopic], @[TestTopic]).len == 0

{.used.}

## Few multi-phase cases. Each `test` block costs three GC-tracked globals, and
## the refc runtime caps the test binary at 3500.

import std/[os, tempfiles, sequtils, tables]
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

proc catchUp(
    topics: seq[BackfillTopic],
    since, now: Timestamp,
    query: BackfillQuery,
    deliver: BackfillDeliver = accept,
    queryTimeout = chronos.seconds(10),
): Future[BackfillOutcome] {.async.} =
  return await runCatchUp(topics, since, now, queryTimeout, query, deliver)

proc waitStored(
    job: Job, category: string, recordKey: Key, expected: seq[byte]
) {.async.} =
  let deadline = Moment.now() + 2.seconds
  while (await job.get(category, recordKey)).get() != Opt.some(expected):
    doAssert Moment.now() < deadline
    await sleepAsync(10.milliseconds)

proc waitLastOnline(job: Job, expected: Opt[Timestamp]) {.async.} =
  ## Writes are fire-and-forget. Waits until the record reads as `expected`.
  let deadline = Moment.now() + 2.seconds
  while (await job.readLastOnline()).get() != expected:
    doAssert Moment.now() < deadline
    await sleepAsync(10.milliseconds)

proc names(payloads: openArray[string]): seq[string] =
  payloads.deduplicate()

suite "Receive backfill":
  asyncTest "the last-online timestamp survives a Persistency reopen; bad records count as none":
    let root = createTempDir("recv-backfill-", "")
    defer:
      removeDir(root)
    block:
      let p = Persistency.new(root).get()
      let job = p.openJob(BackfillJobId).get()
      check (await job.readLastOnline()).get().isNone()
      await job.writeLastOnline(Base)
      await job.waitLastOnline(Opt.some(Base))
      p.close()
    block:
      let p = Persistency.new(root).get()
      defer:
        p.close()
      let job = p.openJob(BackfillJobId).get()
      check (await job.readLastOnline()).get() == Opt.some(Base)
      let k = key("last-online")
      for bad in [
        @[0x08'u8, 0x00],
        @[0xff'u8, 0x01, 0x02],
        @[0x08'u8, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01],
      ]:
        await job.persistPut(BackfillCategory, k, bad)
        await job.waitStored(BackfillCategory, k, bad)
        check (await job.readLastOnline()).get().isNone()
      await job.writeLastOnline(Base + Hour)
      await job.waitLastOnline(Opt.some(Base + Hour))
      p.closeJob(BackfillJobId)
      check (await job.readLastOnline()).isErr()

  asyncTest "catch-up: topics in order, page progress, range bounds, failures":
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

    # Phase 1: both topics run to completion, one after the other. A page
    # continues from the timestamp of the last delivered message.
    var outcome = await catchUp(topics, t0, t1, query, deliver)
    check outcome.queries == 6 and outcome.failed == 0
    check outcome.completedTopics == topics
    for topic in topics:
      check delivered[topic].names() == toSeq(1 .. 6).mapIt("msg-" & $it)
      check delivered[topic].len == 9 # msg-2..4 twice: shared instant, boundary
    check seen[0] == (t0, t1 - 1)
    # Phase 2: the range includes `since` and excludes `now`. A topic whose
    # start is at or past `now` needs no query.
    var got: seq[string]
    let collect: BackfillDeliver = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): bool =
      got.add(string.fromBytes(message.payload))
      true
    let edges: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      return
        page(@[rowAt(request.startTime.get(), 30), rowAt(request.endTime.get(), 31)])
    outcome = await catchUp(@[TestTopic], t0, t1, edges, collect)
    check outcome.completedTopics == @[TestTopic] and got == @["msg-30", "msg-31"]
    outcome = await catchUp(@[TestTopic], t1, t1, emptyQuery)
    check outcome.queries == 0 and outcome.completedTopics == @[TestTopic]
    # Phase 3: a topic with more pages than one advances page by page. The
    # sixth row sits at `t1`, the exclusive end, so five rows are in range.
    let busy: BackfillTopic = ("/waku/2/rs/3/1", "/backfill/1/busy/proto")
    content[busy] = toSeq(1 .. 6).mapIt(rowAt(t0 + int64(it) * 10 * Minute, it, busy))
    pageSize = 2
    got = @[]
    outcome = await catchUp(@[busy], t0, t1, query, collect)
    check outcome.queries == 4 and outcome.completedTopics == @[busy]
    check got.names() == toSeq(1 .. 5).mapIt("msg-" & $it)
    check got.count("msg-1") == 1
    # Phase 4: a failure ends the topic for this catch-up and completes
    # nothing. An error, a timeout, a raising query, a declined delivery,
    # and malformed pages.
    calls = 0
    let failing: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      inc calls
      return err("peer gone")
    outcome = await catchUp(topics, t0, t1, failing)
    check outcome.queries == 2 and outcome.failed == 2 and calls == 2
    check outcome.completedTopics.len == 0
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
    outcome =
      await catchUp(@[TestTopic], t0, t1, slow, queryTimeout = chronos.milliseconds(50))
    check outcome.queries == 1 and outcome.failed == 1 and cancelled
    let raising: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      raise newException(ValueError, "boom")
    outcome = await catchUp(@[TestTopic], t0, t1, raising)
    check outcome.queries == 1 and outcome.failed == 1
    var offered: seq[string]
    let declineSecond: BackfillDeliver = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): bool =
      offered.add(string.fromBytes(message.payload))
      offered.len == 1
    let twoRows: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      return page(@[rowAt(t0 + Minute, 20), rowAt(t0 + 2 * Minute, 21)])
    outcome = await catchUp(@[TestTopic], t0, t1, twoRows, declineSecond)
    check outcome.queries == 1 and outcome.failed == 1
    check offered == @["msg-20", "msg-21"]
    # A row that cannot be used ends the page and fails the topic. The rows
    # before it are delivered.
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
      outcome = await catchUp(@[TestTopic], t0, t1, bad, collect)
      check outcome.failed == 1 and outcome.queries == 1
      check got.len == (if scenario == 3: 0 else: 1)
    let emptyClaimsMore: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      var response = StoreQueryResponse(statusCode: 200)
      response.paginationCursor = Opt.some(rowAt(t0, 1).messageHash)
      return ok(response)
    outcome = await catchUp(@[TestTopic], t0, t1, emptyClaimsMore)
    check outcome.failed == 1 and outcome.queries == 1
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
    outcome = await catchUp(@[TestTopic], t0, t1, sameInstant, collect)
    check outcome.completedTopics == @[TestTopic] and outcome.queries == 2
    check got == @["msg-14", "msg-15"] and starts == @[t0, t0 + 1]
    # A full last page of 100 rows completes the topic.
    got = @[]
    let fullPage: BackfillQuery = proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      let start = request.startTime.get()
      return page(toSeq(1 .. int(MaxPageSize)).mapIt(rowAt(start + int64(it), it)))
    outcome = await catchUp(@[TestTopic], t0, t1, fullPage, collect)
    check outcome.completedTopics == @[TestTopic] and got.len == int(MaxPageSize)

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
    let lc = parseLogosDeliveryConf(
      """{"messagingOverrides": {"backfill-enabled": false,
           "backfillRequestTimeoutSeconds": 7}}"""
    ).valueOr:
      raiseAssert error
    let mc = lc.messagingConf.get()
    check mc.backfillEnabled == Opt.some(false)
    check mc.backfillRequestTimeoutSeconds == Opt.some(7'i64)
    check parseLogosDeliveryConf(
      """{"messagingOverrides": {"backfillRequestTimeoutSeconds": "many"}}"""
    )
      .isErr()

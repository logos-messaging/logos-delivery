{.used.}

## Few multi-phase cases, because refc caps the test binary at 3500 GC-tracked globals.

import
  std/[algorithm, sequtils, strutils, tables],
  chronos,
  results,
  testutils/unittests,
  stew/byteutils,
  brokers/broker_context
import
  ../testlib/[testasync, history_query_events],
  logos_delivery/api/types,
  logos_delivery/messaging/delivery_service/history_query_service,
  logos_delivery/messaging/delivery_service/recv_service/backfill,
  logos_delivery/waku/[waku_core, waku_store/common]

const
  ShardA = PubsubTopic("/waku/2/rs/3/0")
  ShardB = PubsubTopic("/waku/2/rs/3/1")
  Topic = ContentTopic("/history-query/1/chat/proto")
  OtherTopic = ContentTopic("/history-query/1/other/proto")
  Minute = chronos.minutes(1).nanos
  Second = chronos.seconds(1).nanos
  Millisecond = chronos.milliseconds(1).nanos
  WaitTimeout = chronos.seconds(5)

type FakeStore = ref object
  ## A fake Store that answers one forward page of the time range of a request.
  ## It sets a cursor when the range has more rows.
  rows: Table[(PubsubTopic, ContentTopic), seq[WakuMessageKeyValue]]
  pageSize: int
  calls: int
  failures: int ## the number of requests that fail before the next success
  failuresPerPage: int ## the value of `failures` after each success
  cancelled: int ## the requests that got a cancel while they waited for `reply`
  ignoreCancel: bool ## a cancelled request catches the cancel and answers
  otherTopicFirst: bool ## each page starts with a message of `OtherTopic`
  reply: AsyncEvent ## when not nil, each request waits for it
  delay: Duration ## each request waits this long before it answers
  inFlight: int ## the requests that did not answer yet
  maxInFlight: int ## the most requests in flight at the same time
  late: seq[(PubsubTopic, WakuMessage)]
    ## rows that the archive gets after the first request
  badRowOnce: bool ## the next page ends with a row out of order, one time

proc msgAt(at: Timestamp, text: string, topic = Topic): WakuMessage =
  return WakuMessage(payload: text.toBytes(), contentTopic: topic, timestamp: at)

proc put(store: FakeStore, shard: PubsubTopic, message: WakuMessage) =
  let row = WakuMessageKeyValue(
    messageHash: computeMessageHash(shard, message),
    message: Opt.some(message),
    pubsubTopic: Opt.some(shard),
  )
  var rows = store.rows.getOrDefault((shard, message.contentTopic))
  rows.add(row)
  rows.sort(
    proc(a, b: WakuMessageKeyValue): int =
      cmp(a.message.get().timestamp, b.message.get().timestamp)
  )
  store.rows[(shard, message.contentTopic)] = rows

proc queryToAny(store: FakeStore): BackfillQuery =
  return proc(
      request: StoreQueryRequest
  ): Future[Result[StoreQueryResponse, string]] {.async.} =
    inc store.calls
    inc store.inFlight
    store.maxInFlight = max(store.maxInFlight, store.inFlight)
    defer:
      dec store.inFlight
    if store.delay > ZeroDuration:
      await sleepAsync(store.delay)
    if not store.reply.isNil():
      try:
        await store.reply.wait()
      except CancelledError as e:
        inc store.cancelled
        if not store.ignoreCancel:
          raise e
    if store.failures > 0:
      dec store.failures
      return err("the store is not available")
    store.failures = store.failuresPerPage
    let shard = request.pubsubTopic.get()
    let start = request.startTime.get()
    let stop = request.endTime.get()
    var inRange = store.rows.getOrDefault((shard, request.contentTopics[0])).filterIt(
        it.message.get().timestamp >= start and it.message.get().timestamp < stop
      )
    if store.otherTopicFirst:
      let other = msgAt(start, "of the other topic", OtherTopic)
      inRange.insert(
        WakuMessageKeyValue(
          messageHash: computeMessageHash(shard, other),
          message: Opt.some(other),
          pubsubTopic: Opt.some(shard),
        ),
        0,
      )
    let pageLen = min(inRange.len, store.pageSize)
    let cursor =
      if inRange.len > pageLen:
        Opt.some(inRange[pageLen - 1].messageHash)
      else:
        Opt.none(WakuMessageHash)
    if store.calls == 1:
      for (shard, message) in store.late:
        store.put(shard, message)
    var messages = inRange[0 ..< pageLen]
    if store.badRowOnce:
      store.badRowOnce = false
      let bad = msgAt(start - 1, "out of order")
      messages.add(
        WakuMessageKeyValue(
          messageHash: computeMessageHash(shard, bad),
          message: Opt.some(bad),
          pubsubTopic: Opt.some(shard),
        )
      )
    return ok(
      StoreQueryResponse(statusCode: 200, messages: messages, paginationCursor: cursor)
    )

proc newService(
    store: FakeStore,
    ctx: BrokerContext,
    clock: proc(): Timestamp {.gcsafe, raises: [].} = getNowInNanosecondTime,
): HistoryQueryService =
  let service = HistoryQueryService.new(ctx, store.queryToAny(), 10.seconds, clock)
  service.retryDelay = 10.milliseconds
  service.startHistoryQueryService()
  return service

suite "History query service":
  asyncTest "a query emits each message of its range one time and then completes":
    let ctx = NewBrokerContext()
    let events = HistoryQueryEvents.new(ctx)
    defer:
      await events.teardown()
    let store = FakeStore(pageSize: 2)
    let service = newService(store, ctx)
    defer:
      await service.stopHistoryQueryService()
    let now = getNowInNanosecondTime()
    let start = now - 2 * 60 * Minute
    let stop = now - 60 * Minute
    # Shard A has five messages in the range and one on each side of it.
    # Two of the five share a timestamp at a page boundary.
    # Shard B has two messages in the range.
    store.put(ShardA, msgAt(start - Minute, "before the range"))
    store.put(ShardA, msgAt(start, "a1"))
    store.put(ShardA, msgAt(start + Minute, "a2"))
    store.put(ShardA, msgAt(start + 2 * Minute, "a3"))
    store.put(ShardA, msgAt(start + 2 * Minute, "a4"))
    store.put(ShardA, msgAt(start + 3 * Minute, "a5"))
    store.put(ShardA, msgAt(stop, "at the end time"))
    store.put(ShardB, msgAt(start + Minute, "b1"))
    store.put(ShardB, msgAt(start + 4 * Minute, "b2"))
    let requestId = RequestId("query-1")
    let started = service.startQuery(
      requestId, HistoryQuery.init(Topic, start, Opt.some(stop)), @[ShardA, ShardB]
    )
    check started.isOk()
    # No event comes before the caller has the request id.
    check:
      events.messages.len == 0
      events.completed.len == 0
      service.activeQueryCount == 1
    check await events.waitFinished(WaitTimeout)
    check:
      events.payloads() == @["a1", "a2", "a3", "a4", "a5", "b1", "b2"]
      events.messages.allIt(it.requestId == requestId)
      events.messages[0].messageHash ==
        computeMessageHash(ShardA, events.messages[0].message).to0xHex()
      events.messages[5].messageHash ==
        computeMessageHash(ShardB, events.messages[5].message).to0xHex()
      events.completed.len == 1
      events.completed[0].requestId == requestId
      events.completed[0].messageCount == 7
      events.errors.len == 0
      service.activeQueryCount == 0
    # The archive had all of the range at the call, so the query makes one pass.
    # Shard A needs four pages and shard B needs one.
    check store.calls == 5

  asyncTest "a message archived after the first pass comes in the second pass even if the clock jumps":
    let ctx = NewBrokerContext()
    let events = HistoryQueryEvents.new(ctx)
    defer:
      await events.teardown()
    let store = FakeStore(pageSize: 10)
    # The wall clock jumps forward one hour when the first page request comes.
    # The archive wait runs on the monotonic clock, so the jump does not change it.
    let service = newService(
      store,
      ctx,
      proc(): Timestamp {.gcsafe, raises: [].} =
        getNowInNanosecondTime() + (if store.calls > 0: 60 * Minute
        else: Timestamp(0)),
    )
    defer:
      await service.stopHistoryQueryService()
    service.archiveTime = 300.milliseconds
    service.timestampVariance = 300.milliseconds
    let now = getNowInNanosecondTime()
    store.put(ShardA, msgAt(now - 5 * Second, "archived long ago"))
    store.put(ShardA, msgAt(now - 200 * Millisecond, "archived recently"))
    store.late = @[(ShardA, msgAt(now - 100 * Millisecond, "archived late"))]
    let requestId = RequestId("query-tail")
    check service
      .startQuery(requestId, HistoryQuery.init(Topic, now - Minute), @[ShardA])
      .isOk()
    check await events.waitFinished(WaitTimeout)
    check:
      events.payloads() == @["archived long ago", "archived recently", "archived late"]
      events.completed.len == 1
      events.completed[0].messageCount == 3
      # The range ends one variance after the call.
      # The second pass waits one more variance and one archive time.
      events.finishedAt >= now + 900 * Millisecond
      store.calls == 2

  asyncTest "a failed page is tried again and the query fails after the last try":
    let ctx = NewBrokerContext()
    let events = HistoryQueryEvents.new(ctx)
    defer:
      await events.teardown()
    let store = FakeStore(pageSize: 10)
    let service = newService(store, ctx)
    defer:
      await service.stopHistoryQueryService()
    service.pageAttempts = 3
    let now = getNowInNanosecondTime()
    let start = now - 2 * 60 * Minute
    let stop = now - 60 * Minute
    store.put(ShardA, msgAt(start + Minute, "m1"))
    # Phase 1: two requests fail and the third succeeds, after two retry delays.
    service.retryDelay = 50.milliseconds
    store.failures = 2
    let pastQuery = HistoryQuery.init(Topic, start, Opt.some(stop))
    let startedAt = getNowInNanosecondTime()
    check service.startQuery(RequestId("retry"), pastQuery, @[ShardA]).isOk()
    check await events.waitFinished(WaitTimeout)
    check:
      events.payloads() == @["m1"]
      events.completed.len == 1
      events.errors.len == 0
      store.calls == 3
      events.finishedAt - startedAt >= 100 * Millisecond
    # Phase 2: each request fails, so the query fails after three tries.
    events.reset()
    store.calls = 0
    store.failures = 100
    let failing = RequestId("fail")
    check service.startQuery(failing, pastQuery, @[ShardA]).isOk()
    check await events.waitFinished(WaitTimeout)
    check:
      events.messages.len == 0
      events.completed.len == 0
      events.errors.len == 1
      events.errors[0].requestId == failing
      events.errors[0].error == "the store is not available"
      store.calls == 3
    # Phase 3: two requests fail before each page of a query of three pages.
    # A good page resets the count of the failures, so the query completes.
    events.reset()
    store.calls = 0
    store.pageSize = 1
    store.failures = 2
    store.failuresPerPage = 2
    store.put(ShardA, msgAt(start + 2 * Minute, "m2"))
    check service.startQuery(RequestId("pages"), pastQuery, @[ShardA]).isOk()
    check await events.waitFinished(WaitTimeout)
    check:
      events.payloads() == @["m1", "m2"]
      events.completed.len == 1
      events.errors.len == 0
      store.calls == 9
    # Phase 4: the first page ends with a bad row, after its good rows.
    # The query gets the page again, and each message comes one time.
    events.reset()
    store.calls = 0
    store.pageSize = 10
    store.failures = 0
    store.failuresPerPage = 0
    store.badRowOnce = true
    check service.startQuery(RequestId("partial"), pastQuery, @[ShardA]).isOk()
    check await events.waitFinished(WaitTimeout)
    check:
      events.payloads() == @["m1", "m2"]
      events.completed.len == 1
      events.errors.len == 0
      store.calls == 2

  asyncTest "a query from a recent start gives no older message":
    let ctx = NewBrokerContext()
    let events = HistoryQueryEvents.new(ctx)
    defer:
      await events.teardown()
    let store = FakeStore(pageSize: 10)
    let service = newService(store, ctx)
    defer:
      await service.stopHistoryQueryService()
    service.archiveTime = 300.milliseconds
    service.timestampVariance = 300.milliseconds
    let now = getNowInNanosecondTime()
    store.put(ShardA, msgAt(now - 400 * Millisecond, "before the start"))
    store.put(ShardA, msgAt(now - 100 * Millisecond, "after the start"))
    # The range starts in the last part, which the second pass gets again.
    let recent = HistoryQuery.init(Topic, now - 200 * Millisecond)
    check service.startQuery(RequestId("recent"), recent, @[ShardA]).isOk()
    check await events.waitFinished(WaitTimeout)
    check:
      events.payloads() == @["after the start"]
      events.completed.len == 1
      events.completed[0].messageCount == 1
      store.calls == 2

  asyncTest "a query skips a message of another content topic":
    let ctx = NewBrokerContext()
    let events = HistoryQueryEvents.new(ctx)
    defer:
      await events.teardown()
    # Each page of the fake Store starts with a message of `OtherTopic`.
    let store = FakeStore(pageSize: 10, otherTopicFirst: true)
    let service = newService(store, ctx)
    defer:
      await service.stopHistoryQueryService()
    let now = getNowInNanosecondTime()
    let start = now - 2 * 60 * Minute
    store.put(ShardA, msgAt(start + Minute, "m1"))
    let pastQuery = HistoryQuery.init(Topic, start, Opt.some(now - 60 * Minute))
    check service.startQuery(RequestId("wrong"), pastQuery, @[ShardA]).isOk()
    check await events.waitFinished(WaitTimeout)
    check:
      events.payloads() == @["m1"]
      events.completed.len == 1
      events.completed[0].messageCount == 1
      events.errors.len == 0
      store.calls == 1

  asyncTest "a query with a bad range or no shard is refused":
    let now = getNowInNanosecondTime()
    let variance = 20 * Second
    let latest = now + variance
    proc rangeOf(
        start: Timestamp, stop = Opt.none(Timestamp)
    ): Result[tuple[startTime, endTime: Timestamp], string] =
      HistoryQuery.init(Topic, start, stop).timeRange(now, variance)

    # With no end time, the range ends one variance after the current time.
    # A start time in that interval is correct for a sender whose clock is ahead.
    check:
      rangeOf(-1, Opt.some(Timestamp(5))).isErr()
      rangeOf(latest).error.startsWith("startTime")
      rangeOf(now + Second).get() == (now + Second, latest)
      rangeOf(now - Minute, Opt.some(now - Minute)).isErr()
      rangeOf(now - Minute, Opt.some(latest + 1)).isErr()
      rangeOf(now - Minute, Opt.some(latest)).get() == (now - Minute, latest)
      rangeOf(latest - MaxHistoryQueryRange - 1).error.startsWith(
        "startTime must not be more than"
      )
      rangeOf(now - MaxHistoryQueryRange - 1, Opt.some(now)).error.startsWith(
        "the time range"
      )
      rangeOf(latest - MaxHistoryQueryRange).get() ==
        (latest - MaxHistoryQueryRange, latest)
      rangeOf(now - Minute, Opt.some(now - Second)).get() == (
        now - Minute, now - Second
      )
    # The service refuses a query when it is not running or when the topic has no shard.
    let ctx = NewBrokerContext()
    let service = HistoryQueryService.new(ctx, FakeStore().queryToAny(), 10.seconds)
    let query = HistoryQuery.init(Topic, now - Minute)
    check service.startQuery(RequestId("stopped"), query, @[ShardA]).isErr()
    service.startHistoryQueryService()
    check service.startQuery(RequestId("no shard"), query, @[]).isErr()
    await service.stopHistoryQueryService()

  asyncTest "a query over the limit is refused and a stop cancels the queries and frees their slots":
    let ctx = NewBrokerContext()
    let events = HistoryQueryEvents.new(ctx)
    defer:
      await events.teardown()
    let now = getNowInNanosecondTime()
    # Phase 1: a stop cancels the requests in flight and a query that waits for a slot.
    # The queries emit no event.
    let slowStore = FakeStore(pageSize: 10, reply: newAsyncEvent())
    let slowService = newService(slowStore, ctx)
    defer:
      await slowService.stopHistoryQueryService()
    for i in 0 .. MaxPagesInFlight:
      check slowService
        .startQuery(
          RequestId("stopped-" & $i), HistoryQuery.init(Topic, now - Minute), @[ShardA]
        )
        .isOk()
    checkUntilTimeoutCustom(WaitTimeout, 5.milliseconds):
      slowStore.calls == MaxPagesInFlight
    await slowService.stopHistoryQueryService()
    check:
      slowStore.cancelled == MaxPagesInFlight
      events.messages.len == 0
      events.completed.len == 0
      events.errors.len == 0
    # Phase 2: after a new start, `MaxPagesInFlight + 2` queries complete.
    # The most page requests in flight at the same time is `MaxPagesInFlight`.
    # So the stop freed each slot, and the slots still limit the requests.
    slowService.startHistoryQueryService()
    slowStore.reply = nil
    slowStore.delay = 20.milliseconds
    slowStore.maxInFlight = 0
    let pastQuery = HistoryQuery.init(Topic, now - 2 * Minute, Opt.some(now - Minute))
    for i in 0 ..< MaxPagesInFlight + 2:
      check slowService.startQuery(RequestId("slow-" & $i), pastQuery, @[ShardA]).isOk()
    checkUntilTimeoutCustom(WaitTimeout, 5.milliseconds):
      events.completed.len == MaxPagesInFlight + 2
    check slowStore.maxInFlight == MaxPagesInFlight
    events.reset()
    # Phase 3: the fake Store does not answer, so each query waits.
    # A cancelled request answers with a message, so the stop must drop it.
    let store = FakeStore(pageSize: 10, reply: newAsyncEvent(), ignoreCancel: true)
    let service = newService(store, ctx)
    store.put(ShardA, msgAt(now - Second, "after the stop"))
    let query = HistoryQuery.init(Topic, now - Minute)
    for i in 0 ..< MaxActiveHistoryQueries:
      check service.startQuery(RequestId("wait-" & $i), query, @[ShardA]).isOk()
    check:
      service.activeQueryCount == MaxActiveHistoryQueries
      service.startQuery(RequestId("one too many"), query, @[ShardA]).isErr()
    checkUntilTimeoutCustom(WaitTimeout, 5.milliseconds):
      store.calls == MaxPagesInFlight
    await sleepAsync(50.milliseconds)
    check store.calls == MaxPagesInFlight
    # A stop cancels the queries, and they emit no event.
    await service.stopHistoryQueryService()
    check:
      service.activeQueryCount == 0
      store.cancelled == MaxPagesInFlight
    store.reply.fire()
    await sleepAsync(200.milliseconds)
    check:
      events.messages.len == 0
      events.completed.len == 0
      events.errors.len == 0
      service.startQuery(RequestId("after the stop"), query, @[ShardA]).isErr()

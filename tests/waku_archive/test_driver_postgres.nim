{.used.}

import results, std/[sequtils, strutils], testutils/unittests, chronos
import
  logos_delivery/waku/[
    waku_archive,
    waku_archive/driver/postgres_driver,
    waku_core,
    waku_core/message/digest,
    common/databases/db_postgres/pgasyncpool,
  ],
  ../testlib/wakucore,
  ../testlib/testasync,
  ../testlib/postgres

suite "Postgres driver":
  ## Unique driver instance
  var driver {.threadvar.}: PostgresDriver

  asyncSetup:
    let driverRes = await newTestPostgresDriver()
    if driverRes.isErr():
      assert false, driverRes.error

    driver = PostgresDriver(driverRes.get())

  asyncTeardown:
    let resetRes = await driver.reset()
    if resetRes.isErr():
      assert false, resetRes.error

    (await driver.close()).expect("driver to close")

  asyncTest "Asynchronous queries":
    var futures = newSeq[Future[ArchiveDriverResult[void]]](0)

    let beforeSleep = now()

    for _ in 1 .. 25:
      futures.add(driver.sleep(1))

    await allFutures(futures)

    let diff = now() - beforeSleep

    assert diff < 2_000_000_000 ## nanoseconds

  asyncTest "Insert a message":
    const contentTopic = "test-content-topic"
    const meta = "test meta"

    let msg = fakeWakuMessage(contentTopic = contentTopic, meta = meta)

    let putRes = await driver.put(
      computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
    )
    assert putRes.isOk(), putRes.error

    let storedMsg = (await driver.getAllMessages()).tryGet()

    assert storedMsg.len == 1

    let (_, pubsubTopic, actualMsg) = storedMsg[0]
    assert actualMsg.contentTopic == contentTopic
    assert pubsubTopic == DefaultPubsubTopic
    assert toHex(actualMsg.payload) == toHex(msg.payload)
    assert toHex(actualMsg.meta) == toHex(msg.meta)

  asyncTest "Insert and query message":
    const contentTopic1 = "test-content-topic-1"
    const contentTopic2 = "test-content-topic-2"
    const pubsubTopic1 = "pubsubtopic-1"
    const pubsubTopic2 = "pubsubtopic-2"

    let msg1 = fakeWakuMessage(contentTopic = contentTopic1)

    var putRes =
      await driver.put(computeMessageHash(pubsubTopic1, msg1), pubsubTopic1, msg1)
    assert putRes.isOk(), putRes.error

    let msg2 = fakeWakuMessage(contentTopic = contentTopic2)

    putRes =
      await driver.put(computeMessageHash(pubsubTopic2, msg2), pubsubTopic2, msg2)
    assert putRes.isOk(), putRes.error

    let countMessagesRes = await driver.getMessagesCount()

    assert countMessagesRes.isOk(), $countMessagesRes.error
    assert countMessagesRes.get() == 2

    var messagesRes = await driver.getMessages(contentTopics = @[contentTopic1])

    assert messagesRes.isOk(), $messagesRes.error
    assert messagesRes.get().len == 1

    # Get both content topics, check ordering
    messagesRes =
      await driver.getMessages(contentTopics = @[contentTopic1, contentTopic2])
    assert messagesRes.isOk(), messagesRes.error

    assert messagesRes.get().len == 2
    assert messagesRes.get()[0][2].contentTopic == contentTopic1

    # Descending order
    messagesRes = await driver.getMessages(
      contentTopics = @[contentTopic1, contentTopic2], ascendingOrder = false
    )
    assert messagesRes.isOk(), messagesRes.error

    assert messagesRes.get().len == 2
    assert messagesRes.get()[0][2].contentTopic == contentTopic2

    # cursor
    # Get both content topics
    messagesRes = await driver.getMessages(
      contentTopics = @[contentTopic1, contentTopic2],
      cursor = Opt.some(computeMessageHash(pubsubTopic1, messagesRes.get()[1][2])),
    )
    assert messagesRes.isOk()
    assert messagesRes.get().len == 1

    # Get both content topics but one pubsub topic
    messagesRes = await driver.getMessages(
      contentTopics = @[contentTopic1, contentTopic2],
      pubsubTopic = Opt.some(pubsubTopic1),
    )
    assert messagesRes.isOk(), messagesRes.error

    assert messagesRes.get().len == 1
    assert messagesRes.get()[0][2].contentTopic == contentTopic1

    # Limit
    messagesRes = await driver.getMessages(
      contentTopics = @[contentTopic1, contentTopic2], maxPageSize = 1
    )
    assert messagesRes.isOk(), messagesRes.error
    assert messagesRes.get().len == 1

  asyncTest "Insert true duplicated messages":
    # Validates that two completely equal messages can not be stored.

    let now = now()

    let msg1 = fakeWakuMessage(ts = now)
    let msg2 = fakeWakuMessage(ts = now)

    let initialNumMsgs = (await driver.getMessagesCount()).valueOr:
      raiseAssert "could not get num mgs correctly: " & $error

    var putRes = await driver.put(
      computeMessageHash(DefaultPubsubTopic, msg1), DefaultPubsubTopic, msg1
    )
    assert putRes.isOk(), putRes.error

    var newNumMsgs = (await driver.getMessagesCount()).valueOr:
      raiseAssert "could not get num mgs correctly: " & $error

    assert newNumMsgs == (initialNumMsgs + 1.int64),
      "wrong number of messages: " & $newNumMsgs

    putRes = await driver.put(
      computeMessageHash(DefaultPubsubTopic, msg2), DefaultPubsubTopic, msg2
    )

    assert putRes.isOk()

    newNumMsgs = (await driver.getMessagesCount()).valueOr:
      raiseAssert "could not get num mgs correctly: " & $error

    assert newNumMsgs == (initialNumMsgs + 1.int64),
      "wrong number of messages: " & $newNumMsgs

  asyncTest "messages_lookup partitions are created and dropped with messages partitions":
    ## Lookup partitions are created and dropped in lockstep — no row deletes.
    let msg = fakeWakuMessage(ts = now())
    require (
      await driver.put(
        computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
      )
    ).isOk()

    let msgPartitions =
      (await driver.getPartitionsList("messages")).expect("messages list")
    let lookupPartitions =
      (await driver.getPartitionsList("messages_lookup")).expect("lookup list")
    check msgPartitions.len > 0
    check lookupPartitions.len == msgPartitions.len
    for p in msgPartitions:
      check ("lookup_" & p.replace("messages_", "")) in lookupPartitions

    ## dropping every messages partition must take the lookup siblings with it
    require (await driver.reset()).isOk()
    check (await driver.getPartitionsList("messages_lookup")).expect("lookup list").len ==
      0

  asyncTest "ensureLookupPartitions rebuilds dropped lookup partitions":
    ## Dropped lookup partitions degrade hash queries; ensure heals them.
    let msg = fakeWakuMessage(ts = now())
    let hash = computeMessageHash(DefaultPubsubTopic, msg)
    require (await driver.put(hash, DefaultPubsubTopic, msg)).isOk()

    check (await driver.getMessages(hashes = @[hash])).expect("hash query").len == 1

    ## drop every lookup partition behind the driver's back
    let rawPool = PgAsyncPool.new(storeMessageDbUrl, 1).expect("raw pool")
    let lookupPartitions =
      (await driver.getPartitionsList("messages_lookup")).expect("lookup list")
    require lookupPartitions.len > 0
    for p in lookupPartitions:
      (await rawPool.pgQuery("DROP TABLE IF EXISTS " & p)).expect("drop " & p)
    (await rawPool.close()).expect("close raw pool")

    check (await driver.getMessages(hashes = @[hash])).expect("degraded query").len == 0

    (await driver.ensureLookupPartitions()).expect("ensureLookupPartitions")

    check (await driver.getMessages(hashes = @[hash])).expect("healed query").len == 1

  asyncTest "dropStrayLookupPartitions removes attached and detached strays":
    ## Crash leftovers: lookup tables with no messages sibling, attached or
    ## detached — the cleanup must drop both kinds.
    const attachedStray = "lookup_4102444800_4102448400" ## far future: year 2100
    const detachedStray = "lookup_4102448400_4102452000"

    let rawPool = PgAsyncPool.new(storeMessageDbUrl, 1).expect("raw pool")
    (
      await rawPool.pgQuery(
        "CREATE TABLE IF NOT EXISTS " & attachedStray &
          " PARTITION OF messages_lookup FOR VALUES FROM (4102444800000000000) TO (4102448400000000000);"
      )
    ).expect("create attached stray")
    (
      await rawPool.pgQuery(
        "CREATE TABLE IF NOT EXISTS " & detachedStray &
          " (timestamp BIGINT NOT NULL, messageHash VARCHAR NOT NULL);"
      )
    ).expect("create detached stray")
    (await rawPool.close()).expect("close raw pool")

    check attachedStray in
      (await driver.getPartitionsList("messages_lookup")).expect("lookup list")
    check (await driver.existsTable(detachedStray)).expect("existsTable")

    (await driver.dropStrayLookupPartitions()).expect("dropStrayLookupPartitions")

    check attachedStray notin
      (await driver.getPartitionsList("messages_lookup")).expect("lookup list")
    check not (await driver.existsTable(detachedStray)).expect("existsTable")

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

  ## The partition maintenance runs on every instance sharing the database, so
  ## these check that a sequence meeting another one in flight ends well. The
  ## window is well in the past, so that it never collides with the partition
  ## the factory keeps creating for the present time.
  const partitionStart = Timestamp(1_700_000_000) ## 2023-11-14 22:13:20 UTC
  const partitionName = "messages_1700000000_1700002800"
  const partitionConstraint = partitionName & "_by_range_check"
  const partitionFromNanos = "1700000000000000000"
  const partitionUntilNanos = "1700002800000000000"

  proc createPartitionTableQuery(): string =
    return
      "CREATE TABLE IF NOT EXISTS " & partitionName &
      " (LIKE messages INCLUDING DEFAULTS INCLUDING CONSTRAINTS);"

  proc addConstraintQuery(): string =
    return
      "ALTER TABLE " & partitionName & " ADD CONSTRAINT " & partitionConstraint &
      " CHECK ( timestamp >= " & partitionFromNanos & " AND timestamp < " &
      partitionUntilNanos & " );"

  asyncTest "A long database error reaches the caller in one piece":
    ## The words telling a concurrent-DDL outcome apart from a real failure sit
    ## past the 80th character of these messages, so the guards in the partition
    ## maintenance only work as long as the whole message is propagated.
    (await driver.performWriteQuery(createPartitionTableQuery())).expect(
      "create the partition table"
    )
    (await driver.performWriteQuery(addConstraintQuery())).expect("add the constraint")

    let repeatedRes = await driver.performWriteQuery(addConstraintQuery())

    ## constraint "<45 chars>" for relation "<30 chars>" already exists
    ## is 127 characters long, and the deciding words start at the 113th
    check repeatedRes.isErr()
    check repeatedRes.error.contains("already exists")

  asyncTest "Complete a partition another instance left half built":
    ## The other instance created the partition table and added its range
    ## constraint, and went away before attaching it. Our sequence has to take
    ## the steps it finds already done and complete the rest.
    (await driver.performWriteQuery(createPartitionTableQuery())).expect(
      "create the partition table"
    )
    (await driver.performWriteQuery(addConstraintQuery())).expect("add the constraint")

    (await driver.addPartition(partitionStart)).expect("addPartition")

    check partitionName in (await driver.getPartitionsList()).expect("partitions list")

  asyncTest "Defer the partition creation to the instance holding the lock":
    ## A pool of one connection, so that the session-level advisory lock stays
    ## held across the queries below, like an instance midway through its own
    ## sequence.
    let lockHolder = PgAsyncPool.new(storeMessageDbUrl, 1).expect("raw pool")
    (
      await lockHolder.pgQuery(
        "SELECT pg_advisory_lock(" & $PartitionAdvisoryLockId & ");"
      )
    ).expect("take the advisory lock")

    ## Built without the builder on purpose: no partition factory runs on it, so
    ## its partition tracking is empty and says whether the sequence below ran
    ## to the end -- the tracking is only updated by its very last line.
    let ourInstance =
      PostgresDriver.new(storeMessageDbUrl, maxConnections = 4).expect("second driver")

    ## Deferring is not a failure, but nothing may be created either: the steps
    ## belong to the sequence of whoever holds the lock.
    (await ourInstance.addPartition(partitionStart)).expect("deferred addPartition")

    check not (await driver.existsTable(partitionName)).expect("existsTable")
    check not ourInstance.containsAnyPartition()

    (
      await lockHolder.pgQuery(
        "SELECT pg_advisory_unlock(" & $PartitionAdvisoryLockId & ");"
      )
    ).expect("release the advisory lock")
    (await lockHolder.close()).expect("close the raw pool")

    ## The work was postponed, not lost: the next attempt goes through
    (await ourInstance.addPartition(partitionStart)).expect("addPartition")

    check partitionName in (await driver.getPartitionsList()).expect("partitions list")
    check ourInstance.containsAnyPartition()

    (await ourInstance.close()).expect("close the second driver")

suite "Postgres driver - concurrent DDL outcomes":
  ## The messages below are the ones the fleets produced while two instances
  ## maintained the same partitions. Every one of them means "another instance
  ## already did this", and none of them may be treated as a failure.
  const constraintAlreadyExists =
    "ERROR:  constraint \"messages_1720364735_1720364740_by_range_check\" " &
    "for relation \"messages_1720364735_1720364740\" already exists"

  const constraintDoesNotExist =
    "ERROR:  constraint \"messages_1720364735_1720364740_by_range_check\" " &
    "of relation \"messages_1720364735_1720364740\" does not exist"

  const alreadyAPartition =
    "ERROR:  \"messages_1720364735_1720364740\" is already a partition"

  ## CREATE TABLE IF NOT EXISTS is not atomic, so the instance losing that race
  ## gets a catalogue unique violation instead of the "skipping" notice
  const typeCatalogueCollision =
    "ERROR:  duplicate key value violates unique constraint " &
    "\"pg_type_typname_nsp_index\""

  const classCatalogueCollision =
    "ERROR:  duplicate key value violates unique constraint " &
    "\"pg_class_relname_nsp_index\""

  test "Classify the outcomes of a concurrent partition maintenance":
    check constraintAlreadyExists.isConcurrentDdlOutcome()
    check constraintDoesNotExist.isConcurrentDdlOutcome()
    check alreadyAPartition.isConcurrentDdlOutcome()
    check typeCatalogueCollision.isConcurrentDdlOutcome()
    check classCatalogueCollision.isConcurrentDdlOutcome()

  test "Do not classify a genuine failure as a concurrent outcome":
    check not "ERROR:  could not acquire advisory lock".isConcurrentDdlOutcome()
    check not "ERROR:  no space left on device".isConcurrentDdlOutcome()
    check not "ERROR:  deadlock detected".isConcurrentDdlOutcome()

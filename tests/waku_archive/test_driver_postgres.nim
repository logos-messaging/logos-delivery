{.used.}

import
  results,
  std/[algorithm, sequtils, strutils],
  testutils/unittests,
  chronos,
  db_connector/postgres
import
  logos_delivery/waku/[
    waku_archive,
    waku_archive/archive_metrics,
    waku_archive/driver/builder,
    waku_archive/driver/postgres_driver,
    waku_core,
    waku_core/message/digest,
    common/databases/db_postgres/dbconn,
    common/databases/db_postgres/dns_resolver,
    common/databases/db_postgres/pgasyncpool,
  ],
  ../testlib/wakucore,
  ../testlib/testasync,
  ../testlib/postgres,
  ./archive_utils

proc noopFatalHandler(errMsg: string) {.gcsafe, raises: [].} =
  ## For the second driver instances the tests start: the factory only calls it
  ## after six failed passes, about an hour, so it is out of reach within a test.
  discard

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

  asyncTest "A message handled twice by the archive is stored once and counted once as written":
    let
      insertsBefore = insertCount(relayIngress)
      failuresBefore = errorCount(insertFailure)
      shardBefore = messagesPerShard("0")
      archive = newWakuArchive(driver)
      message = fakeWakuMessage(ts = now())

    check (await archive.handleMessage(DefaultPubsubTopic, message)).isOk()
    check (await archive.handleMessage(DefaultPubsubTopic, message)).isOk()

    check:
      (await driver.getMessagesCount()) == ArchiveDriverResult[int64].ok(1)
      insertCount(relayIngress) == insertsBefore + 1
      messagesPerShard("0") == shardBefore + 1
      errorCount(insertFailure) == failuresBefore

  asyncTest "A message handled by two archives sharing one database is counted once as written":
    let otherDriver = (await newTestPostgresDriver()).expect("second driver")
    defer:
      (await otherDriver.close()).expect("close the second driver")

    let
      insertsBefore = insertCount(relayIngress)
      failuresBefore = errorCount(insertFailure)
      message = fakeWakuMessage(ts = now())

    check (await newWakuArchive(driver).handleMessage(DefaultPubsubTopic, message)).isOk()
    check (await newWakuArchive(otherDriver).handleMessage(DefaultPubsubTopic, message)).isOk()

    check:
      (await driver.getMessagesCount()) == ArchiveDriverResult[int64].ok(1)
      insertCount(relayIngress) == insertsBefore + 1
      errorCount(insertFailure) == failuresBefore

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

  asyncTest "A hash query for a full chunk of hashes returns only those":
    ## Request exactly one 100-hash chunk from 101 stored messages.
    ## An extra empty chunk would return the unrequested message too.
    const chunk = 100
    let base = now()
    var hashes: seq[WakuMessageHash]
    for i in 0 .. chunk:
      let msg = fakeWakuMessage(payload = "msg-" & $i, ts = base + int64(i))
      let hash = computeMessageHash(DefaultPubsubTopic, msg)
      require (await driver.put(hash, DefaultPubsubTopic, msg)).isOk()
      hashes.add(hash)

    let asked = hashes[0 ..< chunk]
    let rows = (await driver.getMessages(hashes = asked, maxPageSize = uint(chunk + 1))).expect(
      "full chunk query"
    )
    check:
      rows.len == chunk
      rows.allIt(it[0] in asked)

  asyncTest "A hash query only plans the messages partitions holding the hashes":
    ## Hashes carry no time bound: a query joining both partitioned tables
    ## plans every partition of both, which took production nodes down.
    const numPartitions = 300
    const firstHour = 1_599_998_400'i64 ## 2020-09-13 12:00 UTC, an hour start

    proc forEachPartition(stmt: string): string =
      ## %1$s and %2$s are the partition bounds in seconds
      return
        "DO $$ DECLARE s BIGINT; BEGIN FOR i IN 0.." & $(numPartitions - 1) &
        " LOOP s := " & $firstHour & " + i * 3600; EXECUTE format('" & stmt &
        "', s, s + 3600); END LOOP; END $$;"

    let rawPool = PgAsyncPool.new(storeMessageDbUrl, 1).expect("raw pool")
    for stmt in [
      "CREATE TABLE messages_%1$s_%2$s PARTITION OF messages" &
        " FOR VALUES FROM (%1$s000000000) TO (%2$s000000000)",
      "CREATE TABLE lookup_%1$s_%2$s PARTITION OF messages_lookup" &
        " FOR VALUES FROM (%1$s000000000) TO (%2$s000000000)",
    ]:
      (await rawPool.pgQuery(forEachPartition(stmt))).expect("create partitions")

    var hashes: seq[WakuMessageHash]
    var timestamps: seq[Timestamp]
    var partitions: seq[string]
    for hour in [0'i64, numPartitions div 2, numPartitions - 1]:
      let start = firstHour + hour * 3600
      let msg = fakeWakuMessage(payload = "msg-" & $hour, ts = start * 1_000_000_000)
      let hash = computeMessageHash(DefaultPubsubTopic, msg)
      require (await driver.put(hash, DefaultPubsubTopic, msg)).isOk()
      hashes.add(hash)
      timestamps.add(msg.timestamp)
      partitions.add("messages_" & $start & "_" & $(start + 3600))

    let missing = computeMessageHash(DefaultPubsubTopic, fakeWakuMessage(ts = 1))
    let rows =
      (await driver.getMessages(hashes = hashes & missing)).expect("hash query")
    check rows.mapIt(it[0]) == reversed(hashes)

    var plan: seq[string]
    proc planCallback(pqResult: ptr PGresult) =
      for iRow in 0 ..< pqResult.pqNtuples():
        plan.add($(pqgetvalue(pqResult, iRow, 0)))

    let hexHashes = "'" & hashes.mapIt(toHex(it).toLowerAscii()).join("','") & "'"
    let explain = "EXPLAIN " & messagesAtTimestampsQuery(hexHashes, timestamps, 20)
    (await rawPool.pgQuery(explain, @[], planCallback)).expect("explain")
    ## only the partitions holding the hashes, out of the 300 just created
    var scanned: seq[string]
    for partition in partitions:
      if plan.anyIt(it.contains(" on " & partition)):
        scanned.add(partition)
    check:
      scanned == partitions
      plan.countIt(it.contains(" on messages_")) <= 2 * partitions.len

    (
      await rawPool.pgQuery(
        forEachPartition("DROP TABLE messages_%1$s_%2$s, lookup_%1$s_%2$s")
      )
    ).expect("drop partitions")
    (await rawPool.close()).expect("close raw pool")

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

  asyncTest "dropStrayLookupPartitions keeps the sibling of an attached partition":
    ## Besides the one added here, the setup's partitions around now: every
    ## attached messages partition must keep its lookup sibling.
    const siblingStart = Timestamp(1_719_997_200) ## 2024-07-03 09:00:00 UTC
    (await driver.addPartition(siblingStart)).expect("addPartition")

    (await driver.dropStrayLookupPartitions()).expect("dropStrayLookupPartitions")

    let partitions = (await driver.getPartitionsList()).expect("partitions list")
    let lookups =
      (await driver.getPartitionsList("messages_lookup")).expect("lookup list")
    check "messages_1719997200_1720000800" in partitions
    for partition in partitions:
      check ("lookup_" & partition.replace("messages_", "")) in lookups

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

  ## Its own hour: the test above leaves its partition in the database, where
  ## the next setup's driver tracks it until that test's teardown.
  const buildStart = Timestamp(1_710_000_000) ## 2024-03-09 16:00:00 UTC
  const buildName = "messages_1710000000_1710003600"
  const buildLookupName = "lookup_1710000000_1710003600"

  asyncTest "A partition under construction survives another instance's cleanup":
    ## The blocker takes the lock an ANALYZE of messages takes, which holds up
    ## the ATTACH of the partition being built. A second instance runs its
    ## maintenance pass, cleanups included, during that wait.
    let blocker = PgAsyncPool.new(storeMessageDbUrl, 1).expect("blocker pool")
    let observer = PgAsyncPool.new(storeMessageDbUrl, 1).expect("observer pool")
    let other =
      PostgresDriver.new(storeMessageDbUrl, maxConnections = 4).expect("second driver")

    var waitingAttaches = 0
    proc onCount(res: ptr PGresult) {.closure, gcsafe, raises: [].} =
      if pqntuples(res) > 0:
        try:
          waitingAttaches = parseInt($pqgetvalue(res, 0, 0))
        except ValueError:
          discard

    (await blocker.pgQuery("BEGIN")).expect("begin")
    (await blocker.pgQuery("LOCK TABLE messages IN SHARE UPDATE EXCLUSIVE MODE")).expect(
      "lock messages"
    )

    let building = driver.addPartition(buildStart)
    try:
      ## By the partition's name, near the start of the statement: pg_stat_activity
      ## keeps only its first track_activity_query_size bytes (1024 by default),
      ## and the ATTACH comes late in it. The only lock wait is that ATTACH.
      for _ in 0 ..< 100:
        (
          await observer.pgQuery(
            "SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid()" &
              " AND wait_event_type = 'Lock' AND query LIKE '%" & buildName & "%'",
            @[],
            onCount,
          )
        ).expect("count the waiting attaches")
        if waitingAttaches > 0:
          break
        await sleepAsync(chronos.milliseconds(100))
      require waitingAttaches > 0

      await other.startPartitionFactory(noopFatalHandler)
      checkUntilTimeout:
        other.arePartitionsProvisioned()
    finally:
      (await blocker.pgQuery("COMMIT")).expect("commit")
      (await blocker.close()).expect("close the blocker")
      (await observer.close()).expect("close the observer")
      (await other.close()).expect("close the second driver")

    (await building).expect("addPartition")

    let partitions = (await driver.getPartitionsList()).expect("partitions list")
    let lookups =
      (await driver.getPartitionsList("messages_lookup")).expect("lookup list")
    check:
      buildName in partitions
      buildLookupName in lookups

  asyncTest "Adding a partition that already exists does not wait for its readers":
    ## What a second instance does when it gets the lock right after the first
    ## one committed the partition. The reader plays long reads of the
    ## partition and of the lookup table.
    (await driver.addPartition(buildStart)).expect("addPartition")

    let reader = PgAsyncPool.new(storeMessageDbUrl, 1).expect("reader pool")
    (await reader.pgQuery("BEGIN")).expect("begin")
    (await reader.pgQuery("LOCK TABLE " & buildName & " IN ACCESS SHARE MODE")).expect(
      "read the partition"
    )
    (await reader.pgQuery("LOCK TABLE messages_lookup IN ACCESS SHARE MODE")).expect(
      "read the lookup table"
    )

    ## A second instance, as the suite's driver already tracks the partition.
    let other =
      PostgresDriver.new(storeMessageDbUrl, maxConnections = 4).expect("second driver")
    let adding = other.addPartition(buildStart)
    try:
      require (await adding.withTimeout(chronos.seconds(5)))
      check (await adding).isOk()
    finally:
      (await reader.pgQuery("COMMIT")).expect("commit")
      (await reader.close()).expect("close the reader")
      discard await adding.withTimeout(chronos.seconds(5))
      (await other.close()).expect("close the second driver")

  asyncTest "A partition rolled back by a concurrent-looking error is reported as a failure":
    ## Every statement of the sequence already tolerates what another instance
    ## may have done, so an error that only reads like it ("already exists") is
    ## a genuine failure. A type holding the name of the partition's row type
    ## raises one.
    let rawPool = PgAsyncPool.new(storeMessageDbUrl, 1).expect("raw pool")
    try:
      (await rawPool.pgQuery("CREATE TYPE " & buildName & " AS ENUM ('taken')")).expect(
        "create the type"
      )

      check (await driver.addPartition(buildStart)).isErr()
      check not (await driver.existsTable(buildName)).expect("existsTable")
    finally:
      (await rawPool.pgQuery("DROP TYPE IF EXISTS " & buildName)).expect(
        "drop the type"
      )
      ## in case the sequence did not roll back as a whole
      (await rawPool.pgQuery("DROP TABLE IF EXISTS " & buildLookupName)).expect(
        "drop the lookup partition"
      )
      (await rawPool.close()).expect("close the raw pool")

  ## The startup pass creates the partitions for the current hour and the two
  ## before it, so that the messages store sync pushes back after a downtime, or
  ## into a brand new node, have a partition to land in. The checks below look
  ## at the slots relative to the hour they run in: should an o'clock have
  ## passed since the pass, those slots still exist, created one slot earlier.
  asyncTest "A fresh database gets the current hour and the two before it":
    ## The suite's driver may have found partitions left by an earlier test, so
    ## empty the database and let a second instance start on it: its first
    ## pass takes the empty-state branch.
    (await driver.reset()).expect("reset")
    let leftovers =
      (await driver.getPartitionsList()).expect("partitions list") &
      (await driver.getPartitionsList("messages_lookup")).expect("lookup list")
    for table in leftovers:
      (await driver.performWriteQuery("DROP TABLE " & table)).expect("drop " & table)

    let fresh =
      PostgresDriver.new(storeMessageDbUrl, maxConnections = 4).expect("second driver")
    try:
      await fresh.startPartitionFactory(noopFatalHandler)
      checkUntilTimeout:
        fresh.arePartitionsProvisioned()

      let currentSlot = floorToHour(now() div 1_000_000_000)
      let partitions = (await fresh.getPartitionsList()).expect("partitions list")
      check:
        partitions.anyIt(it.startsWith("messages_" & $(currentSlot - 7200) & "_"))
        partitions.anyIt(it.startsWith("messages_" & $(currentSlot - 3600) & "_"))
        partitions.anyIt(it.startsWith("messages_" & $currentSlot & "_"))
    finally:
      (await fresh.reset()).expect("reset the second driver")
      (await fresh.close()).expect("close the second driver")

  asyncTest "A message up to two hours old is storable right after start":
    let timeOrigin = now()
    let recentEnough = fakeWakuMessage(ts = ts(-90 * 60, timeOrigin))
    let tooOld = fakeWakuMessage(ts = ts(-200 * 60, timeOrigin))

    check (
      await driver.put(
        computeMessageHash(DefaultPubsubTopic, recentEnough),
        DefaultPubsubTopic,
        recentEnough,
      )
    ).expect("put a message 90 minutes old")

    ## Three hours and twenty minutes back is before the oldest startup slot
    ## whatever the current minute, so there is no partition for it.
    check (
      await driver.put(
        computeMessageHash(DefaultPubsubTopic, tooOld), DefaultPubsubTopic, tooOld
      )
    ).isErr()

  asyncTest "A restart after a downtime fills the hours before now":
    ## Leave the database with only a partition from long ago, like a node that
    ## was stopped for a long time, then start a second instance the way the
    ## builder does. The old partition is created through that instance so that
    ## it tracks everything and cleans up; the suite's driver tracks nothing
    ## after its reset, so the teardown has nothing stale to drop.
    (await driver.reset()).expect("reset")

    let restarted =
      PostgresDriver.new(storeMessageDbUrl, maxConnections = 4).expect("second driver")
    try:
      (await restarted.addPartition(partitionStart)).expect("addPartition")

      await restarted.startPartitionFactory(noopFatalHandler)
      checkUntilTimeout:
        restarted.arePartitionsProvisioned()

      let currentSlot = floorToHour(now() div 1_000_000_000)
      let partitions = (await restarted.getPartitionsList()).expect("partitions list")
      check:
        partitionName in partitions
        partitions.anyIt(it.startsWith("messages_" & $(currentSlot - 7200) & "_"))
        partitions.anyIt(it.startsWith("messages_" & $(currentSlot - 3600) & "_"))
        partitions.anyIt(it.startsWith("messages_" & $currentSlot & "_"))
    finally:
      (await restarted.reset()).expect("reset the second driver")
      (await restarted.close()).expect("close the second driver")

  asyncTest "Add a partition with an explicit end":
    ## Half an hour inside the 2023 fixture window, so it collides with nothing.
    let explicitEnd = Timestamp(1_700_001_800)
    (await driver.addPartition(partitionStart, explicitEnd)).expect("addPartition")

    let partitions = (await driver.getPartitionsList()).expect("partitions list")
    let lookups =
      (await driver.getPartitionsList("messages_lookup")).expect("lookup list")
    check:
      "messages_1700000000_1700001800" in partitions
      "lookup_1700000000_1700001800" in lookups

    ## An empty range is refused before any statement runs
    check (await driver.addPartition(partitionStart, partitionStart)).isErr()

  asyncTest "A legacy partition starting mid-hour gets the start of its hour filled":
    ## The previous version started its first partition at the moment the node
    ## came up, e.g. [10:28, 11:00). The start of that hour has no partition, and
    ## the lookback must create exactly [10:00, 10:28), never the whole hour.
    (await driver.reset()).expect("reset")

    let currentSlot = floorToHour(now() div 1_000_000_000)
    let legacyStart = currentSlot - 3600 + 1680 # 28 minutes into the hour before
    let legacyEnd = currentSlot

    let restarted =
      PostgresDriver.new(storeMessageDbUrl, maxConnections = 4).expect("second driver")
    try:
      (await restarted.addPartition(Timestamp(legacyStart), Timestamp(legacyEnd))).expect(
        "legacy partition"
      )

      await restarted.startPartitionFactory(noopFatalHandler)
      checkUntilTimeout:
        restarted.arePartitionsProvisioned()

      let partitions = (await restarted.getPartitionsList()).expect("partitions list")
      check:
        ("messages_" & $(currentSlot - 3600) & "_" & $legacyStart) in partitions
        ("messages_" & $legacyStart & "_" & $legacyEnd) in partitions
        partitions.anyIt(it.startsWith("messages_" & $currentSlot & "_"))
    finally:
      (await restarted.reset()).expect("reset the second driver")
      (await restarted.close()).expect("close the second driver")

  asyncTest "The tracked partitions are in time order after the lookback":
    ## With only the hour before the current one in place, the lookback adds the
    ## hour before that, older than everything tracked so far. The oldest
    ## tracked partition drives retention; here it is what reports the oldest
    ## timestamp, once a row exists so that the row minimum is not the answer.
    (await driver.reset()).expect("reset")

    let currentSlot = floorToHour(now() div 1_000_000_000)

    let restarted =
      PostgresDriver.new(storeMessageDbUrl, maxConnections = 4).expect("second driver")
    try:
      (await restarted.addPartition(Timestamp(currentSlot - 3600))).expect(
        "previous hour"
      )

      await restarted.startPartitionFactory(noopFatalHandler)
      checkUntilTimeout:
        restarted.arePartitionsProvisioned()

      let msg = fakeWakuMessage()
      check (
        await restarted.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).expect("put a message stamped now")

      check (await restarted.getOldestMessageTimestamp()).expect("oldest timestamp") ==
        Timestamp(currentSlot - 7200) * 1_000_000_000
    finally:
      (await restarted.reset()).expect("reset the second driver")
      (await restarted.close()).expect("close the second driver")

  asyncTest "A node whose partition creation is deferred at startup starts with what the other instance built":
    ## The holder plays the other instance midway through its build: it holds
    ## the partition lock while the node starts, so that every creation of the
    ## node's first pass is deferred, then commits the partition for now and
    ## lets go.
    (await driver.reset()).expect("reset")
    let leftovers =
      (await driver.getPartitionsList()).expect("partitions list") &
      (await driver.getPartitionsList("messages_lookup")).expect("lookup list")
    for table in leftovers:
      (await driver.performWriteQuery("DROP TABLE " & table)).expect("drop " & table)

    let holder = PgAsyncPool.new(storeMessageDbUrl, 1).expect("holder pool")
    (await holder.pgQuery("SELECT pg_advisory_lock(" & $PartitionAdvisoryLockId & ");")).expect(
      "take the advisory lock"
    )

    var fatalErrors = newSeq[string](0)
    proc onFatal(errMsg: string) {.gcsafe, closure, raises: [].} =
      fatalErrors.add(errMsg)

    ## The hour the node starts in.
    let slotStart = floorToHour(now() div 1_000_000_000)
    let slotEnd = slotStart + 3600
    let suffix = $slotStart & "_" & $slotEnd
    let bounds =
      " FOR VALUES FROM (" & $slotStart & "000000000) TO (" & $slotEnd & "000000000)"

    var nodeStart: string
    proc onServerTime(res: ptr PGresult) {.closure, gcsafe, raises: [].} =
      if pqntuples(res) > 0:
        nodeStart = $pqgetvalue(res, 0, 0)

    (await holder.pgQuery("SELECT clock_timestamp()", @[], onServerTime)).expect(
      "server time"
    )

    let building = ArchiveDriver.new(
      storeMessageDbUrl, vacuum = false, migrate = true, maxNumConn = 4, onFatal
    )

    ## Until the node has run a partition block and been turned away: with the
    ## lock held, that block can only have been deferred. pg_stat_activity keeps
    ## a backend's last statement, failed or not; the node's backends are those
    ## started after it, the suite's own driver ran such blocks earlier.
    var deferredBlocks = 0
    proc onCount(res: ptr PGresult) {.closure, gcsafe, raises: [].} =
      if pqntuples(res) > 0:
        try:
          deferredBlocks = parseInt($pqgetvalue(res, 0, 0))
        except ValueError:
          discard

    for _ in 0 ..< 100:
      (
        await holder.pgQuery(
          "SELECT count(*) FROM pg_stat_activity WHERE backend_start > ?::timestamptz" &
            " AND query LIKE '%pg_try_advisory_xact_lock%'",
          @[nodeStart],
          onCount,
        )
      ).expect("count the deferred blocks")
      if deferredBlocks > 0:
        break
      await sleepAsync(chronos.milliseconds(100))
    require deferredBlocks > 0

    (
      await holder.pgQuery(
        "CREATE TABLE messages_" & suffix & " PARTITION OF messages" & bounds
      )
    ).expect("create the partition for now")
    (
      await holder.pgQuery(
        "CREATE TABLE lookup_" & suffix & " PARTITION OF messages_lookup" & bounds
      )
    ).expect("create its lookup partition")
    (
      await holder.pgQuery(
        "SELECT pg_advisory_unlock(" & $PartitionAdvisoryLockId & ");"
      )
    ).expect("release the advisory lock")
    (await holder.close()).expect("close the holder")

    let builtRes = await building
    let started = PostgresDriver(builtRes.expect("ArchiveDriver.new"))
    try:
      check:
        fatalErrors.len == 0
        started.containsAnyPartition()
    finally:
      (await started.reset()).expect("reset the started driver")
      (await started.close()).expect("close the started driver")

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

suite "Postgres driver - query metric labels":
  test "hash lookup statements map to their labels":
    const hashes = "'0a1b','2c3d'"
    check:
      convertQueryToMetricLabel(
        "SELECT DISTINCT timestamp FROM messages_lookup WHERE messagehash IN (" & hashes &
          ");"
      ) == "messages_lookup"
      convertQueryToMetricLabel(
        messagesAtTimestampsQuery(hashes, [Timestamp(1_720_364_735_000_000_000)], 20)
      ) == "messages_lookup_fetch"

suite "Postgres connection lifecycle":
  ## A database restart used to take the node down: closing a connection whose
  ## backend was gone failed, which left the remaining connections open and
  ## their descriptors registered in the chronos dispatcher.

  const RawConnString =
    "user=postgres host=localhost port=5432 dbname=postgres password=test123"

  proc backendPidsAlive(
      pool: PgAsyncPool, pids: seq[string]
  ): Future[Result[int, string]] {.async.} =
    var alive = 0

    proc onRow(res: ptr PGresult) {.closure, gcsafe, raises: [].} =
      if pqntuples(res) > 0:
        try:
          alive = parseInt($pqgetvalue(res, 0, 0))
        except ValueError:
          discard

    (
      await pool.pgQuery(
        "SELECT count(*) FROM pg_stat_activity WHERE pid IN (" & pids.join(",") & ")",
        @[],
        onRow,
      )
    ).isOkOr:
      return err($error)

    return ok(alive)

  asyncTest "A connection whose backend died gives its selector entry back":
    let wrapper = (await DbConnWrapper.new(RawConnString)).expect("new connection")

    let asyncFd = wrapper.getRegisteredFd().expect("registered fd")
    check asyncFd in getThreadDispatcher()

    ## the backend kills itself, so libpq closes the socket while the results
    ## of this very query are being read
    let killRes = await wrapper.dbConnQuery(
      sql("SELECT pg_terminate_backend(pg_backend_pid())"), @[], nil, ""
    )
    check killRes.isErr()

    ## precondition: libpq cannot tell the descriptor anymore
    check pqsocket(wrapper.getDbConn()) == -1

    check wrapper.closeDbConn().isOk()
    check asyncFd notin getThreadDispatcher()

  asyncTest "A pool closes every connection even when one is dead":
    let pool = PgAsyncPool.new(storeMessageDbUrl, 3).expect("pool")
    let observer = PgAsyncPool.new(storeMessageDbUrl, 1).expect("observer pool")

    var pids = newSeq[string](3)

    proc collectPid(index: int): DataProc =
      return proc(res: ptr PGresult) {.closure, gcsafe, raises: [].} =
        if pqntuples(res) > 0:
          pids[index] = $pqgetvalue(res, 0, 0)

    ## three overlapping queries force the pool to open three connections
    var queries = newSeq[Future[Result[void, string]]](0)
    for i in 0 ..< 3:
      queries.add(
        pool.pgQuery("SELECT pg_backend_pid(), pg_sleep(0.5)", @[], collectPid(i))
      )

    for queryFut in queries:
      (await queryFut).expect("concurrent pid query")

    check pids.deduplicate().len == 3

    ## an idle pool always hands out its first connection, so this tells which
    ## backend has to die for the close loop to fail on its first iteration
    var firstConnPid: string
    proc onFirstPid(res: ptr PGresult) {.closure, gcsafe, raises: [].} =
      if pqntuples(res) > 0:
        firstConnPid = $pqgetvalue(res, 0, 0)

    (await pool.pgQuery("SELECT pg_backend_pid()", @[], onFirstPid)).expect(
      "first conn pid"
    )

    let survivorPids = pids.filterIt(it != firstConnPid)
    check survivorPids.len == 2

    (await observer.pgQuery("SELECT pg_terminate_backend(" & firstConnPid & ")")).expect(
      "terminate backend"
    )

    ## the pool only learns about the dead backend when it uses it again
    check (await pool.pgQuery("SELECT 1")).isErr()

    (await pool.close()).expect("pool close")

    var stillAlive = -1
    for _ in 0 ..< 50:
      stillAlive = (await observer.backendPidsAlive(survivorPids)).expect("alive count")
      if stillAlive == 0:
        break
      await sleepAsync(100.milliseconds)

    check stillAlive == 0

    (await observer.close()).expect("observer close")

  asyncTest "A pool holding a never used connection can still be closed":
    ## A failing prepare leaves behind a connection that never ran a query, so
    ## it has no futBecomeFree for the close barrier to wait on.
    let pool = PgAsyncPool.new(storeMessageDbUrl, 1).expect("pool")

    check (
      await pool.runStmt(
        "stmtOverMissingTable",
        "SELECT * FROM a_table_that_does_not_exist",
        newSeq[string](0),
        newSeq[int32](0),
        newSeq[int32](0),
      )
    ).isErr()

    (await pool.close()).expect("pool close")

  asyncTest "The pool comes back after its connection died":
    let pool = PgAsyncPool.new(storeMessageDbUrl, 1).expect("pool")

    check (await pool.pgQuery("SELECT pg_terminate_backend(pg_backend_pid())")).isErr()

    (await pool.resetConnPool()).expect("resetConnPool")
    (await pool.pgQuery("SELECT 1")).expect("query after reset")

    (await pool.close()).expect("pool close")

  asyncTest "A pool that cannot be closed does not bring the node down":
    let pool = PgAsyncPool.new(storeMessageDbUrl, 1).expect("pool")

    check (await pool.pgQuery("SELECT pg_terminate_backend(pg_backend_pid())")).isErr()

    var fatalErrors = newSeq[string](0)
    proc onFatalError(errMsg: string) {.gcsafe, closure, raises: [].} =
      fatalErrors.add(errMsg)

    let healthFut = checkConnectivity(pool, onFatalError)
    await sleepAsync(1.seconds)

    check fatalErrors.len == 0

    await healthFut.cancelAndWait()
    (await pool.close()).expect("pool close")

  asyncTest "Queries waiting for the only connection never share it":
    ## Every waiter woken by the same release used to pick that connection,
    ## which libpq answered with "another command is already in progress".
    let pool = PgAsyncPool.new(storeMessageDbUrl, 1).expect("pool")

    var queries = newSeq[Future[Result[void, string]]](0)
    for _ in 0 ..< 5:
      queries.add(pool.pgQuery("SELECT pg_sleep(0.05)"))

    for queryFut in queries:
      (await queryFut).expect("queued query")

    (await pool.close()).expect("pool close")

  asyncTest "A cancelled query does not leave its connection unusable":
    let pool = PgAsyncPool.new(storeMessageDbUrl, 1).expect("pool")

    let slowFut = pool.pgQuery("SELECT pg_sleep(1)")
    await sleepAsync(100.milliseconds)
    await slowFut.cancelAndWait()

    let nextRes = await pool.pgQuery("SELECT 1").wait(5.seconds)
    check nextRes.isOk()

    (await pool.close()).expect("pool close")

  asyncTest "Connecting to an unresponsive server times out without blocking":
    ## Listening without accepting: the handshake completes in the kernel, but
    ## the server never answers the startup packet
    let silentServer = createStreamServer(initTAddress("127.0.0.1:0"))
    let port = silentServer.localAddress().port
    let pool = PgAsyncPool
      .new(
        "postgres://postgres:test123@127.0.0.1:" & $port & "/postgres",
        1,
        connectTimeout = 1.seconds,
      )
      .expect("pool")

    var maxGap = ZeroDuration
    var probing = true
    proc probe() {.async.} =
      var last = Moment.now()
      while probing:
        await sleepAsync(50.milliseconds)
        maxGap = max(maxGap, Moment.now() - last)
        last = Moment.now()

    let probeFut = probe()
    let queryRes = await pool.pgQuery("SELECT 1")
    probing = false
    await probeFut

    check:
      queryRes.isErr()
      queryRes.error.contains("timed out")
      maxGap < 500.milliseconds

    (await pool.close()).expect("pool close")
    await silentServer.closeWait()

  asyncTest "A pool with a statement timeout cancels long queries server-side":
    let pool = PgAsyncPool
      .new(storeMessageDbUrl, 1, statementTimeout = 200.milliseconds)
      .expect("pool")

    let sleepRes = await pool.pgQuery("SELECT pg_sleep(2)")
    check:
      sleepRes.isErr()
      sleepRes.error.contains("statement timeout")

    (await pool.pgQuery("SELECT 1")).expect("query after the timeout")

    (await pool.close()).expect("pool close")

  asyncTest "A cancelled query is also cancelled in the server":
    let pool = PgAsyncPool.new(storeMessageDbUrl, 1).expect("pool")
    let observer = PgAsyncPool.new(storeMessageDbUrl, 1).expect("observer pool")

    let slowFut = pool.pgQuery("SELECT pg_sleep(30) /* cancelled_sleep_marker */")
    await sleepAsync(200.milliseconds)
    await slowFut.cancelAndWait()

    var running = 1
    proc onRow(res: ptr PGresult) {.closure, gcsafe, raises: [].} =
      if pqntuples(res) > 0:
        try:
          running = parseInt($pqgetvalue(res, 0, 0))
        except ValueError:
          discard

    for _ in 0 ..< 50:
      (
        await observer.pgQuery(
          "SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%cancelled_sleep_marker%' AND query NOT LIKE '%pg_stat_activity%'",
          @[],
          onRow,
        )
      ).expect("observer query")
      if running == 0:
        break
      await sleepAsync(100.milliseconds)

    check running == 0

    (await pool.close()).expect("pool close")
    (await observer.close()).expect("observer close")

  asyncTest "A lock timeout asked for one call does not stay on the connection":
    let pool = PgAsyncPool.new(storeMessageDbUrl, 1).expect("pool")

    var shown = ""
    proc onRow(res: ptr PGresult) {.closure, gcsafe, raises: [].} =
      if pqntuples(res) > 0:
        shown = $pqgetvalue(res, 0, 0)

    (
      await pool.pgQuery(
        "SHOW lock_timeout", @[], onRow, lockTimeout = Opt.some(1.seconds)
      )
    ).expect("query with a lock timeout")
    check shown == "1s"

    (await pool.pgQuery("SHOW lock_timeout", @[], onRow)).expect("default query")
    check shown == "0"

    (await pool.close()).expect("pool close")

  asyncTest "Host names are resolved off the event loop":
    check (await resolveHostAddr("127.0.0.1")).expect("literal") == ""
    let addrs = (await resolveHostAddr("localhost")).expect("name").split(',')
    check:
      addrs.len > 0
      addrs.deduplicate().len == addrs.len
    check (await resolveHostAddr("host.invalid")).isErr()

  asyncTest "Several addresses for one host connect through the first reachable":
    let wrapper = (
      await DbConnWrapper.new(
        "user=postgres host=localhost,localhost hostaddr=127.0.0.1,127.0.0.1 port=5432 dbname=postgres password=test123"
      )
    ).expect("connection with two addresses")

    wrapper.closeDbConn().expect("close")

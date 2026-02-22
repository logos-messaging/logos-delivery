{.used.}

import std/[sequtils, times], results, testutils/unittests, chronos
import
  waku/[
    waku_core,
    waku_core/message/digest,
    waku_archive,
    waku_archive/retention_policy,
    waku_archive/retention_policy/retention_policy_capacity,
    waku_archive/retention_policy/retention_policy_size,
  ],
  ../waku_archive/archive_utils,
  ../testlib/wakucore

suite "Waku Archive - Retention policy":
  test "capacity retention policy - windowed message deletion":
    ## Given
    let
      capacity = 100
      excess = 60

    let driver = newSqliteArchiveDriver()

    let retentionPolicy: RetentionPolicy =
      CapacityRetentionPolicy.new(capacity = capacity)
    var putFutures = newSeq[Future[ArchiveDriverResult[void]]]()

    ## When
    for i in 1 .. capacity + excess:
      let msg = fakeWakuMessage(
        payload = @[byte i], contentTopic = DefaultContentTopic, ts = Timestamp(i)
      )
      putFutures.add(
        driver.put(computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg)
      )

    discard waitFor allFinished(putFutures)

    let res = waitFor retentionPolicy.execute(driver)
    assert res.isOk(), $res.error

    ## Then
    let numMessages = (waitFor driver.getMessagesCount()).tryGet()
    check:
      # Expected number of messages is 120 because
      # (capacity = 100) + (half of the overflow window = 15) + (5 messages added after after the last delete)
      # the window size changes when changing `const maxStoreOverflow = 1.3 in sqlite_store
      numMessages == 115

    ## Cleanup
    (waitFor driver.close()).expect("driver to close")

  test "size retention policy - windowed message deletion":
    ## Given
    let
      # in bytes
      sizeLimit: int64 = 52428
      excess = 325

    let driver = newSqliteArchiveDriver()

    let retentionPolicy: RetentionPolicy = SizeRetentionPolicy.new(size = sizeLimit)
    var putFutures = newSeq[Future[ArchiveDriverResult[void]]]()

    # make sure that the db is empty to before test begins
    let storedMsg = (waitFor driver.getAllMessages()).tryGet()
    # if there are messages in db, empty them
    if storedMsg.len > 0:
      let now = getNanosecondTime(getTime().toUnixFloat())
      require (waitFor driver.deleteMessagesOlderThanTimestamp(ts = now)).isOk()
      require (waitFor driver.performVacuum()).isOk()

    ## When
    ## 

    # create a number of messages so that the size of the DB overshoots
    for i in 1 .. excess:
      let msg = fakeWakuMessage(
        payload = @[byte i], contentTopic = DefaultContentTopic, ts = Timestamp(i)
      )
      putFutures.add(
        driver.put(computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg)
      )

    # waitFor is used to synchronously wait for the futures to complete.
    discard waitFor allFinished(putFutures)

    ## Then
    # calculate the current database size
    let sizeDB = int64((waitFor driver.getDatabaseSize()).tryGet())

    # NOTE: since vacuumin is done manually, this needs to be revisited if vacuuming done automatically

    # get the rows count pre-deletion
    let rowsCountBeforeDeletion = (waitFor driver.getMessagesCount()).tryGet()

    # execute policy provided the current db size oveflows, results in rows deletion
    require (sizeDB >= sizeLimit)
    require (waitFor retentionPolicy.execute(driver)).isOk()

    # get the number or rows from database
    let rowCountAfterDeletion = (waitFor driver.getMessagesCount()).tryGet()

    check:
      # size of the database is used to check if the storage limit has been preserved
      # check the current database size with the limitSize provided by the user
      # it should be lower
      rowCountAfterDeletion <= rowsCountBeforeDeletion

    ## Cleanup
    (waitFor driver.close()).expect("driver to close")

  test "store capacity should be limited":
    ## Given
    const capacity = 5
    const contentTopic = "test-content-topic"

    let
      driver = newSqliteArchiveDriver()
      retentionPolicy: RetentionPolicy =
        CapacityRetentionPolicy.new(capacity = capacity)

    let messages = @[
      fakeWakuMessage(contentTopic = DefaultContentTopic, ts = ts(0)),
      fakeWakuMessage(contentTopic = DefaultContentTopic, ts = ts(1)),
      fakeWakuMessage(contentTopic = contentTopic, ts = ts(2)),
      fakeWakuMessage(contentTopic = contentTopic, ts = ts(3)),
      fakeWakuMessage(contentTopic = contentTopic, ts = ts(4)),
      fakeWakuMessage(contentTopic = contentTopic, ts = ts(5)),
      fakeWakuMessage(contentTopic = contentTopic, ts = ts(6)),
    ]

    ## When
    for msg in messages:
      require (
        waitFor driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()
      require (waitFor retentionPolicy.execute(driver)).isOk()

    ## Then
    let storedMsg = (waitFor driver.getAllMessages()).tryGet()
    check:
      storedMsg.len == capacity
      storedMsg.all do(item: auto) -> bool:
        let (_, pubsubTopic, msg) = item
        msg.contentTopic == contentTopic and pubsubTopic == DefaultPubsubTopic

    ## Cleanup
    (waitFor driver.close()).expect("driver to close")

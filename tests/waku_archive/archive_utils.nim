{.used.}

import results, chronos, libp2p/crypto/crypto

import
  logos_delivery/waku/[
    node/peer_manager,
    waku_core,
    waku_archive,
    waku_archive/driver/sqlite_driver,
    waku_archive/driver/sqlite_driver/migrations,
    common/databases/db_sqlite,
  ],
  ../testlib/[wakucore]

proc newSqliteDatabase*(path: Opt[string] = Opt.none(string)): SqliteDatabase =
  SqliteDatabase.new(path.get(":memory:")).tryGet()

proc newSqliteArchiveDriver*(): ArchiveDriver =
  let database = newSqliteDatabase()
  migrate(database).tryGet()
  return SqliteDriver.new(database).tryGet()

proc newWakuArchive*(driver: ArchiveDriver): WakuArchive =
  WakuArchive.new(driver).get()

type FailingArchiveDriver* = ref object of ArchiveDriver
  ## Refuses every write, which is what a node with a broken database does.

method put*(
    driver: FailingArchiveDriver,
    messageHash: WakuMessageHash,
    pubsubTopic: PubsubTopic,
    message: WakuMessage,
): Future[ArchiveDriverResult[void]] {.async.} =
  return err("failing archive driver stub")

proc newFailingArchiveDriver*(): ArchiveDriver =
  return FailingArchiveDriver()

proc put*(
    driver: ArchiveDriver, pubsubTopic: PubSubTopic, msgList: seq[WakuMessage]
): ArchiveDriver =
  for msg in msgList:
    let _ = waitFor driver.put(computeMessageHash(pubsubTopic, msg), pubsubTopic, msg)
  return driver

proc newArchiveDriverWithMessages*(
    pubsubTopic: PubSubTopic, msgList: seq[WakuMessage]
): ArchiveDriver =
  var driver = newSqliteArchiveDriver()
  driver = driver.put(pubsubTopic, msgList)
  return driver

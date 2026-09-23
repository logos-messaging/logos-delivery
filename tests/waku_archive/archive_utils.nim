{.used.}

import std/sets, results, chronos, metrics, libp2p/crypto/crypto

import
  logos_delivery/waku/[
    node/peer_manager,
    waku_core,
    waku_archive,
    waku_archive/archive_metrics,
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

proc insertCount*(source: string): float64 =
  ## `value(labelValues = ...)` ignores the label selector in metrics 0.2.1 and
  ## answers with whichever child was created first, so the series has to be
  ## read by name. Counters are registered with the '_total' suffix.
  try:
    return logos_delivery_archive_inserts.valueByName(
      "logos_delivery_archive_inserts_total", [source]
    )
  except ValueError:
    return 0.0

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
): Future[ArchiveDriver] {.async.} =
  for msg in msgList:
    let _ = await driver.put(computeMessageHash(pubsubTopic, msg), pubsubTopic, msg)
  return driver

proc holdsMessages*(
    archive: WakuArchive, hashes: seq[WakuMessageHash]
): Future[bool] {.async.} =
  let response = (
    await archive.findMessages(ArchiveQuery(hashes: hashes, pageSize: uint(hashes.len)))
  ).valueOr:
    return false
  return response.hashes.toHashSet() == hashes.toHashSet()

proc newArchiveDriverWithMessages*(
    pubsubTopic: PubSubTopic, msgList: seq[WakuMessage]
): Future[ArchiveDriver] {.async.} =
  var driver = newSqliteArchiveDriver()
  driver = await driver.put(pubsubTopic, msgList)
  return driver

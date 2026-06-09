# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim
{.push raises: [].}

import std/options, stew/byteutils, chronicles, chronos, results
import
  ../../../common/databases/db_sqlite,
  ../../../waku_core,
  ../../../waku_core/message/digest,
  ../../common,
  ../../driver,
  ./queries

logScope:
  topics = "waku archive sqlite"

proc init(db: SqliteDatabase): ArchiveDriverResult[void] =
  ## Misconfiguration can lead to nil DB
  if db.isNil():
    return err("db not initialized")

  # Create table, if doesn't exist
  createTable(db).isOkOr:
    return err("failed to create table: " & error)

  # Create indices, if don't exist
  createOldestMessageTimestampIndex(db).isOkOr:
    return err("failed to create i_ts index: " & error)

  return ok()

type SqliteDriver* = ref object of ArchiveDriver
  db: SqliteDatabase
  insertStmt: SqliteStmt[InsertMessageParams, void]

proc new*(T: type SqliteDriver, db: SqliteDatabase): ArchiveDriverResult[T] =
  # Database initialization
  ?init(db)

  # General initialization
  let insertStmt = db.prepareInsertMessageStmt()
  return ok(SqliteDriver(db: db, insertStmt: insertStmt))

method put*(
    s: SqliteDriver,
    messageHash: WakuMessageHash,
    pubsubTopic: PubsubTopic,
    message: WakuMessage,
): Future[ArchiveDriverResult[void]] {.async.} =
  ## Inserts a message into the store
  let res = s.insertStmt.exec(
    (
      @(messageHash),
      toBytes(pubsubTopic),
      toBytes(message.contentTopic),
      message.payload,
      int64(message.version),
      message.timestamp,
      message.meta,
    )
  )

  return res

method getAllMessages*(
    s: SqliteDriver
): Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =
  ## Retrieve all messages from the store.
  return s.db.selectAllMessages()

method getMessages*(
    s: SqliteDriver,
    includeData = true,
    contentTopics = newSeq[ContentTopic](0),
    pubsubTopic = none(PubsubTopic),
    cursor = none(ArchiveCursor),
    startTime = none(Timestamp),
    endTime = none(Timestamp),
    hashes = newSeq[WakuMessageHash](0),
    maxPageSize = DefaultPageSize,
    ascendingOrder = true,
    requestId = "",
): Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =
  if not includeData:
    return s.db.selectMessageHashesByStoreQueryWithLimit(
      contentTopics,
      pubsubTopic,
      cursor,
      startTime,
      endTime,
      hashes,
      limit = maxPageSize,
      ascending = ascendingOrder,
    )

  return s.db.selectMessagesByStoreQueryWithLimit(
    contentTopics,
    pubsubTopic,
    cursor,
    startTime,
    endTime,
    hashes,
    limit = maxPageSize,
    ascending = ascendingOrder,
  )

method getMessagesCount*(
    s: SqliteDriver
): Future[ArchiveDriverResult[int64]] {.async.} =
  return s.db.getMessageCount()

method getPagesCount*(s: SqliteDriver): Future[ArchiveDriverResult[int64]] {.async.} =
  return s.db.getPageCount()

method getPagesSize*(s: SqliteDriver): Future[ArchiveDriverResult[int64]] {.async.} =
  return s.db.getPageSize()

method getDatabaseSize*(s: SqliteDriver): Future[ArchiveDriverResult[int64]] {.async.} =
  return s.db.getDatabaseSize()

method performVacuum*(s: SqliteDriver): Future[ArchiveDriverResult[void]] {.async.} =
  return s.db.performSqliteVacuum()

method getOldestMessageTimestamp*(
    s: SqliteDriver
): Future[ArchiveDriverResult[Timestamp]] {.async.} =
  return s.db.selectOldestTimestamp()

method getNewestMessageTimestamp*(
    s: SqliteDriver
): Future[ArchiveDriverResult[Timestamp]] {.async.} =
  return s.db.selectnewestTimestamp()

method deleteMessagesOlderThanTimestamp*(
    s: SqliteDriver, ts: Timestamp
): Future[ArchiveDriverResult[void]] {.async.} =
  return s.db.deleteMessagesOlderThanTimestamp(ts)

method deleteOldestMessagesNotWithinLimit*(
    s: SqliteDriver, limit: int
): Future[ArchiveDriverResult[void]] {.async.} =
  return s.db.deleteOldestMessagesNotWithinLimit(limit)

method decreaseDatabaseSize*(
    driver: SqliteDriver, targetSizeInBytes: int64, forceRemoval: bool = false
): Future[ArchiveDriverResult[void]] {.async.} =
  ## To remove 20% of the outdated data from database
  const DeleteLimit = 0.80

  ## when db size overshoots the database limit, shread 20% of outdated messages
  ## get size of database
  let dbSize = (await driver.getDatabaseSize()).valueOr:
    return err("failed to get database size: " & $error)

  ## database size in bytes
  let totalSizeOfDB: int64 = int64(dbSize)

  if totalSizeOfDB < targetSizeInBytes:
    return ok()

  ## to shread/delete messsges, get the total row/message count
  let numMessages = (await driver.getMessagesCount()).valueOr:
    return err("failed to get messages count: " & error)

  ## NOTE: Using SQLite vacuuming is done manually, we delete a percentage of rows
  ## if vacumming is done automatically then we aim to check DB size periodially for efficient
  ## retention policy implementation.

  ## 80% of the total messages are to be kept, delete others
  let pageDeleteWindow = int(float(numMessages) * DeleteLimit)

  (await driver.deleteOldestMessagesNotWithinLimit(limit = pageDeleteWindow)).isOkOr:
    return err("deleting oldest messages failed: " & error)

  return ok()

method close*(s: SqliteDriver): Future[ArchiveDriverResult[void]] {.async.} =
  ## Close the database connection
  # Dispose statements
  s.insertStmt.dispose()
  # Close connection
  s.db.close()
  return ok()

method existsTable*(
    s: SqliteDriver, tableName: string
): Future[ArchiveDriverResult[bool]] {.async.} =
  return err("existsTable method not implemented in sqlite_driver")

{.push raises: [].}

import std/[options, sequtils], stew/byteutils, sqlite3_abi, results
import chronicles
import
  ../../../common/databases/db_sqlite,
  ../../../common/databases/common,
  ../../../waku_core

const DbTable = "Message"

type SqlQueryStr = string

### SQLite column helper methods

proc queryRowWakuMessageCallback(
    s: ptr sqlite3_stmt,
    contentTopicCol, payloadCol, versionCol, timestampCol, metaCol: cint,
): WakuMessage =
  let
    topic = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, contentTopicCol))
    topicLength = sqlite3_column_bytes(s, contentTopicCol)
    contentTopic = string.fromBytes(@(toOpenArray(topic, 0, topicLength - 1)))

    p = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, payloadCol))
    m = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, metaCol))

    payloadLength = sqlite3_column_bytes(s, payloadCol)
    metaLength = sqlite3_column_bytes(s, metaCol)
    payload = @(toOpenArray(p, 0, payloadLength - 1))
    version = sqlite3_column_int64(s, versionCol)
    timestamp = sqlite3_column_int64(s, timestampCol)
    meta = @(toOpenArray(m, 0, metaLength - 1))

  return WakuMessage(
    contentTopic: ContentTopic(contentTopic),
    payload: payload,
    version: uint32(version),
    timestamp: Timestamp(timestamp),
    meta: meta,
  )

proc queryRowTimestampCallback(s: ptr sqlite3_stmt, timestampCol: cint): Timestamp =
  let timestamp = sqlite3_column_int64(s, timestampCol)
  return Timestamp(timestamp)

proc queryRowPubsubTopicCallback(
    s: ptr sqlite3_stmt, pubsubTopicCol: cint
): PubsubTopic =
  let
    pubsubTopicPointer =
      cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, pubsubTopicCol))
    pubsubTopicLength = sqlite3_column_bytes(s, pubsubTopicCol)
    pubsubTopic =
      string.fromBytes(@(toOpenArray(pubsubTopicPointer, 0, pubsubTopicLength - 1)))

  return pubsubTopic

proc queryRowWakuMessageHashCallback(
    s: ptr sqlite3_stmt, hashCol: cint
): WakuMessageHash =
  let
    hashPointer = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, hashCol))
    hashLength = sqlite3_column_bytes(s, hashCol)
    hash = fromBytes(toOpenArray(hashPointer, 0, hashLength - 1))

  return hash

### SQLite queries

## Create table

proc createTableQuery(table: string): SqlQueryStr =
  "CREATE TABLE IF NOT EXISTS " & table & " (" &
    " messageHash BLOB NOT NULL PRIMARY KEY," & " pubsubTopic BLOB NOT NULL," &
    " contentTopic BLOB NOT NULL," & " payload BLOB," & " version INTEGER NOT NULL," &
    " timestamp INTEGER NOT NULL," & " meta BLOB" & ") WITHOUT ROWID;"

proc createTable*(db: SqliteDatabase): DatabaseResult[void] =
  let query = createTableQuery(DbTable)
  discard ?db.query(
    query,
    proc(s: ptr sqlite3_stmt) =
      discard,
  )
  return ok()

## Create indices

proc createOldestMessageTimestampIndexQuery(table: string): SqlQueryStr =
  "CREATE INDEX IF NOT EXISTS i_ts ON " & table & " (timestamp);"

proc createOldestMessageTimestampIndex*(db: SqliteDatabase): DatabaseResult[void] =
  let query = createOldestMessageTimestampIndexQuery(DbTable)
  discard ?db.query(
    query,
    proc(s: ptr sqlite3_stmt) =
      discard,
  )
  return ok()

## Insert message
type InsertMessageParams* =
  (seq[byte], seq[byte], seq[byte], seq[byte], int64, Timestamp, seq[byte])

proc insertMessageQuery(table: string): SqlQueryStr =
  return
    "INSERT INTO " & table &
    "(messageHash, pubsubTopic, contentTopic, payload, version, timestamp, meta)" &
    " VALUES (?, ?, ?, ?, ?, ?, ?);"

proc prepareInsertMessageStmt*(
    db: SqliteDatabase
): SqliteStmt[InsertMessageParams, void] =
  let query = insertMessageQuery(DbTable)
  return
    db.prepareStmt(query, InsertMessageParams, void).expect("this is a valid statement")

## Count table messages

proc countMessagesQuery(table: string): SqlQueryStr =
  return "SELECT COUNT(*) FROM " & table

proc getMessageCount*(db: SqliteDatabase): DatabaseResult[int64] =
  var count: int64
  proc queryRowCallback(s: ptr sqlite3_stmt) =
    count = sqlite3_column_int64(s, 0)

  let query = countMessagesQuery(DbTable)
  db.query(query, queryRowCallback).isOkOr:
    return err("failed to count number of messages in the database")

  return ok(count)

## Get oldest message receiver timestamp

proc selectOldestMessageTimestampQuery(table: string): SqlQueryStr =
  return "SELECT MIN(timestamp) FROM " & table

proc selectOldestTimestamp*(db: SqliteDatabase): DatabaseResult[Timestamp] {.inline.} =
  var timestamp: Timestamp
  proc queryRowCallback(s: ptr sqlite3_stmt) =
    timestamp = queryRowTimestampCallback(s, 0)

  let query = selectOldestMessageTimestampQuery(DbTable)
  db.query(query, queryRowCallback).isOkOr:
    return err("failed to get the oldest receiver timestamp from the database")

  return ok(timestamp)

## Get newest message receiver timestamp

proc selectNewestMessageTimestampQuery(table: string): SqlQueryStr =
  return "SELECT MAX(timestamp) FROM " & table

proc selectNewestTimestamp*(db: SqliteDatabase): DatabaseResult[Timestamp] {.inline.} =
  var timestamp: Timestamp
  proc queryRowCallback(s: ptr sqlite3_stmt) =
    timestamp = queryRowTimestampCallback(s, 0)

  let query = selectNewestMessageTimestampQuery(DbTable)
  db.query(query, queryRowCallback).isOkOr:
    return err("failed to get the newest receiver timestamp from the database")

  return ok(timestamp)

## Delete messages older than timestamp

proc deleteMessagesOlderThanTimestampQuery(table: string, ts: Timestamp): SqlQueryStr =
  return "DELETE FROM " & table & " WHERE timestamp < " & $ts

proc deleteMessagesOlderThanTimestamp*(
    db: SqliteDatabase, ts: int64
): DatabaseResult[void] =
  let query = deleteMessagesOlderThanTimestampQuery(DbTable, ts)
  discard ?db.query(
    query,
    proc(s: ptr sqlite3_stmt) =
      discard,
  )
  return ok()

## Delete oldest messages not within limit

proc deleteOldestMessagesNotWithinLimitQuery(table: string, limit: int): SqlQueryStr =
  return
    "DELETE FROM " & table & " WHERE (timestamp, messageHash) NOT IN (" &
    " SELECT timestamp, messageHash FROM " & table &
    " ORDER BY timestamp DESC, messageHash DESC" & " LIMIT " & $limit & ");"

proc deleteOldestMessagesNotWithinLimit*(
    db: SqliteDatabase, limit: int
): DatabaseResult[void] =
  # NOTE: The word `limit` here refers the store capacity/maximum number-of-messages allowed limit
  let query = deleteOldestMessagesNotWithinLimitQuery(DbTable, limit = limit)
  discard ?db.query(
    query,
    proc(s: ptr sqlite3_stmt) =
      discard,
  )
  return ok()

## Select all messages

proc selectAllMessagesQuery(table: string): SqlQueryStr =
  return
    "SELECT messageHash, pubsubTopic, contentTopic, payload, version, timestamp, meta" &
    " FROM " & table & " ORDER BY timestamp ASC"

proc selectAllMessages*(
    db: SqliteDatabase
): DatabaseResult[seq[(WakuMessageHash, PubsubTopic, WakuMessage)]] =
  ## Retrieve all messages from the store.
  var rows: seq[(WakuMessageHash, PubsubTopic, WakuMessage)]
  proc queryRowCallback(s: ptr sqlite3_stmt) =
    let
      hash = queryRowWakuMessageHashCallback(s, hashCol = 0)
      pubsubTopic = queryRowPubsubTopicCallback(s, pubsubTopicCol = 1)
      wakuMessage = queryRowWakuMessageCallback(
        s,
        contentTopicCol = 2,
        payloadCol = 3,
        versionCol = 4,
        timestampCol = 5,
        metaCol = 6,
      )

    rows.add((hash, pubsubTopic, wakuMessage))

  let query = selectAllMessagesQuery(DbTable)
  db.query(query, queryRowCallback).isOkOr:
    return err("select all messages failed: " & $error)

  return ok(rows)

## Select all messages without data

proc selectAllMessageHashesQuery(table: string): SqlQueryStr =
  return "SELECT messageHash" & " FROM " & table & " ORDER BY timestamp ASC"

proc selectAllMessageHashes*(db: SqliteDatabase): DatabaseResult[seq[WakuMessageHash]] =
  ## Retrieve all messages from the store.
  var rows: seq[WakuMessageHash]
  proc queryRowCallback(s: ptr sqlite3_stmt) =
    let hash = queryRowWakuMessageHashCallback(s, hashCol = 0)
    rows.add(hash)

  let query = selectAllMessageHashesQuery(DbTable)
  db.query(query, queryRowCallback).isOkOr:
    return err("select all message hashes failed: " & $error)

  return ok(rows)

## Select messages by history query with limit

proc combineClauses(clauses: varargs[Option[string]]): Option[string] =
  let whereSeq = @clauses.filterIt(it.isSome()).mapIt(it.get())
  if whereSeq.len <= 0:
    return none(string)

  var where: string = whereSeq[0]
  for clause in whereSeq[1 ..^ 1]:
    where &= " AND " & clause
  return some(where)

proc prepareStmt(
    db: SqliteDatabase, stmt: string
): DatabaseResult[SqliteStmt[void, void]] =
  var s: RawStmtPtr
  checkErr sqlite3_prepare_v2(db.env, stmt, stmt.len.cint, addr s, nil)
  return ok(SqliteStmt[void, void](s))

proc execSelectMessageByHash(
    s: SqliteStmt, hash: WakuMessageHash, onRowCallback: DataProc
): DatabaseResult[void] =
  let s = RawStmtPtr(s)

  checkErr bindParam(s, 1, toSeq(hash))

  try:
    while true:
      let v = sqlite3_step(s)
      case v
      of SQLITE_ROW:
        onRowCallback(s)
      of SQLITE_DONE:
        return ok()
      else:
        return err($sqlite3_errstr(v))
  except Exception, CatchableError:
    error "exception in execSelectMessageByHash", error = getCurrentExceptionMsg()

  # release implicit transaction
  discard sqlite3_reset(s) # same return information as step
  discard sqlite3_clear_bindings(s) # no errors possible

proc selectTimestampByHashQuery(table: string): SqlQueryStr =
  return "SELECT timestamp FROM " & table & " WHERE messageHash = (?)"

proc getCursorTimestamp(
    db: SqliteDatabase, hash: WakuMessageHash
): DatabaseResult[Option[Timestamp]] =
  var timestamp = none(Timestamp)

  proc queryRowCallback(s: ptr sqlite3_stmt) =
    timestamp = some(queryRowTimestampCallback(s, 0))

  let query = selectTimestampByHashQuery(DbTable)
  let dbStmt = ?db.prepareStmt(query)
  ?dbStmt.execSelectMessageByHash(hash, queryRowCallback)
  dbStmt.dispose()

  return ok(timestamp)

proc whereClause(
    cursor: bool,
    pubsubTopic: Option[PubsubTopic],
    contentTopic: seq[ContentTopic],
    startTime: Option[Timestamp],
    endTime: Option[Timestamp],
    hashes: seq[WakuMessageHash],
    ascending: bool,
): Option[string] =
  let cursorClause =
    if cursor:
      let comp = if ascending: ">" else: "<"

      some("(timestamp, messageHash) " & comp & " (?, ?)")
    else:
      none(string)

  let pubsubTopicClause =
    if pubsubTopic.isNone():
      none(string)
    else:
      some("pubsubTopic = (?)")

  let contentTopicClause =
    if contentTopic.len <= 0:
      none(string)
    else:
      var where = "contentTopic IN ("
      where &= "?"
      for _ in 1 ..< contentTopic.len:
        where &= ", ?"
      where &= ")"
      some(where)

  let startTimeClause =
    if startTime.isNone():
      none(string)
    else:
      some("timestamp >= (?)")

  let endTimeClause =
    if endTime.isNone():
      none(string)
    else:
      some("timestamp <= (?)")

  let hashesClause =
    if hashes.len <= 0:
      none(string)
    else:
      var where = "messageHash IN ("
      where &= "?"
      for _ in 1 ..< hashes.len:
        where &= ", ?"
      where &= ")"
      some(where)

  return combineClauses(
    cursorClause, pubsubTopicClause, contentTopicClause, startTimeClause, endTimeClause,
    hashesClause,
  )

proc execSelectMessagesWithLimitStmt(
    s: SqliteStmt,
    cursor: Option[(Timestamp, WakuMessageHash)],
    pubsubTopic: Option[PubsubTopic],
    contentTopic: seq[ContentTopic],
    startTime: Option[Timestamp],
    endTime: Option[Timestamp],
    hashes: seq[WakuMessageHash],
    onRowCallback: DataProc,
): DatabaseResult[void] =
  let s = RawStmtPtr(s)

  # Bind params
  var paramIndex = 1

  if cursor.isSome():
    let (time, hash) = cursor.get()
    checkErr bindParam(s, paramIndex, time)
    paramIndex += 1
    checkErr bindParam(s, paramIndex, toSeq(hash))
    paramIndex += 1

  if pubsubTopic.isSome():
    let pubsubTopic = toBytes(pubsubTopic.get())
    checkErr bindParam(s, paramIndex, pubsubTopic)
    paramIndex += 1

  for topic in contentTopic:
    checkErr bindParam(s, paramIndex, topic.toBytes())
    paramIndex += 1

  for hash in hashes:
    checkErr bindParam(s, paramIndex, toSeq(hash))
    paramIndex += 1

  if startTime.isSome():
    let time = startTime.get()
    checkErr bindParam(s, paramIndex, time)
    paramIndex += 1

  if endTime.isSome():
    let time = endTime.get()
    checkErr bindParam(s, paramIndex, time)
    paramIndex += 1

  try:
    while true:
      let v = sqlite3_step(s)
      case v
      of SQLITE_ROW:
        onRowCallback(s)
      of SQLITE_DONE:
        return ok()
      else:
        return err($sqlite3_errstr(v))
  except Exception, CatchableError:
    error "exception in execSelectMessagesWithLimitStmt",
      error = getCurrentExceptionMsg()

  # release implicit transaction
  discard sqlite3_reset(s) # same return information as step
  discard sqlite3_clear_bindings(s) # no errors possible

proc selectMessagesWithLimitQuery(
    table: string, where: Option[string], limit: uint, ascending = true
): SqlQueryStr =
  let order = if ascending: "ASC" else: "DESC"

  var query: string

  query =
    "SELECT messageHash, pubsubTopic, contentTopic, payload, version, timestamp, meta"
  query &= " FROM " & table

  if where.isSome():
    query &= " WHERE " & where.get()

  query &= " ORDER BY timestamp " & order & ", messageHash " & order

  query &= " LIMIT " & $limit & ";"

  return query

proc selectMessageHashesWithLimitQuery(
    table: string, where: Option[string], limit: uint, ascending = true
): SqlQueryStr =
  let order = if ascending: "ASC" else: "DESC"

  var query = "SELECT messageHash FROM " & table

  if where.isSome():
    query &= " WHERE " & where.get()

  query &= " ORDER BY timestamp " & order & ", messageHash " & order

  query &= " LIMIT " & $limit & ";"

  return query

proc selectMessagesByStoreQueryWithLimit*(
    db: SqliteDatabase,
    contentTopic: seq[ContentTopic],
    pubsubTopic: Option[PubsubTopic],
    cursor: Option[WakuMessageHash],
    startTime: Option[Timestamp],
    endTime: Option[Timestamp],
    hashes: seq[WakuMessageHash],
    limit: uint,
    ascending: bool,
): DatabaseResult[seq[(WakuMessageHash, PubsubTopic, WakuMessage)]] =
  var timeCursor = none((Timestamp, WakuMessageHash))

  if cursor.isSome():
    let hash: WakuMessageHash = cursor.get()

    let timeOpt = ?getCursorTimestamp(db, hash)

    if timeOpt.isNone():
      return err("cursor not found")

    timeCursor = some((timeOpt.get(), hash))

  var rows: seq[(WakuMessageHash, PubsubTopic, WakuMessage)] = @[]

  proc queryRowCallback(s: ptr sqlite3_stmt) =
    let
      hash = queryRowWakuMessageHashCallback(s, hashCol = 0)
      pubsubTopic = queryRowPubsubTopicCallback(s, pubsubTopicCol = 1)
      message = queryRowWakuMessageCallback(
        s,
        contentTopicCol = 2,
        payloadCol = 3,
        versionCol = 4,
        timestampCol = 5,
        metaCol = 6,
      )

    rows.add((hash, pubsubTopic, message))

  let where = whereClause(
    timeCursor.isSome(),
    pubsubTopic,
    contentTopic,
    startTime,
    endTime,
    hashes,
    ascending,
  )

  let query = selectMessagesWithLimitQuery(DbTable, where, limit, ascending)

  let dbStmt = ?db.prepareStmt(query)
  ?dbStmt.execSelectMessagesWithLimitStmt(
    timeCursor, pubsubTopic, contentTopic, startTime, endTime, hashes, queryRowCallback
  )
  dbStmt.dispose()

  return ok(rows)

proc selectMessageHashesByStoreQueryWithLimit*(
    db: SqliteDatabase,
    contentTopic: seq[ContentTopic],
    pubsubTopic: Option[PubsubTopic],
    cursor: Option[WakuMessageHash],
    startTime: Option[Timestamp],
    endTime: Option[Timestamp],
    hashes: seq[WakuMessageHash],
    limit: uint,
    ascending: bool,
): DatabaseResult[seq[(WakuMessageHash, PubsubTopic, WakuMessage)]] =
  var timeCursor = none((Timestamp, WakuMessageHash))

  if cursor.isSome():
    let hash: WakuMessageHash = cursor.get()

    let timeOpt = ?getCursorTimestamp(db, hash)

    if timeOpt.isNone():
      return err("cursor not found")

    timeCursor = some((timeOpt.get(), hash))

  var rows: seq[(WakuMessageHash, PubsubTopic, WakuMessage)] = @[]

  proc queryRowCallback(s: ptr sqlite3_stmt) =
    let hash = queryRowWakuMessageHashCallback(s, hashCol = 0)
    rows.add((hash, "", WakuMessage()))

  let where = whereClause(
    timeCursor.isSome(),
    pubsubTopic,
    contentTopic,
    startTime,
    endTime,
    hashes,
    ascending,
  )

  let query = selectMessageHashesWithLimitQuery(DbTable, where, limit, ascending)

  let dbStmt = ?db.prepareStmt(query)
  ?dbStmt.execSelectMessagesWithLimitStmt(
    timeCursor, pubsubTopic, contentTopic, startTime, endTime, hashes, queryRowCallback
  )
  dbStmt.dispose()

  return ok(rows)

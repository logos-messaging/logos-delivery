## Synchronous SQLite backend for the persistency library.
##
## Plain procs against a SqliteDatabase connection. Phase 3 wraps these in
## per-job storage threads driven by brokers; phase 2 verifies the SQL
## itself against an in-memory database.

import std/options
import results, sqlite3_abi
import ../common/databases/[common, db_sqlite]
import ./[types, schema]

type
  KvBackend* = ref object
    db*: SqliteDatabase
    putStmt: SqliteStmt[(seq[byte], seq[byte], seq[byte]), void]
    deleteStmt: SqliteStmt[(seq[byte], seq[byte]), void]

  RowHandler = proc(s: ptr sqlite3_stmt) {.gcsafe, raises: [].}

proc toErr(msg: string): PersistencyError {.inline.} =
  persistencyErr(peBackend, msg)

proc catBytes(category: string): seq[byte] =
  var buf = newSeq[byte](category.len)
  for i, c in category:
    buf[i] = byte(c)
  return buf

proc keyBytes(key: Key): seq[byte] {.inline.} =
  bytes(key)

proc readBlob(s: ptr sqlite3_stmt, col: cint): seq[byte] =
  let n = sqlite3_column_bytes(s, col)
  var buf = newSeq[byte](n)
  if n > 0:
    let src = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, col))
    for i in 0 ..< n:
      buf[i] = src[i]
  return buf

proc bindBlob(s: ptr sqlite3_stmt, n: cint, val: seq[byte]): cint =
  if val.len > 0:
    sqlite3_bind_blob(s, n, unsafeAddr val[0], val.len.cint, SQLITE_TRANSIENT)
  else:
    sqlite3_bind_blob(s, n, nil, 0.cint, SQLITE_TRANSIENT)

proc runRead(
    db: SqliteDatabase, sql: string, params: openArray[seq[byte]], onRow: RowHandler
): Result[void, PersistencyError] =
  var s: ptr sqlite3_stmt
  let rc = sqlite3_prepare_v2(db.env, sql.cstring, sql.len.cint, addr s, nil)
  if rc != SQLITE_OK:
    return err(toErr("prepare: " & $sqlite3_errstr(rc)))
  defer:
    discard sqlite3_finalize(s)

  for i, p in params:
    let bc = bindBlob(s, cint(i + 1), p)
    if bc != SQLITE_OK:
      return err(toErr("bind: " & $sqlite3_errstr(bc)))

  while true:
    let v = sqlite3_step(s)
    case v
    of SQLITE_ROW:
      onRow(s)
    of SQLITE_DONE:
      break
    else:
      return err(toErr("step: " & $sqlite3_errstr(v)))
  return ok()

proc prepareStatements(b: KvBackend): DatabaseResult[void] =
  b.putStmt = ?b.db.prepareStmt(
    "INSERT OR REPLACE INTO kv(category, key, payload) VALUES (?, ?, ?);",
    (seq[byte], seq[byte], seq[byte]),
    void,
  )
  b.deleteStmt = ?b.db.prepareStmt(
    "DELETE FROM kv WHERE category = ? AND key = ?;", (seq[byte], seq[byte]), void
  )
  return ok()

proc openBackend*(path: string): Result[KvBackend, PersistencyError] =
  let dbRes = SqliteDatabase.new(path)
  if dbRes.isErr:
    return err(toErr("open " & path & " failed: " & dbRes.error))
  let db = dbRes.get()

  applyPragmas(db).isOkOr:
    return err(toErr(error))
  ensureSchema(db).isOkOr:
    return err(toErr(error))

  let b = KvBackend(db: db)
  prepareStatements(b).isOkOr:
    return err(toErr(error))
  return ok(b)

proc openBackendInMemory*(): Result[KvBackend, PersistencyError] =
  ## Convenience for tests.
  let dbRes = SqliteDatabase.new(":memory:")
  if dbRes.isErr:
    return err(toErr("open :memory: failed: " & dbRes.error))
  let db = dbRes.get()

  applyPragmas(db).isOkOr:
    return err(toErr(error))
  ensureSchema(db).isOkOr:
    return err(toErr(error))

  let b = KvBackend(db: db)
  prepareStatements(b).isOkOr:
    return err(toErr(error))
  return ok(b)

proc close*(b: KvBackend) =
  if b.db != nil:
    dispose(b.putStmt)
    dispose(b.deleteStmt)
    b.db.close()
    b.db = nil

proc applyOne(b: KvBackend, op: TxOp): Result[void, PersistencyError] =
  case op.kind
  of txPut:
    let r = b.putStmt.exec((catBytes(op.category), keyBytes(op.key), op.payload))
    if r.isErr:
      return err(toErr("put failed: " & r.error))
  of txDelete:
    let r = b.deleteStmt.exec((catBytes(op.category), keyBytes(op.key)))
    if r.isErr:
      return err(toErr("delete failed: " & r.error))
  return ok()

proc execSql(b: KvBackend, sql: string): Result[void, PersistencyError] =
  let r = b.db.query(sql, NoopRowHandler)
  if r.isErr:
    return err(toErr(sql & ": " & r.error))
  return ok()

proc applyOps*(b: KvBackend, ops: openArray[TxOp]): Result[void, PersistencyError] =
  ## Single op = auto-commit. Multiple ops = BEGIN IMMEDIATE / COMMIT, with
  ## ROLLBACK on first failure. This is the single source of truth for write
  ## SQL — Phase 3's PersistEvent listener calls straight into here.
  if ops.len == 0:
    return ok()
  if ops.len == 1:
    return b.applyOne(ops[0])

  ?b.execSql("BEGIN IMMEDIATE;")
  for op in ops:
    let r = b.applyOne(op)
    if r.isErr:
      discard b.execSql("ROLLBACK;")
      return r
  ?b.execSql("COMMIT;")
  return ok()

proc getOne*(
    b: KvBackend, category: string, key: Key
): Result[Option[seq[byte]], PersistencyError] =
  var found: Option[seq[byte]] = none(seq[byte])
  proc onRow(rs: ptr sqlite3_stmt) {.gcsafe, raises: [].} =
    found = some(readBlob(rs, 0.cint))

  ?b.db.runRead(
    "SELECT payload FROM kv WHERE category = ? AND key = ? LIMIT 1;",
    [catBytes(category), keyBytes(key)],
    onRow,
  )
  return ok(found)

proc existsOne*(
    b: KvBackend, category: string, key: Key
): Result[bool, PersistencyError] =
  var present = false
  proc onRow(rs: ptr sqlite3_stmt) {.gcsafe, raises: [].} =
    present = true

  ?b.db.runRead(
    "SELECT 1 FROM kv WHERE category = ? AND key = ? LIMIT 1;",
    [catBytes(category), keyBytes(key)],
    onRow,
  )
  return ok(present)

proc deleteOne*(
    b: KvBackend, category: string, key: Key
): Result[bool, PersistencyError] =
  ## Returns true if a row was actually removed.
  let existed = ?b.existsOne(category, key)
  if not existed:
    return ok(false)
  let r = b.deleteStmt.exec((catBytes(category), keyBytes(key)))
  if r.isErr:
    return err(toErr("delete: " & r.error))
  return ok(true)

proc scanRange*(
    b: KvBackend, category: string, range: KeyRange, reverse = false
): Result[seq[KvRow], PersistencyError] =
  let openEnded = bytes(range.stop).len == 0
  let direction = if reverse: "DESC" else: "ASC"
  let sql =
    if openEnded:
      "SELECT key, payload FROM kv WHERE category = ? AND key >= ? ORDER BY key " &
        direction & ";"
    else:
      "SELECT key, payload FROM kv WHERE category = ? AND key >= ? AND key < ? ORDER BY key " &
        direction & ";"

  var rows: seq[KvRow] = @[]
  proc onRow(rs: ptr sqlite3_stmt) {.gcsafe, raises: [].} =
    let k = readBlob(rs, 0.cint)
    let p = readBlob(rs, 1.cint)
    rows.add((rawKey(k), p))

  if openEnded:
    ?b.db.runRead(sql, [catBytes(category), keyBytes(range.start)], onRow)
  else:
    ?b.db.runRead(
      sql, [catBytes(category), keyBytes(range.start), keyBytes(range.stop)], onRow
    )
  return ok(rows)

proc countRange*(
    b: KvBackend, category: string, range: KeyRange
): Result[int, PersistencyError] =
  let openEnded = bytes(range.stop).len == 0
  let sql =
    if openEnded:
      "SELECT COUNT(*) FROM kv WHERE category = ? AND key >= ?;"
    else:
      "SELECT COUNT(*) FROM kv WHERE category = ? AND key >= ? AND key < ?;"

  var n: int64 = 0
  proc onRow(rs: ptr sqlite3_stmt) {.gcsafe, raises: [].} =
    n = sqlite3_column_int64(rs, 0.cint)

  if openEnded:
    ?b.db.runRead(sql, [catBytes(category), keyBytes(range.start)], onRow)
  else:
    ?b.db.runRead(
      sql, [catBytes(category), keyBytes(range.start), keyBytes(range.stop)], onRow
    )
  return ok(int(n))

{.push raises: [].}
# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim
#
# Most of it is a direct copy, the only unique functions being `get` and `put`.

import std/[os, strutils, sequtils, algorithm], results, chronicles, sqlite3_abi
import ./common

logScope:
  topics = "sqlite"

type
  Sqlite = ptr sqlite3

  NoParams* = tuple[]
  RawStmtPtr* = ptr sqlite3_stmt
  SqliteStmt*[Params; Result] = distinct RawStmtPtr

  AutoDisposed[T: ptr | ref] = object
    val: T

template dispose(db: Sqlite) =
  discard sqlite3_close(db)

template dispose(rawStmt: RawStmtPtr) =
  discard sqlite3_finalize(rawStmt)

template dispose*(sqliteStmt: SqliteStmt) =
  discard sqlite3_finalize(RawStmtPtr sqliteStmt)

proc release[T](x: var AutoDisposed[T]): T =
  result = x.val
  x.val = nil

proc disposeIfUnreleased[T](x: var AutoDisposed[T]) =
  mixin dispose
  if x.val != nil:
    dispose(x.release)

template checkErr*(op, cleanup: untyped) =
  if (let v = (op); v != SQLITE_OK):
    cleanup
    return err($sqlite3_errstr(v))

template checkErr*(op) =
  checkErr(op):
    discard

type SqliteDatabase* = ref object of RootObj
  env*: Sqlite

type DataProc* = proc(s: RawStmtPtr) {.closure, gcsafe.}
  # the nim-eth definition is different; one more indirection

const NoopRowHandler* = proc(s: RawStmtPtr) {.closure, gcsafe.} =
  discard

proc new*(T: type SqliteDatabase, path: string, readOnly = false): DatabaseResult[T] =
  var env: AutoDisposed[ptr sqlite3]
  defer:
    disposeIfUnreleased(env)

  let flags =
    if readOnly:
      SQLITE_OPEN_READONLY
    else:
      SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE

  if path != ":memory:":
    try:
      createDir(parentDir(path))
    except OSError, IOError:
      return err("sqlite: cannot create database directory")

  checkErr sqlite3_open_v2(path, addr env.val, flags.cint, nil)

  template prepare(q: string, cleanup: untyped): ptr sqlite3_stmt =
    var s: ptr sqlite3_stmt
    checkErr sqlite3_prepare_v2(env.val, q, q.len.cint, addr s, nil):
      cleanup
    s

  template checkExec(s: ptr sqlite3_stmt) =
    if (let x = sqlite3_step(s); x != SQLITE_DONE):
      discard sqlite3_finalize(s)
      return err($sqlite3_errstr(x))

    if (let x = sqlite3_finalize(s); x != SQLITE_OK):
      return err($sqlite3_errstr(x))

  template checkExec(q: string) =
    let s = prepare(q):
      discard
    checkExec(s)

  template checkWalPragmaResult(journalModePragma: ptr sqlite3_stmt) =
    if (let x = sqlite3_step(journalModePragma); x != SQLITE_ROW):
      discard sqlite3_finalize(journalModePragma)
      return err($sqlite3_errstr(x))

    if (let x = sqlite3_column_type(journalModePragma, 0); x != SQLITE3_TEXT):
      discard sqlite3_finalize(journalModePragma)
      return err($sqlite3_errstr(x))

    if (let x = sqlite3_column_text(journalModePragma, 0); x != "memory" and x != "wal"):
      discard sqlite3_finalize(journalModePragma)
      return err("Invalid pragma result: " & $x)

  let journalModePragma = prepare("PRAGMA journal_mode = WAL;"):
    discard
  checkWalPragmaResult(journalModePragma)
  checkExec(journalModePragma)

  ok(SqliteDatabase(env: env.release))

template prepare*(env: Sqlite, q: string, cleanup: untyped): ptr sqlite3_stmt =
  var s: ptr sqlite3_stmt
  checkErr sqlite3_prepare_v2(env, q, q.len.cint, addr s, nil):
    cleanup
  s

proc bindParam*(s: RawStmtPtr, n: int, val: auto): cint =
  when val is openarray[byte] | seq[byte]:
    # The constant, SQLITE_TRANSIENT, may be passed to indicate that the object is to be copied
    #  prior to the return from sqlite3_bind_*(). The object and pointer to it must remain valid
    #  until then. SQLite will then manage the lifetime of its private copy.
    #
    # From: https://www.sqlite.org/c3ref/bind_blob.html
    if val.len > 0:
      sqlite3_bind_blob(s, n.cint, unsafeAddr val[0], val.len.cint, SQLITE_TRANSIENT)
    else:
      sqlite3_bind_blob(s, n.cint, nil, 0.cint, SQLITE_TRANSIENT)
  elif val is int32:
    sqlite3_bind_int(s, n.cint, val)
  elif val is uint32:
    sqlite3_bind_int64(s, n.cint, val)
  elif val is int64:
    sqlite3_bind_int64(s, n.cint, val)
  elif val is float64:
    sqlite3_bind_double(s, n.cint, val)
  # Note: bind_text not yet supported in sqlite3_abi wrapper
  # elif val is string:
  #   sqlite3_bind_text(s, n.cint, val.cstring, -1, nil)  # `-1` implies string length is the number of bytes up to the first null-terminator
  else:
    {.fatal: "Please add support for the '" & $typeof(val) & "' type".}

template bindParams(s: RawStmtPtr, params: auto) =
  when params is tuple:
    var i = 1
    for param in fields(params):
      checkErr bindParam(s, i, param)
      inc i
  else:
    checkErr bindParam(s, 1, params)

proc exec*[P](s: SqliteStmt[P, void], params: P): DatabaseResult[void] =
  let s = RawStmtPtr s
  bindParams(s, params)

  let res =
    if (let v = sqlite3_step(s); v != SQLITE_DONE):
      err($sqlite3_errstr(v) & " " & $sqlite3_errmsg(sqlite3_db_handle(s)))
    else:
      ok()

  # release implict transaction
  discard sqlite3_reset(s) # same return information as step
  discard sqlite3_clear_bindings(s) # no errors possible

  res

template readResult(s: RawStmtPtr, column: cint, T: type): auto =
  when T is Option:
    if sqlite3_column_type(s, column) == SQLITE_NULL:
      none(typeof(default(T).get()))
    else:
      some(readSimpleResult(s, column, typeof(default(T).get())))
  else:
    readSimpleResult(s, column, T)

template readResult(s: RawStmtPtr, T: type): auto =
  when T is tuple:
    var res: T
    var i = cint 0
    for field in fields(res):
      field = readResult(s, i, typeof(field))
      inc i
    res
  else:
    readResult(s, 0.cint, T)

proc exec*[Params, Res](
    s: SqliteStmt[Params, Res], params: Params, onData: DataProc
): DatabaseResult[bool] =
  let s = RawStmtPtr s
  bindParams(s, params)

  try:
    var gotResults = false
    while true:
      let v = sqlite3_step(s)
      case v
      of SQLITE_ROW:
        onData(s)
        gotResults = true
      of SQLITE_DONE:
        break
      else:
        return err($sqlite3_errstr(v))
    return ok gotResults
  finally:
    # release implicit transaction
    discard sqlite3_reset(s) # same return information as step
    discard sqlite3_clear_bindings(s) # no errors possible

proc query*(
    db: SqliteDatabase, query: string, onData: DataProc
): DatabaseResult[bool] {.gcsafe.} =
  var s = prepare(db.env, query):
    discard

  try:
    var gotResults = false
    while true:
      let v = sqlite3_step(s)
      case v
      of SQLITE_ROW:
        onData(s)
        gotResults = true
      of SQLITE_DONE:
        break
      else:
        return err($sqlite3_errstr(v))
    return ok gotResults
  except Exception, CatchableError:
    error "exception in query", query = query, error = getCurrentExceptionMsg()

  # release implicit transaction
  discard sqlite3_reset(s) # same return information as step
  discard sqlite3_clear_bindings(s) # no errors possible
  discard sqlite3_finalize(s)
    # NB: dispose of the prepared query statement and free associated memory

proc prepareStmt*(
    db: SqliteDatabase, stmt: string, Params: type, Res: type
): DatabaseResult[SqliteStmt[Params, Res]] =
  var s: RawStmtPtr
  checkErr sqlite3_prepare_v2(db.env, stmt, stmt.len.cint, addr s, nil)
  ok SqliteStmt[Params, Res](s)

proc close*(db: SqliteDatabase) =
  discard sqlite3_close(db.env)

  db[] = SqliteDatabase()[]

##  Maintenance procedures

# TODO: Cache this value in the SqliteDatabase object.
#       Page size should not change during the node execution time
proc getPageSize*(db: SqliteDatabase): DatabaseResult[int64] =
  ## Query or set the page size of the database. The page size must be a power of
  ## two between 512 and 65536 inclusive.
  var size: int64
  proc handler(s: RawStmtPtr) =
    size = sqlite3_column_int64(s, 0)

  db.query("PRAGMA page_size;", handler).isOkOr:
    return err("failed to get page_size")

  return ok(size)

proc getFreelistCount*(db: SqliteDatabase): DatabaseResult[int64] =
  ## Return the number of unused pages in the database file.
  var count: int64
  proc handler(s: RawStmtPtr) =
    count = sqlite3_column_int64(s, 0)

  db.query("PRAGMA freelist_count;", handler).isOkOr:
    return err("failed to get freelist_count")

  return ok(count)

proc getPageCount*(db: SqliteDatabase): DatabaseResult[int64] =
  ## Return the total number of pages in the database file.
  var count: int64
  proc handler(s: RawStmtPtr) =
    count = sqlite3_column_int64(s, 0)

  db.query("PRAGMA page_count;", handler).isOkOr:
    return err("failed to get page_count")

  return ok(count)

proc getDatabaseSize*(db: SqliteDatabase): DatabaseResult[int64] =
  # get the database page size in bytes
  var pageSize: int64 = ?db.getPageSize()

  if pageSize == 0:
    return err("failed to get page size ")

  # get the database page count
  let pageCount = ?db.getPageCount()

  let databaseSize = (pageSize * pageCount)

  return ok(databaseSize)

proc gatherSqlitePageStats*(db: SqliteDatabase): DatabaseResult[(int64, int64, int64)] =
  let
    pageSize = ?db.getPageSize()
    pageCount = ?db.getPageCount()
    freelistCount = ?db.getFreelistCount()

  return ok((pageSize, pageCount, freelistCount))

proc vacuum*(db: SqliteDatabase): DatabaseResult[void] =
  ## The VACUUM command rebuilds the database file, repacking it into a minimal amount of disk space.
  db.query("VACUUM;", NoopRowHandler).isOkOr:
    return err("vacuum failed")

  return ok()

## Database scheme versioning

proc getUserVersion*(database: SqliteDatabase): DatabaseResult[int64] =
  ## Get the value of the user-version integer.
  ##
  ## The user-version is an integer that is available to applications to use however they want.
  ## SQLite makes no use of the user-version itself. This integer is stored at offset 60 in
  ## the database header.
  ##
  ## For more info check: https://www.sqlite.org/pragma.html#pragma_user_version
  var version: int64
  proc handler(s: ptr sqlite3_stmt) =
    version = sqlite3_column_int64(s, 0)

  database.query("PRAGMA user_version;", handler).isOkOr:
    return err("failed to get user_version")

  ok(version)

proc setUserVersion*(database: SqliteDatabase, version: int64): DatabaseResult[void] =
  ## Set the value of the user-version integer.
  ##
  ## The user-version is an integer that is available to applications to use however they want.
  ## SQLite makes no use of the user-version itself. This integer is stored at offset 60 in
  ## the database header.
  ##
  ## For more info check: https://www.sqlite.org/pragma.html#pragma_user_version
  let query = "PRAGMA user_version=" & $version & ";"
  database.query(query, NoopRowHandler).isOkOr:
    return err("failed to set user_version")

  ok()

## Migration scripts

proc getMigrationScriptVersion(path: string): DatabaseResult[int64] =
  let name = extractFilename(path)
  let parts = name.split("_", 1)

  try:
    let version = parseInt(parts[0])
    return ok(version)
  except ValueError:
    return err("failed to parse file version: " & name)

proc isSqlScript(path: string): bool =
  path.toLower().endsWith(".sql")

proc listSqlScripts(path: string): DatabaseResult[seq[string]] =
  var scripts = newSeq[string]()

  try:
    for scriptPath in walkDirRec(path):
      if isSqlScript(scriptPath):
        scripts.add(scriptPath)
      else:
        info "invalid migration script", file = scriptPath
  except OSError:
    return err("failed to list migration scripts: " & getCurrentExceptionMsg())

  ok(scripts)

proc filterMigrationScripts(
    paths: seq[string], lowVersion, highVersion: int64, direction: string = "up"
): seq[string] =
  ## Returns migration scripts whose version fall between lowVersion and highVersion (inclusive)
  let filterPredicate = proc(script: string): bool =
    if not isSqlScript(script):
      return false

    if direction != "" and not script.toLower().endsWith("." & direction & ".sql"):
      return false

    let scriptVersion = getMigrationScriptVersion(script).valueOr:
      return false

    return lowVersion < scriptVersion and scriptVersion <= highVersion

  paths.filter(filterPredicate)

proc sortMigrationScripts(paths: seq[string]): seq[string] =
  ## Sort migration scripts paths alphabetically
  paths.sorted(system.cmp[string])

proc loadMigrationScripts(paths: seq[string]): DatabaseResult[seq[string]] =
  var loadedScripts = newSeq[string]()

  for script in paths:
    try:
      loadedScripts.add(readFile(script))
    except OSError, IOError:
      return err("failed to load script '" & script & "': " & getCurrentExceptionMsg())

  ok(loadedScripts)

proc breakIntoStatements(script: string): seq[string] =
  var statements = newSeq[string]()

  for chunk in script.split(';'):
    if chunk.strip().isEmptyOrWhitespace():
      continue

    let statement = chunk.strip() & ";"
    statements.add(statement)

  statements

proc migrate*(
    db: SqliteDatabase, targetVersion: int64, migrationsScriptsDir: string
): DatabaseResult[void] =
  ## Compares the `user_version` of the sqlite database with the provided `targetVersion`, then
  ## it runs migration scripts if the `user_version` is outdated. The `migrationScriptsDir` path
  ## points to the directory holding the migrations scripts once the db is updated, it sets the
  ## `user_version` to the `tragetVersion`.
  ##
  ## NOTE: Down migration it is not currently supported
  let userVersion = ?db.getUserVersion()

  if userVersion == targetVersion:
    info "database schema is up to date",
      userVersion = userVersion, targetVersion = targetVersion
    return ok()

  info "database schema is outdated",
    userVersion = userVersion, targetVersion = targetVersion

  # Load migration scripts
  var migrationScriptsPaths = ?listSqlScripts(migrationsScriptsDir)
  migrationScriptsPaths = filterMigrationScripts(
    migrationScriptsPaths,
    lowVersion = userVersion,
    highVersion = targetVersion,
    direction = "up",
  )
  migrationScriptsPaths = sortMigrationScripts(migrationScriptsPaths)

  if migrationScriptsPaths.len <= 0:
    info "no scripts to be run"
    return ok()

  let scripts = ?loadMigrationScripts(migrationScriptsPaths)

  # Run the migration scripts
  for script in scripts:
    for statement in script.breakIntoStatements():
      info "executing migration statement", statement = statement

      db.query(statement, NoopRowHandler).isOkOr:
        error "failed to execute migration statement",
          statement = statement, error = error
        return err("failed to execute migration statement")

      info "migration statement executed succesfully", statement = statement

  # Update user_version
  ?db.setUserVersion(targetVersion)

  info "database user_version updated", userVersion = targetVersion
  ok()

proc performSqliteVacuum*(db: SqliteDatabase): DatabaseResult[void] =
  ## SQLite database vacuuming
  # TODO: Run vacuuming conditionally based on database page stats
  # if (pageCount > 0 and freelistCount > 0):

  info "starting sqlite database vacuuming"

  db.vacuum().isOkOr:
    return err("failed to execute vacuum: " & error)

  info "finished sqlite database vacuuming"
  ok()

{.used.}

import std/os, results, sqlite3_abi, testutils/unittests
import logos_delivery/waku/common/databases/[common, db_sqlite]

proc openStatements(db: SqliteDatabase): int =
  var s = sqlite3_next_stmt(db.env, nil)
  while not s.isNil():
    inc result
    s = sqlite3_next_stmt(db.env, s)

suite "SQLite - query":
  ## An unfinalized statement makes `sqlite3_close` fail with SQLITE_BUSY,
  ## which keeps the database and its -wal/-shm files open (#4498).

  test "finalizes the statement on success":
    let db = SqliteDatabase.new(":memory:").expect("open")
    defer:
      db.close()

    check:
      db.query("PRAGMA temp_store = MEMORY;", NoopRowHandler).isOk()
      db.query("SELECT 1;", NoopRowHandler).isOk()
      db.openStatements() == 0

  test "finalizes the statement on a step error":
    let db = SqliteDatabase.new(":memory:").expect("open")
    defer:
      db.close()

    ## Prepares fine, fails in sqlite3_step (integer overflow).
    check:
      db.query("SELECT abs(-9223372036854775808);", NoopRowHandler).isErr()
      db.openStatements() == 0

  test "close releases a file database":
    let path = getTempDir() / "test_sqlite_query.db"
    removeFile(path)
    defer:
      removeFile(path)
      removeFile(path & "-wal")
      removeFile(path & "-shm")

    let db = SqliteDatabase.new(path).expect("open")
    check:
      db.query("CREATE TABLE t (x INTEGER);", NoopRowHandler).isOk()
      db.getUserVersion().isOk()
    let env = db.env
    check sqlite3_close(env) == SQLITE_OK

## SQL schema and pragma setup for the persistency library.
##
## Single uniform schema per job DB file:
##   kv(category BLOB, key BLOB, payload BLOB) PRIMARY KEY (category, key)
##   WITHOUT ROWID
##
## category is declared BLOB (not TEXT) so it round-trips via the existing
## sqlite3_abi binding helpers (which do not yet expose bind_text). SQLite
## compares BLOBs byte-wise, which is exactly the ordering we want.

{.push raises: [].}

import results
import ../common/databases/[common, db_sqlite]

const
  PersistencyUserVersion* = 1'i64

  CreateKvTableSql* = """
    CREATE TABLE IF NOT EXISTS kv (
      category BLOB NOT NULL,
      key      BLOB NOT NULL,
      payload  BLOB NOT NULL,
      PRIMARY KEY (category, key)
    ) WITHOUT ROWID;
    """

  ApplyPragmasSql* = """
    PRAGMA synchronous = NORMAL;
    PRAGMA temp_store = MEMORY;
    PRAGMA busy_timeout = 5000;
    PRAGMA foreign_keys = OFF;
    """

proc applyPragmas*(db: SqliteDatabase): DatabaseResult[void] =
  ## Apply the connection-level pragmas. journal_mode=WAL is already set by
  ## SqliteDatabase.new.
  for stmt in [
    "PRAGMA synchronous = NORMAL;", "PRAGMA temp_store = MEMORY;",
    "PRAGMA busy_timeout = 5000;", "PRAGMA foreign_keys = OFF;",
  ]:
    db.query(stmt, NoopRowHandler).isOkOr:
      return err("pragma failed: " & stmt & ": " & error)
  return ok()

proc ensureSchema*(db: SqliteDatabase): DatabaseResult[void] =
  db.query(CreateKvTableSql, NoopRowHandler).isOkOr:
    return err("create kv table failed: " & error)

  let userVersion = ?db.getUserVersion()
  if userVersion == 0:
    ?db.setUserVersion(PersistencyUserVersion)
  elif userVersion != PersistencyUserVersion:
    return err(
      "incompatible persistency user_version: got " & $userVersion & ", expected " &
        $PersistencyUserVersion
    )
  return ok()

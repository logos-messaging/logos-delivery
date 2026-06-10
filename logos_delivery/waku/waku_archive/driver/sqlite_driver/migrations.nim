{.push raises: [].}

import
  std/[tables, strutils, os], results, chronicles, sqlite3_abi # sqlite3_column_int64
import ../../../common/databases/db_sqlite, ../../../common/databases/common

logScope:
  topics = "waku archive migration"

const SchemaVersion* = 10 # increase this when there is an update in the database schema

template projectRoot(): string =
  currentSourcePath.rsplit(DirSep, 1)[0] / ".." / ".." / ".." / ".."

const MessageStoreMigrationPath: string = projectRoot / "migrations" / "message_store"

proc isSchemaVersion7*(db: SqliteDatabase): DatabaseResult[bool] =
  ## Temporary proc created to analyse when the table actually belongs to the SchemaVersion 7.
  ##
  ## During many nwaku versions, 0.14.0 until 0.18.0, the SchemaVersion wasn't set or checked.
  ## Docker `nwaku` nodes that start working from these versions, 0.14.0 until 0.18.0, they started
  ## with this discrepancy: `user_version`== 0 (not set) but Message table with SchemaVersion 7.
  ##
  ## We found issues where `user_version` (SchemaVersion) was set to 0 in the database even though
  ## its scheme structure reflected SchemaVersion 7. In those cases, when `nwaku` re-started to
  ## apply the migration scripts (in 0.19.0) the node didn't start properly because it tried to
  ## migrate a database that already had the Schema structure #7, so it failed when changing the PK.
  ##
  ## TODO: This was added in version 0.20.0. We might remove this in version 0.30.0, as we
  ##       could consider that many users use +0.20.0.

  var pkColumns = newSeq[string]()
  proc queryRowCallback(s: ptr sqlite3_stmt) =
    let colName = cstring sqlite3_column_text(s, 0)
    pkColumns.add($colName)

  let query =
    """SELECT l.name FROM pragma_table_info("Message") as l WHERE l.pk != 0;"""
  db.query(query, queryRowCallback).isOkOr:
    return err("failed to determine the current SchemaVersion: " & $error)

  if pkColumns == @["pubsubTopic", "id", "storedAt"]:
    return ok(true)
  else:
    info "Not considered schema version 7"
    return ok(false)

proc migrate*(db: SqliteDatabase, targetVersion = SchemaVersion): DatabaseResult[void] =
  ## Compares the `user_version` of the sqlite database with the provided `targetVersion`, then
  ## it runs migration scripts if the `user_version` is outdated. The `migrationScriptsDir` path
  ## points to the directory holding the migrations scripts once the db is updated, it sets the
  ## `user_version` to the `tragetVersion`.
  ##
  ## If not `targetVersion` is provided, it defaults to `SchemaVersion`.
  ##
  ## NOTE: Down migration it is not currently supported
  info "starting message store's sqlite database migration"

  let userVersion = ?db.getUserVersion()
  let isSchemaVersion7 = ?db.isSchemaVersion7()

  if userVersion == 0'i64 and isSchemaVersion7:
    info "We found user_version 0 but the database schema reflects the user_version 7"
    ## Force the correct schema version
    ?db.setUserVersion(7)

  migrate(db, targetVersion, migrationsScriptsDir = MessageStoreMigrationPath).isOkOr:
    return err("failed to execute migration scripts: " & error)

  info "finished message store's sqlite database migration"
  return ok()

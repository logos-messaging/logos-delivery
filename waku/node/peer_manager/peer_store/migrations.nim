{.push raises: [].}

import std/[tables, strutils, os], results, chronicles
import ../../../common/databases/db_sqlite, ../../../common/databases/common

logScope:
  topics = "waku node peer_manager"

const SchemaVersion* = 1 # increase this when there is an update in the database schema

template projectRoot(): string =
  currentSourcePath.rsplit(DirSep, 1)[0] / ".." / ".." / ".." / ".." / ".."

const PeerStoreMigrationPath: string = projectRoot / "migrations" / "peer_store"

proc migrate*(db: SqliteDatabase, targetVersion = SchemaVersion): DatabaseResult[void] =
  ## Compares the `user_version` of the sqlite database with the provided `targetVersion`, then
  ## it runs migration scripts if the `user_version` is outdated. The `migrationScriptsDir` path
  ## points to the directory holding the migrations scripts once the db is updated, it sets the
  ## `user_version` to the `tragetVersion`.
  ##
  ## If not `targetVersion` is provided, it defaults to `SchemaVersion`.
  ##
  ## NOTE: Down migration it is not currently supported
  info "starting peer store's sqlite database migration"

  migrate(db, targetVersion, migrationsScriptsDir = PeerStoreMigrationPath).isOkOr:
    return err("failed to execute migration scripts: " & error)

  info "finished peer store's sqlite database migration"
  ok()

{.push raises: [].}

import std/[tables, strutils, os], results, chronicles
import ../../../common/databases/db_sqlite, ../../../common/databases/common

logScope:
  topics = "waku node delivery_service"

const TargetSchemaVersion* = 1
  # increase this when there is an update in the database schema

template projectRoot(): string =
  currentSourcePath.rsplit(DirSep, 1)[0] / ".." / ".." / ".." / ".."

const PeerStoreMigrationPath: string = projectRoot / "migrations" / "sent_msgs"

proc migrate*(db: SqliteDatabase): DatabaseResult[void] =
  info "starting peer store's sqlite database migration for sent messages"

  migrate(db, TargetSchemaVersion, migrationsScriptsDir = PeerStoreMigrationPath).isOkOr:
    return err("failed to execute migration scripts: " & error)

  info "finished peer store's sqlite database migration for sent messages"
  ok()

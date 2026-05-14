import std/[options], results, testutils/unittests

import
  waku/node/peer_manager/peer_store/migrations,
  ../../waku_archive/archive_utils,
  ../../testlib/[simple_mock]

import std/[tables, strutils, os], results, chronicles

import waku/common/databases/db_sqlite, waku/common/databases/common

suite "Migrations":
  test "migrate ok":
    # Given the db_sqlite.migrate function returns ok
    let backup = db_sqlite.migrate
    mock(db_sqlite.migrate):
      proc mockedMigrate(
          db: SqliteDatabase, targetVersion: int64, migrationsScriptsDir: string
      ): DatabaseResult[void] =
        ok()

      mockedMigrate

    # When we call the migrate function
    let migrationResult = migrations.migrate(newSqliteDatabase(), 1)

    # Then we expect the result to be ok
    check:
      migrationResult == DatabaseResult[void].ok()

    # Cleanup
    mock(db_sqlite.migrate):
      backup

  test "migrate error":
    # Given the db_sqlite.migrate function returns an error
    let backup = db_sqlite.migrate
    mock(db_sqlite.migrate):
      proc mockedMigrate(
          db: SqliteDatabase, targetVersion: int64, migrationsScriptsDir: string
      ): DatabaseResult[void] =
        err("mock error")

      mockedMigrate

    # When we call the migrate function
    let migrationResult = migrations.migrate(newSqliteDatabase(), 1)

    # Then we expect the result to be an error
    check:
      migrationResult ==
        DatabaseResult[void].err("failed to execute migration scripts: mock error")

    # Cleanup
    mock(db_sqlite.migrate):
      backup

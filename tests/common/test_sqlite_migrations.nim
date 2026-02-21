{.used.}

import std/[strutils, os], results, testutils/unittests
import waku/common/databases/db_sqlite {.all.}, ../waku_archive/archive_utils

template sourceDir(): string =
  currentSourcePath.rsplit(DirSep, 1)[0]

suite "SQLite - migrations":
  test "set and get user version":
    ## Given
    let database = newSqliteDatabase()

    ## When
    let setRes = database.setUserVersion(5)
    let getRes = database.getUserVersion()

    ## Then
    check:
      setRes.isOk()
      getRes.isOk()

    let version = getRes.tryGet()
    check:
      version == 5

    ## Cleanup
    database.close()

  test "filter and order migration script file paths":
    ## Given
    let paths = @[
      sourceDir / "00001_valid.up.sql",
      sourceDir / "00002_alsoValidWithUpperCaseExtension.UP.SQL",
      sourceDir / "00007_unorderedValid.up.sql",
      sourceDir / "00003_validRepeated.up.sql",
      sourceDir / "00003_validRepeated.up.sql",
      sourceDir / "00666_noMigrationScript.bmp",
      sourceDir / "00X00_invalidVersion.down.sql",
      sourceDir / "00008_notWithinVersionRange.up.sql",
    ]

    let
      lowerVersion = 0
      highVersion = 7

    ## When
    var migrationSciptPaths: seq[string]
    migrationSciptPaths =
      filterMigrationScripts(paths, lowerVersion, highVersion, direction = "up")
    migrationSciptPaths = sortMigrationScripts(migrationSciptPaths)

    ## Then
    check:
      migrationSciptPaths ==
        @[
          sourceDir / "00001_valid.up.sql",
          sourceDir / "00002_alsoValidWithUpperCaseExtension.UP.SQL",
          sourceDir / "00003_validRepeated.up.sql",
          sourceDir / "00003_validRepeated.up.sql",
          sourceDir / "00007_unorderedValid.up.sql",
        ]

  test "break migration scripts into queries":
    ## Given
    let statement1 = """CREATE TABLE contacts1 (
                          contact_id INTEGER PRIMARY KEY,
                          first_name TEXT NOT NULL,
                          last_name TEXT NOT NULL,
                          email TEXT NOT NULL UNIQUE,
                          phone TEXT NOT NULL UNIQUE
                        );"""
    let statement2 = """CREATE TABLE contacts2 (
                          contact_id INTEGER PRIMARY KEY,
                          first_name TEXT NOT NULL,
                          last_name TEXT NOT NULL,
                          email TEXT NOT NULL UNIQUE,
                          phone TEXT NOT NULL UNIQUE
                        );"""
    let script = statement1 & statement2

    ## When
    let statements = script.breakIntoStatements()

    ## Then
    check:
      statements == @[statement1, statement2]

  test "break statements script into queries - empty statements":
    ## Given
    let statement1 = """CREATE TABLE contacts1 (
                          contact_id INTEGER PRIMARY KEY,
                          first_name TEXT NOT NULL,
                          last_name TEXT NOT NULL,
                          email TEXT NOT NULL UNIQUE,
                          phone TEXT NOT NULL UNIQUE
                        );"""
    let statement2 = """CREATE TABLE contacts2 (
                          contact_id INTEGER PRIMARY KEY,
                          first_name TEXT NOT NULL,
                          last_name TEXT NOT NULL,
                          email TEXT NOT NULL UNIQUE,
                          phone TEXT NOT NULL UNIQUE
                        );"""
    let script = statement1 & "; ;" & statement2

    ## When
    let statements = script.breakIntoStatements()

    ## Then
    check:
      statements == @[statement1, statement2]

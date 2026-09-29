{.used.}

import std/[os, strutils], results, testutils/unittests, chronos, chronicles
import
  logos_delivery/waku/[
    waku_archive/driver,
    waku_archive/driver/builder,
    common/databases/db_postgres/pgasyncpool,
  ]

proc newDriver(url: string): Result[ArchiveDriver, string] =
  proc onFatal(errMsg: string) {.gcsafe, closure.} =
    discard

  return waitFor ArchiveDriver.new(
    url, vacuum = false, migrate = true, maxNumConn = 1, onFatalErrorAction = onFatal
  )

suite "Waku Archive - driver builder":
  test "unknown engine is rejected":
    let res = newDriver("mysql://user:pass@localhost:3306/db")
    check:
      res.isErr()
      "unsupported store message DB engine 'mysql'" in res.error

  test "'none' and empty url select the in-memory driver":
    for url in ["none", ""]:
      let res = newDriver(url)
      check:
        res.isOk()
        res.get() of QueueDriver

  test "sqlite url selects the sqlite driver":
    let path = getTempDir() / "test_driver_builder.sqlite3"
    removeFile(path)
    defer:
      removeFile(path)

    let res = newDriver("sqlite://" & path)
    check:
      res.isOk()
      res.get() of SqliteDriver

  test "postgresql url is parsed by the postgres pool":
    check PgAsyncPool.new("postgresql://u:p@localhost:5432/db", 1).isOk()

  when not defined(postgres):
    test "postgresql url is routed to the postgres engine":
      let res = newDriver("postgresql://u:p@localhost:5432/db")
      check:
        res.isErr()
        "Postgres has been configured but not been compiled" in res.error

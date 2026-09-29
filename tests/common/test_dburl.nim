{.used.}

import results, testutils/unittests
import logos_delivery/waku/common/databases/dburl

suite "DbUrl - engine resolution":
  test "sqlite scheme resolves to sqlite":
    check dburl.getDbEngine("sqlite://store.sqlite3").get() == "sqlite"

  test "postgres scheme resolves to postgres":
    check dburl.getDbEngine("postgres://u:p@localhost:5432/db").get() == "postgres"

  test "postgresql scheme is an alias of postgres":
    let url = "postgresql://u:p@localhost:5432/db"
    check:
      dburl.validateDbUrl(url).isOk()
      dburl.getDbEngine(url).get() == "postgres"

  test "unknown scheme is returned as is":
    check dburl.getDbEngine("mysql://u:p@localhost:3306/db").get() == "mysql"

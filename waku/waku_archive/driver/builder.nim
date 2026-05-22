{.push raises: [].}

import results, chronicles, chronos
import
  ../driver,
  ../../common/databases/dburl,
  ../../common/databases/db_sqlite,
  ../../common/error_handling,
  ./sqlite_driver,
  ./sqlite_driver/migrations as archive_driver_sqlite_migrations,
  ./queue_driver

export sqlite_driver, queue_driver

when defined(postgres):
  import ## These imports add dependency with an external libpq library
    ./postgres_driver/migrations as archive_postgres_driver_migrations,
    ./postgres_driver
  export postgres_driver

proc new*(
    T: type ArchiveDriver,
    url: string,
    vacuum: bool,
    migrate: bool,
    maxNumConn: int,
    onFatalErrorAction: OnFatalErrorHandler,
): Future[Result[T, string]] {.async.} =
  ## url - string that defines the database
  ## vacuum - if true, a cleanup operation will be applied to the database
  ## migrate - if true, the database schema will be updated
  ## maxNumConn - defines the maximum number of connections to handle simultaneously (Postgres)
  ## onFatalErrorAction - called if, e.g., the connection with db got lost

  dburl.validateDbUrl(url).isOkOr:
    return err("DbUrl failure in ArchiveDriver.new: " & error)

  let engine = dburl.getDbEngine(url).valueOr:
    return err("error getting db engine in setupWakuArchiveDriver: " & error)

  case engine
  of "sqlite":
    let path = dburl.getDbPath(url).valueOr:
      return err("error get path in setupWakuArchiveDriver: " & error)

    let db = SqliteDatabase.new(path).valueOr:
      return err("error in setupWakuArchiveDriver: " & error)

    # SQLite vacuum
    let (pageSize, pageCount, freelistCount) = db.gatherSqlitePageStats().valueOr:
      return err("error while gathering sqlite stats: " & $error)

    info "sqlite database page stats",
      pageSize = pageSize, pages = pageCount, freePages = freelistCount

    if vacuum and (pageCount > 0 and freelistCount > 0):
      db.performSqliteVacuum().isOkOr:
        return err("error in vacuum sqlite: " & $error)

    # Database migration
    if migrate:
      archive_driver_sqlite_migrations.migrate(db).isOkOr:
        return err("error in migrate sqlite: " & $error)

    info "setting up sqlite waku archive driver"
    let res = SqliteDriver.new(db).valueOr:
      return err("failed to init sqlite archive driver: " & error)

    return ok(res)
  of "postgres":
    when defined(postgres):
      let driver = PostgresDriver.new(
        dbUrl = url,
        maxConnections = maxNumConn,
        onFatalErrorAction = onFatalErrorAction,
      ).valueOr:
        return err("failed to init postgres archive driver: " & error)

      # Database migration
      if migrate:
        (await archive_postgres_driver_migrations.migrate(driver)).isOkOr:
          return err("ArchiveDriver build failed in migration: " & $error)

      ## This should be started once we make sure the 'messages' table exists
      ## Hence, this should be run after the migration is completed.
      asyncSpawn driver.startPartitionFactory(onFatalErrorAction)

      driver.startAnalyzeTableLoop()

      info "waiting for a partition to be created"
      for i in 0 ..< 100:
        if driver.containsAnyPartition():
          break
        await sleepAsync(chronos.milliseconds(100))

      if not driver.containsAnyPartition():
        onFatalErrorAction("a partition could not be created")

      return ok(driver)
    else:
      return err(
        "Postgres has been configured but not been compiled. Check compiler definitions."
      )
  else:
    info "setting up in-memory waku archive driver"
    let driver = QueueDriver.new() # Defaults to a capacity of 25.000 messages
    return ok(driver)

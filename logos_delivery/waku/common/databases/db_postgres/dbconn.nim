import
  std/[times, strutils, os, sets, strformat, tables],
  results,
  chronos,
  chronos/threadsync,
  metrics,
  chronicles
import ./query_metrics

include db_connector/db_postgres

type DataProc* = proc(result: ptr PGresult) {.closure, gcsafe, raises: [].}

type DbConnWrapper* = ref object
  dbConn: DbConn
  registeredFd: Opt[asyncengine.AsyncFD]
    ## the descriptor handed to chronos when the connection was opened. It has
    ## to be remembered because libpq no longer knows it once the backend dies.
  open: bool
  preparedStmts: HashSet[string] ## [stmtName's]
  futBecomeFree*: Future[void]
    ## to notify the pgasyncpool that this conn is free, i.e. not busy

## Connection management

proc containsPreparedStmt*(dbConnWrapper: DbConnWrapper, preparedStmt: string): bool =
  return dbConnWrapper.preparedStmts.contains(preparedStmt)

proc inclPreparedStmt*(dbConnWrapper: DbConnWrapper, preparedStmt: string) =
  dbConnWrapper.preparedStmts.incl(preparedStmt)

proc getDbConn*(dbConnWrapper: DbConnWrapper): DbConn =
  return dbConnWrapper.dbConn

proc getRegisteredFd*(dbConnWrapper: DbConnWrapper): Opt[asyncengine.AsyncFD] =
  ## Exposed so that the tests can assert the selector entry is given back.
  return dbConnWrapper.registeredFd

proc isPgDbConnBusy*(dbConnWrapper: DbConnWrapper): bool =
  if isNil(dbConnWrapper.futBecomeFree):
    return false
  return not dbConnWrapper.futBecomeFree.finished()

proc isPgDbConnOpen*(dbConnWrapper: DbConnWrapper): bool =
  return dbConnWrapper.open

const MaxDbErrorLen = 512
  ## libpq can answer with very long messages -- the DETAIL and CONTEXT lines
  ## carry row data -- and this string reaches both the logs and the error chain,
  ## so it has to stay bounded. 512 keeps whole every message the callers must
  ## classify: the longest of them, the constraint ones naming a partition twice,
  ## are around 130 characters.

proc check(db: DbConn): Result[void, string] =
  var message: string
  try:
    message = $db.pqErrorMessage()
  except ValueError, DbError:
    return err("exception in check: " & getCurrentExceptionMsg())

  if message.len > 0:
    let truncatedErr = message[0 ..< min(MaxDbErrorLen, message.len)]
    error "postgres check issue. see truncated db error.", error = truncatedErr
    return err(truncatedErr)

  return ok()

proc openDbConn(connString: string): Result[DbConnWrapper, string] =
  ## Opens a new connection.
  var conn: DbConn = nil
  try:
    conn = open("", "", "", connString) ## included from db_postgres module
  except DbError:
    return err("exception opening new connection: " & getCurrentExceptionMsg())

  if conn.status != CONNECTION_OK:
    conn.check().isOkOr:
      return err("failed to connect to database: " & error)

    return err("unknown reason")

  ## registering the socket fd in chronos for better wait for data.
  ## The wrapper is built here so that the registered descriptor and the
  ## remembered one cannot drift apart.
  let asyncFd = cast[asyncengine.AsyncFD](pqsocket(conn))
  asyncengine.register2(asyncFd).isOkOr:
    conn.close()
    return err("failed to register the connection socket: " & $error)

  return ok(DbConnWrapper(dbConn: conn, registeredFd: Opt.some(asyncFd), open: true))

proc new*(T: type DbConnWrapper, connString: string): Result[T, string] =
  let dbConnWrapper = openDbConn(connString).valueOr:
    return err("failed to establish a new connection: " & $error)

  return ok(dbConnWrapper)

proc closeDbConn*(dbConnWrapper: DbConnWrapper): Result[void, string] {.raises: [].} =
  ## Closing must always reach pqfinish, even when giving the selector entry
  ## back fails. Asking libpq for the descriptor here is useless: it answers -1
  ## as soon as the backend is gone.
  if not dbConnWrapper.open:
    return ok()

  var unregisterError = ""
  if dbConnWrapper.registeredFd.isSome():
    let asyncFd = dbConnWrapper.registeredFd.get()
    ## unregister2 asserts when the descriptor is unknown to the dispatcher
    if asyncFd in asyncengine.getThreadDispatcher():
      when defined(windows):
        ## chronos exposes no Result-returning unregister on Windows, where
        ## unregistering only drops the handle from the dispatcher and cannot
        ## fail
        asyncengine.unregister(asyncFd)
      else:
        asyncengine.unregister2(asyncFd).isOkOr:
          unregisterError = "failed to unregister the connection socket: " & $error

  dbConnWrapper.dbConn.close()
  dbConnWrapper.open = false

  if unregisterError.len > 0:
    return err(unregisterError)

  return ok()

proc `$`(self: SqlQuery): string =
  return cast[string](self)

proc sendQuery(
    dbConnWrapper: DbConnWrapper, query: SqlQuery, args: seq[string]
): Future[Result[void, string]] {.async.} =
  ## This proc can be used directly for queries that don't retrieve values back.

  if dbConnWrapper.dbConn.status != CONNECTION_OK:
    dbConnWrapper.dbConn.check().isOkOr:
      return err("failed to connect to database: " & $error)

    return err("unknown reason")

  var wellFormedQuery = ""
  try:
    wellFormedQuery = dbFormat(query, args)
  except DbError:
    return err("exception formatting the query: " & getCurrentExceptionMsg())

  let success = dbConnWrapper.dbConn.pqsendQuery(cstring(wellFormedQuery))
  if success != 1:
    dbConnWrapper.dbConn.check().isOkOr:
      return err("failed pqsendQuery: " & $error)
    return err("failed pqsendQuery: unknown reason")

  return ok()

proc sendQueryPrepared(
    dbConnWrapper: DbConnWrapper,
    stmtName: string,
    paramValues: openArray[string],
    paramLengths: openArray[int32],
    paramFormats: openArray[int32],
): Result[void, string] {.raises: [].} =
  ## This proc can be used directly for queries that don't retrieve values back.

  if paramValues.len != paramLengths.len or paramValues.len != paramFormats.len or
      paramLengths.len != paramFormats.len:
    let lengthsErrMsg =
      $paramValues.len & " " & $paramLengths.len & " " & $paramFormats.len
    return err("lengths discrepancies in sendQueryPrepared: " & $lengthsErrMsg)

  if dbConnWrapper.dbConn.status != CONNECTION_OK:
    dbConnWrapper.dbConn.check().isOkOr:
      return err("failed to connect to database: " & $error)

    return err("unknown reason")

  var cstrArrayParams = allocCStringArray(paramValues)
  defer:
    deallocCStringArray(cstrArrayParams)

  let nParams = cast[int32](paramValues.len)

  const ResultFormat = 0 ## 0 for text format, 1 for binary format.

  let success = dbConnWrapper.dbConn.pqsendQueryPrepared(
    stmtName,
    nParams,
    cstrArrayParams,
    unsafeAddr paramLengths[0],
    unsafeAddr paramFormats[0],
    ResultFormat,
  )
  if success != 1:
    dbConnWrapper.dbConn.check().isOkOr:
      return err("failed pqsendQueryPrepared: " & $error)

    return err("failed pqsendQueryPrepared: unknown reason")

  return ok()

proc waitForData(
    dbConnWrapper: DbConnWrapper, asyncFd: asyncengine.AsyncFD
): Future[Result[void, string]] {.async.} =
  ## Waits until the socket has something to read and gives the reader back
  ## before returning. The caller must not touch libpq while the reader is
  ## installed: libpq closes the socket as soon as it notices the backend is
  ## gone, and removing a reader from an already closed descriptor fails,
  ## leaving the selector entry behind forever.

  when defined(windows):
    return err("Postgres not supported on Windows")
  else:
    let futDataAvailable = newFuture[void]("futDataAvailable")

    proc onDataAvailable(udata: pointer) {.gcsafe, raises: [].} =
      if not futDataAvailable.completed():
        futDataAvailable.complete()

    asyncengine.addReader2(asyncFd, onDataAvailable).isOkOr:
      dbConnWrapper.futBecomeFree.fail(newException(ValueError, $error))
      return err("failed to add event reader in waitForData: " & $error)

    defer:
      asyncengine.removeReader2(asyncFd).isOkOr:
        error "failed to remove event reader in waitForData", error = $error

    await futDataAvailable

    return ok()

proc waitQueryToFinish(
    dbConnWrapper: DbConnWrapper, rowCallback: DataProc = nil
): Future[Result[void, string]] {.async.} =
  ## The 'rowCallback' param is != nil when the underlying query wants to retrieve results (SELECT.)
  ## For other queries, like "INSERT", 'rowCallback' should be nil.

  let asyncFd = dbConnWrapper.registeredFd.valueOr:
    return err("the connection socket is not registered in waitQueryToFinish")

  (await dbConnWrapper.waitForData(asyncFd)).isOkOr:
    return err($error)

  ## Now retrieve the result from the database
  while true:
    let pqResult = dbConnWrapper.dbConn.pqgetResult()

    if pqResult == nil:
      dbConnWrapper.dbConn.check().isOkOr:
        if not dbConnWrapper.futBecomeFree.failed():
          dbConnWrapper.futBecomeFree.fail(newException(ValueError, $error))
        return err("error in query: " & $error)

      dbConnWrapper.futBecomeFree.complete()
      return ok() # reached the end of the results. The query is completed

    if not rowCallback.isNil():
      rowCallback(pqResult)

    pqclear(pqResult)

proc containsRiskyPatterns(input: string): bool =
  let riskyPatterns = @[
    " OR ", " AND ", " UNION ", " SELECT ", "INSERT ", "DELETE ", "UPDATE ", "DROP ",
    "EXEC ", "--", "/*", "*/",
  ]

  for pattern in riskyPatterns:
    if pattern.toLowerAscii() in input.toLowerAscii():
      return true

  return false

proc isSecureString(input: string): bool =
  ## Returns `false` if the string contains risky characters or patterns, `true` otherwise.
  let riskyChars = {'\'', '\"', ';', '#', '\\', '%', '_', '/', '*', '\0'}

  for ch in input:
    if ch in riskyChars:
      return false

  if containsRiskyPatterns(input):
    return false

  return true

proc convertQueryToMetricLabel*(query: string): string =
  ## Simple query categorization. The output label is the one that should be used in query metrics
  for snippetQuery, metric in QueriesToMetricMap.pairs():
    if $snippetQuery in query:
      return $metric
  return "unknown_query_metric"

proc dbConnQuery*(
    dbConnWrapper: DbConnWrapper,
    query: SqlQuery,
    args: seq[string],
    rowCallback: DataProc,
    requestId: string,
): Future[Result[void, string]] {.async, gcsafe.} =
  if not requestId.isSecureString():
    return err("the passed request id is not secure: " & requestId)

  dbConnWrapper.futBecomeFree = newFuture[void]("dbConnQuery")

  let metricLabel = convertQueryToMetricLabel($query)

  var queryStartTime = getTime().toUnixFloat()

  let reqIdAndQuery = "/* requestId=" & requestId & " */ " & $query
  (await dbConnWrapper.sendQuery(SqlQuery(reqIdAndQuery), args)).isOkOr:
    error "error in dbConnQuery", error = $error
    dbConnWrapper.futBecomeFree.fail(newException(ValueError, $error))
    return err("error in dbConnQuery calling sendQuery: " & $error)

  let sendDuration = getTime().toUnixFloat() - queryStartTime
  logos_delivery_query_time_secs.set(sendDuration, [metricLabel, "sendToDBQuery"])

  queryStartTime = getTime().toUnixFloat()

  (await dbConnWrapper.waitQueryToFinish(rowCallback)).isOkOr:
    return err("error in dbConnQuery calling waitQueryToFinish: " & $error)

  let waitDuration = getTime().toUnixFloat() - queryStartTime
  logos_delivery_query_time_secs.set(waitDuration, [metricLabel, "waitFinish"])

  logos_delivery_query_count.inc(labelValues = [metricLabel])

  if "insert" notin ($query).toLower():
    debug "dbConnQuery",
      requestId,
      query = $query,
      args,
      metricLabel,
      waitDbQueryDurationSecs = waitDuration,
      sendToDBDurationSecs = sendDuration

  return ok()

proc dbConnQueryPrepared*(
    dbConnWrapper: DbConnWrapper,
    stmtName: string,
    paramValues: seq[string],
    paramLengths: seq[int32],
    paramFormats: seq[int32],
    rowCallback: DataProc,
    requestId: string,
): Future[Result[void, string]] {.async, gcsafe.} =
  dbConnWrapper.futBecomeFree = newFuture[void]("dbConnQueryPrepared")
  var queryStartTime = getTime().toUnixFloat()

  dbConnWrapper.sendQueryPrepared(stmtName, paramValues, paramLengths, paramFormats).isOkOr:
    dbConnWrapper.futBecomeFree.fail(newException(ValueError, $error))
    error "error in dbConnQueryPrepared", error = $error
    return err("error in dbConnQueryPrepared calling sendQuery: " & $error)

  let sendDuration = getTime().toUnixFloat() - queryStartTime
  logos_delivery_query_time_secs.set(sendDuration, [stmtName, "sendToDBQuery"])

  queryStartTime = getTime().toUnixFloat()

  (await dbConnWrapper.waitQueryToFinish(rowCallback)).isOkOr:
    return err("error in dbConnQueryPrepared calling waitQueryToFinish: " & $error)

  let waitDuration = getTime().toUnixFloat() - queryStartTime
  logos_delivery_query_time_secs.set(waitDuration, [stmtName, "waitFinish"])

  logos_delivery_query_count.inc(labelValues = [stmtName])

  if "insert" notin stmtName.toLower():
    debug "dbConnQueryPrepared",
      requestId,
      stmtName,
      paramValues,
      waitDbQueryDurationSecs = waitDuration,
      sendToDBDurationSecs = sendDuration

  return ok()

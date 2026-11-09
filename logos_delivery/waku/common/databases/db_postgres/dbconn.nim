import
  std/[times, strutils, os, sets, strformat, tables],
  results,
  chronos,
  chronos/threadsync,
  metrics,
  chronicles
import ./query_metrics

include db_connector/db_postgres

when defined(windows):
  const libpqName = "libpq.dll"
elif defined(macosx):
  const libpqName = "libpq.dylib"
else:
  const libpqName = "libpq.so(.5|)"

proc pqsendPrepare(
  conn: PPGconn, stmtName, query: cstring, nParams: int32, paramTypes: POid
): int32 {.cdecl, dynlib: libpqName, importc: "PQsendPrepare".}
  ## db_connector only binds the blocking PQprepare

const DefaultConnectTimeout* = chronos.seconds(10)

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
  lockTimeoutMs*: int64 ## lock_timeout currently set in the session, 0 meaning none

## Connection management

proc unregisterFd(asyncFd: asyncengine.AsyncFD): Result[void, string] =
  ## chronos exposes no Result-returning unregister on Windows, where
  ## unregistering only drops the handle from the dispatcher and cannot fail
  when defined(windows):
    asyncengine.unregister(asyncFd)
  else:
    asyncengine.unregister2(asyncFd).isOkOr:
      return err($error)
  return ok()

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

proc markBusy*(dbConnWrapper: DbConnWrapper) =
  dbConnWrapper.futBecomeFree = newFuture[void]("DbConnWrapper.futBecomeFree")

proc markFree*(dbConnWrapper: DbConnWrapper) =
  if not dbConnWrapper.futBecomeFree.isNil() and
      not dbConnWrapper.futBecomeFree.finished():
    dbConnWrapper.futBecomeFree.complete()

proc isReusable*(dbConnWrapper: DbConnWrapper): bool =
  ## False while libpq still has a command in flight, e.g. after the awaiting
  ## query was cancelled, or once the backend is gone.
  return
    dbConnWrapper.open and dbConnWrapper.dbConn.status == CONNECTION_OK and
    dbConnWrapper.dbConn.pqtransactionStatus() notin {PQTRANS_ACTIVE, PQTRANS_UNKNOWN}

proc isCommandInFlight*(dbConnWrapper: DbConnWrapper): bool =
  ## True when libpq sent a command whose results were not fully read
  return
    dbConnWrapper.open and dbConnWrapper.dbConn.status == CONNECTION_OK and
    dbConnWrapper.dbConn.pqtransactionStatus() == PQTRANS_ACTIVE

proc backendPid*(dbConnWrapper: DbConnWrapper): int32 =
  return dbConnWrapper.dbConn.pqbackendPID()

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

proc errorText(db: DbConn): string =
  db.check().isOkOr:
    return error
  return "unknown reason"

proc waitForSocket(
    asyncFd: asyncengine.AsyncFD,
    forRead: bool,
    forWrite: bool,
    timeout = InfiniteDuration,
): Future[Result[void, string]] {.async.} =
  ## Waits until the socket is ready and gives the reader and writer back
  ## before returning. The caller must not touch libpq while they are installed:
  ## libpq closes the socket as soon as it notices the backend is gone, and
  ## removing a reader from an already closed descriptor fails, leaving the
  ## selector entry behind forever.

  when defined(windows):
    return err("Postgres not supported on Windows")
  else:
    let futReady = newFuture[void]("waitForSocket")

    proc onReady(udata: pointer) {.gcsafe, raises: [].} =
      if not futReady.finished():
        futReady.complete()

    var readerAdded = false
    var writerAdded = false
    defer:
      if readerAdded:
        asyncengine.removeReader2(asyncFd).isOkOr:
          error "failed to remove event reader in waitForSocket", error = $error
      if writerAdded:
        asyncengine.removeWriter2(asyncFd).isOkOr:
          error "failed to remove event writer in waitForSocket", error = $error

    if forRead:
      asyncengine.addReader2(asyncFd, onReady).isOkOr:
        return err("failed to add event reader: " & $error)
      readerAdded = true
    if forWrite:
      asyncengine.addWriter2(asyncFd, onReady).isOkOr:
        return err("failed to add event writer: " & $error)
      writerAdded = true

    if timeout == InfiniteDuration:
      await futReady
    elif not (await futReady.withTimeout(timeout)):
      return err("timed out after: " & $timeout)

    return ok()

proc pollConnection(
    conn: DbConn, timeout: chronos.Duration
): Future[Result[void, string]] {.async.} =
  ## Drives PQconnectPoll from chronos so that neither the TCP handshake nor the
  ## authentication can stall the event loop. libpq may switch sockets while
  ## connecting, so each wait registers the current one only for its duration.
  let deadline = Moment.now() + timeout
  var pollStatus = PGRES_POLLING_WRITING
  while true:
    case pollStatus
    of PGRES_POLLING_OK:
      return ok()
    of PGRES_POLLING_FAILED:
      return err("connection polling failed: " & conn.errorText())
    of PGRES_POLLING_READING, PGRES_POLLING_WRITING:
      let remaining = deadline - Moment.now()
      if remaining <= ZeroDuration:
        return err("timed out connecting after: " & $timeout)

      let asyncFd = cast[asyncengine.AsyncFD](pqsocket(conn))
      asyncengine.register2(asyncFd).isOkOr:
        return err("failed to register the connecting socket: " & $error)
      let waitRes =
        try:
          await waitForSocket(
            asyncFd,
            forRead = pollStatus == PGRES_POLLING_READING,
            forWrite = pollStatus == PGRES_POLLING_WRITING,
            timeout = remaining,
          )
        finally:
          unregisterFd(asyncFd).isOkOr:
            error "failed to unregister the connecting socket", error = error
      waitRes.isOkOr:
        return err("failed waiting for the connecting socket: " & $error)
    of PGRES_POLLING_ACTIVE:
      discard

    pollStatus = pqconnectPoll(conn)

proc openDbConn(
    connString: string, timeout: chronos.Duration
): Future[Result[DbConnWrapper, string]] {.async.} =
  let conn: DbConn = pqconnectStart(cstring(connString))
  if conn.isNil():
    return err("failed to allocate a connection: out of memory")

  var connected = false
  defer:
    if not connected:
      pqfinish(conn)

  if conn.status == CONNECTION_BAD:
    return err("failed to start connecting: " & conn.errorText())

  (await conn.pollConnection(timeout)).isOkOr:
    return err("failed to connect to database: " & $error)

  ## Sends only queue their data when the connection is nonblocking, and
  ## flushSend drives the rest, so a full socket buffer cannot stall the loop.
  if pqsetnonblocking(conn, 1) != 0:
    return err("failed to set the connection nonblocking: " & conn.errorText())

  ## registering the socket fd in chronos for better wait for data.
  ## The wrapper is built here so that the registered descriptor and the
  ## remembered one cannot drift apart.
  let asyncFd = cast[asyncengine.AsyncFD](pqsocket(conn))
  asyncengine.register2(asyncFd).isOkOr:
    return err("failed to register the connection socket: " & $error)

  connected = true
  return ok(DbConnWrapper(dbConn: conn, registeredFd: Opt.some(asyncFd), open: true))

proc new*(
    T: type DbConnWrapper, connString: string, connectTimeout = DefaultConnectTimeout
): Future[Result[T, string]] {.async.} =
  let dbConnWrapper = (await openDbConn(connString, connectTimeout)).valueOr:
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
      unregisterFd(asyncFd).isOkOr:
        unregisterError = "failed to unregister the connection socket: " & error

  dbConnWrapper.dbConn.close()
  dbConnWrapper.open = false

  if unregisterError.len > 0:
    return err(unregisterError)

  return ok()

proc `$`(self: SqlQuery): string =
  return cast[string](self)

proc flushSend(dbConnWrapper: DbConnWrapper): Future[Result[void, string]] {.async.} =
  ## The connection is nonblocking, so a send can leave data queued in libpq.
  let asyncFd = dbConnWrapper.registeredFd.valueOr:
    return err("the connection socket is not registered in flushSend")

  let conn = dbConnWrapper.dbConn
  while true:
    case pqflush(conn)
    of 0:
      return ok()
    of 1:
      ## The server may be waiting for us to read before it accepts more, so
      ## both directions are watched.
      (await waitForSocket(asyncFd, forRead = true, forWrite = true)).isOkOr:
        return err("failed waiting to flush the query: " & $error)

      if pqconsumeInput(conn) != 1:
        return err("failed to read while flushing the query: " & conn.errorText())
    else:
      return err("failed to flush the query: " & conn.errorText())

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

  (await dbConnWrapper.flushSend()).isOkOr:
    return err("failed flushing pqsendQuery: " & $error)

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

proc waitQueryToFinish(
    dbConnWrapper: DbConnWrapper, rowCallback: DataProc = nil
): Future[Result[void, string]] {.async.} =
  ## The 'rowCallback' param is != nil when the underlying query wants to retrieve results (SELECT.)
  ## For other queries, like "INSERT", 'rowCallback' should be nil.
  ## pqgetResult blocks while a result is only partly received, so it is only
  ## called once pqisBusy says the whole result is buffered.

  let asyncFd = dbConnWrapper.registeredFd.valueOr:
    return err("the connection socket is not registered in waitQueryToFinish")

  let conn = dbConnWrapper.dbConn
  while true:
    if pqconsumeInput(conn) != 1:
      return err("failed to read the query result: " & conn.errorText())

    if pqisBusy(conn) == 1:
      (await waitForSocket(asyncFd, forRead = true, forWrite = false)).isOkOr:
        return err("failed waiting for the query result: " & $error)
      continue

    let pqResult = pqgetResult(conn)
    if pqResult == nil:
      conn.check().isOkOr:
        return err("error in query: " & $error)
      return ok() # reached the end of the results. The query is completed

    if not rowCallback.isNil():
      rowCallback(pqResult)

    pqclear(pqResult)

proc dbConnPrepare*(
    dbConnWrapper: DbConnWrapper, stmtName: string, stmtDefinition: string, nParams: int
): Future[Result[void, string]] {.async.} =
  ## The prepare can wait on table locks server-side, so it has to be awaited
  ## like any other query instead of using the blocking PQprepare.
  if pqsendPrepare(
    dbConnWrapper.dbConn,
    cstring(stmtName),
    cstring(stmtDefinition),
    int32(nParams),
    nil,
  ) != 1:
    return err("failed pqsendPrepare: " & dbConnWrapper.dbConn.errorText())

  (await dbConnWrapper.flushSend()).isOkOr:
    return err("failed flushing pqsendPrepare: " & $error)

  (await dbConnWrapper.waitQueryToFinish()).isOkOr:
    return err("failed preparing statement: " & stmtName & ": " & $error)

  return ok()

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

  let metricLabel = convertQueryToMetricLabel($query)

  var queryStartTime = getTime().toUnixFloat()

  let reqIdAndQuery = "/* requestId=" & requestId & " */ " & $query
  (await dbConnWrapper.sendQuery(SqlQuery(reqIdAndQuery), args)).isOkOr:
    error "error in dbConnQuery", error = $error
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
  var queryStartTime = getTime().toUnixFloat()

  dbConnWrapper.sendQueryPrepared(stmtName, paramValues, paramLengths, paramFormats).isOkOr:
    error "error in dbConnQueryPrepared", error = $error
    return err("error in dbConnQueryPrepared calling sendQuery: " & $error)

  (await dbConnWrapper.flushSend()).isOkOr:
    return err("error in dbConnQueryPrepared calling flushSend: " & $error)

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

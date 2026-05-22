{.push raises: [].}

import std/net
import
  results,
  chronicles,
  chronos,
  chronos/apps/http/httpserver,
  presto,
  presto/middleware,
  presto/servercommon

import ./origin_handler

type
  RestServerResult*[T] = Result[T, string]

  WakuRestServer* = object of RootObj
    router*: RestRouter
    httpServer*: HttpServerRef

  WakuRestServerRef* = ref WakuRestServer

### Configuration

type RestServerConf* {.requiresInit.} = object
  cacheSize*: Natural
    ## \
    ## The maximum number of recently accessed states that are kept in \
    ## memory. Speeds up requests obtaining information for consecutive
    ## slots or epochs.

  cacheTtl*: Natural
    ## \
    ## The number of seconds to keep recently accessed states in memory

  requestTimeout*: Natural
    ## \
    ## The number of seconds to wait until complete REST request will be received

  maxRequestBodySize*: Natural
    ## \
    ## Maximum size of REST request body (kilobytes)

  maxRequestHeadersSize*: Natural
    ## \
    ## Maximum size of REST request headers (kilobytes)

proc default*(T: type RestServerConf): T =
  RestServerConf(
    cacheSize: 3,
    cacheTtl: 60,
    requestTimeout: 0,
    maxRequestBodySize: 16_384,
    maxRequestHeadersSize: 64,
  )

### Initialization

proc new*(
    t: typedesc[WakuRestServerRef],
    router: RestRouter,
    address: TransportAddress,
    serverIdent: string = PrestoIdent,
    serverFlags = {HttpServerFlags.NotifyDisconnect},
    socketFlags: set[ServerFlags] = {ReuseAddr},
    serverUri = Uri(),
    maxConnections: int = -1,
    backlogSize: int = DefaultBacklogSize,
    bufferSize: int = 4096,
    httpHeadersTimeout = 10.seconds,
    maxHeadersSize: int = 8192,
    maxRequestBodySize: int = 1_048_576,
    requestErrorHandler: RestRequestErrorHandler = nil,
    dualstack = DualStackType.Auto,
    allowedOrigin: Option[string] = none(string),
): RestServerResult[WakuRestServerRef] =
  var server = WakuRestServerRef(router: router)

  let restMiddleware = RestServerMiddlewareRef.new(
    router = server.router, errorHandler = requestErrorHandler
  )
  let originHandlerMiddleware = OriginHandlerMiddlewareRef.new(allowedOrigin)

  let middlewares = [originHandlerMiddleware, restMiddleware]

  ## This must be empty and needed only to confirm original initialization requirements of
  ## the RestHttpServer now combining old and new middleware approach.
  proc defaultProcessCallback(
      rf: RequestFence
  ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
    discard

  server.httpServer = ?HttpServerRef.new(
    address,
    defaultProcessCallback,
    serverFlags,
    socketFlags,
    serverUri,
    serverIdent,
    maxConnections,
    bufferSize,
    backlogSize,
    httpHeadersTimeout,
    maxHeadersSize,
    maxRequestBodySize,
    dualstack = dualstack,
    middlewares = middlewares,
  )
  return ok(server)

proc getRouter(): RestRouter =
  # TODO: Review this `validate` method. Check in nim-presto what is this used for.
  proc validate(pattern: string, value: string): int =
    ## This is rough validation procedure which should be simple and fast,
    ## because it will be used for query routing.
    if pattern.startsWith("{") and pattern.endsWith("}"): 0 else: 1

  # disable allowed origin handling by presto, we add our own handling as middleware
  RestRouter.init(validate, allowedOrigin = none(string))

proc init*(
    T: type WakuRestServerRef,
    ip: IpAddress,
    port: Port,
    allowedOrigin = none(string),
    conf = RestServerConf.default(),
    requestErrorHandler: RestRequestErrorHandler = nil,
): RestServerResult[T] =
  let address = initTAddress(ip, port)
  let serverFlags =
    {HttpServerFlags.QueryCommaSeparatedArray, HttpServerFlags.NotifyDisconnect}

  let
    headersTimeout =
      if conf.requestTimeout == 0:
        chronos.InfiniteDuration
      else:
        seconds(int64(conf.requestTimeout))
    maxHeadersSize = conf.maxRequestHeadersSize * 1024
    maxRequestBodySize = conf.maxRequestBodySize * 1024

  let router = getRouter()

  try:
    return WakuRestServerRef.new(
      router,
      address,
      serverFlags = serverFlags,
      httpHeadersTimeout = headersTimeout,
      maxHeadersSize = maxHeadersSize,
      maxRequestBodySize = maxRequestBodySize,
      requestErrorHandler = requestErrorHandler,
      allowedOrigin = allowedOrigin,
    )
  except CatchableError:
    return err(getCurrentExceptionMsg())

proc newRestHttpServer*(
    ip: IpAddress,
    port: Port,
    allowedOrigin = none(string),
    conf = RestServerConf.default(),
    requestErrorHandler: RestRequestErrorHandler = nil,
): RestServerResult[WakuRestServerRef] =
  WakuRestServerRef.init(ip, port, allowedOrigin, conf, requestErrorHandler)

proc localAddress*(rs: WakuRestServerRef): TransportAddress =
  ## Returns `rs` bound local socket address.
  rs.httpServer.instance.localAddress()

proc state*(rs: WakuRestServerRef): RestServerState =
  ## Returns current REST server's state.
  case rs.httpServer.state
  of HttpServerState.ServerClosed: RestServerState.Closed
  of HttpServerState.ServerStopped: RestServerState.Stopped
  of HttpServerState.ServerRunning: RestServerState.Running

proc start*(rs: WakuRestServerRef) =
  ## Starts REST server.
  rs.httpServer.start()
  notice "REST service started", address = $rs.localAddress()

proc stop*(rs: WakuRestServerRef) {.async: (raises: []).} =
  ## Stop REST server from accepting new connections.
  await rs.httpServer.stop()
  notice "REST service stopped", address = $rs.localAddress()

proc drop*(rs: WakuRestServerRef): Future[void] {.async: (raw: true, raises: []).} =
  ## Drop all pending connections.
  rs.httpServer.drop()

proc closeWait*(rs: WakuRestServerRef) {.async: (raises: []).} =
  ## Stop REST server and drop all the pending connections.
  await rs.httpServer.closeWait()
  notice "REST service closed", address = $rs.localAddress()

proc join*(
    rs: WakuRestServerRef
): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Wait until REST server will not be closed.
  rs.httpServer.join()

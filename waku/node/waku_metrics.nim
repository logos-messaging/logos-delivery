{.push raises: [].}

import chronicles, chronos, metrics, metrics/chronos_httpserver
import
  waku/[
    common/auto_port,
    waku_rln_relay/protocol_metrics as rln_metrics,
    utils/collector,
  ],
  ./peer_manager,
  ./waku_node

const LogInterval = 10.minutes

logScope:
  topics = "waku node metrics"

type MetricsServerConf* = object
  httpAddress*: IpAddress
  httpPort*: Port
  logging*: bool

proc startMetricsLog*() =
  var logMetrics: CallbackFunc

  var cumulativeErrors = 0.float64
  var cumulativeConns = 0.float64

  let logRlnMetrics = getRlnMetricsLogger()

  logMetrics = CallbackFunc(
    proc(udata: pointer) {.gcsafe.} =
      # TODO: libp2p_pubsub_peers is not public, so we need to make this either
      # public in libp2p or do our own peer counting after all.

      # track cumulative values
      let freshErrorCount = parseAndAccumulate(waku_node_errors, cumulativeErrors)
      let freshConnCount =
        parseAndAccumulate(waku_node_conns_initiated, cumulativeConns)

      let totalMessages = collectorAsF64(waku_node_messages)
      let storePeers = collectorAsF64(waku_store_peers)
      let pxPeers = collectorAsF64(waku_px_peers)
      let lightpushPeers = collectorAsF64(waku_lightpush_peers)
      let filterPeers = collectorAsF64(waku_filter_peers)

      info "Total connections initiated", count = $freshConnCount
      info "Total messages", count = totalMessages
      info "Total store peers", count = storePeers
      info "Total peer exchange peers", count = pxPeers
      info "Total lightpush peers", count = lightpushPeers
      info "Total filter peers", count = filterPeers
      info "Total errors", count = $freshErrorCount

      # Start protocol specific metrics logging
      logRlnMetrics()

      discard setTimer(Moment.fromNow(LogInterval), logMetrics)
  )

  discard setTimer(Moment.fromNow(LogInterval), logMetrics)

type StartedMetricsServer* = tuple[server: MetricsHttpServerRef, port: Port]

proc startMetricsServer(
    serverIp: IpAddress, serverPort: Port
): Future[Result[StartedMetricsServer, string]] {.async.} =
  let autoMode = serverPort == Port(0)
  let attempts = if autoMode: AutoPortRetryCount else: 1
  var lastErr = ""

  for attempt in 1 .. attempts:
    let port =
      if autoMode:
        Port(getAutoPort())
      else:
        serverPort
    info "Starting metrics HTTP server", serverIp = $serverIp, serverPort = $port

    let server = MetricsHttpServerRef.new($serverIp, port).valueOr:
      lastErr = $error
      continue

    try:
      await server.start()
    except CatchableError:
      lastErr = getCurrentExceptionMsg()
      continue

    info "Metrics HTTP server started", serverIp = $serverIp, serverPort = $port
    return ok((server: server, port: port))

  if autoMode:
    return err("metrics HTTP server: auto-port bind exhausted; last error: " & lastErr)
  return err("metrics HTTP server start failed: " & lastErr)

proc startMetricsServerAndLogging*(
    conf: MetricsServerConf, portsShift: uint16
): Future[Result[StartedMetricsServer, string]] {.async.} =
  let started = (
    await (
      startMetricsServer(conf.httpAddress, Port(conf.httpPort.uint16 + portsShift))
    )
  ).valueOr:
    return err("Starting metrics server failed. Continuing in current state:" & $error)

  if conf.logging:
    startMetricsLog()

  return ok(started)

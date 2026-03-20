{.push raises: [].}

import
  std/[options, strutils, os, sequtils, net],
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  system/ansi_c,
  libp2p/crypto/crypto,
  confutils

import
  tools/confutils/cli_args,
  waku/[
    common/enr,
    common/logging,
    factory/waku as waku_factory,
    waku_node,
    node/waku_metrics,
    node/peer_manager,
    waku_lightpush/common,
    waku_filter_v2,
    waku_peer_exchange/protocol,
    waku_core/peers,
    waku_core/multiaddrstr,
  ],
  ./tester_config,
  ./publisher,
  ./receiver,
  ./diagnose_connections,
  ./service_peer_management

logScope:
  topics = "liteprotocoltester main"

proc logConfig(conf: LiteProtocolTesterConf) =
  info "Configuration: Lite protocol tester", conf = $conf

{.pop.}
when isMainModule:
  ## Node setup happens in 6 phases:
  ## 1. Set up storage
  ## 2. Initialize node
  ## 3. Mount and initialize configured protocols
  ## 4. Start node and mounted protocols
  ## 5. Start monitoring tools and external interfaces
  ## 6. Setup graceful shutdown hooks

  const versionString = "version / git commit hash: " & waku_factory.git_version

  let conf = LiteProtocolTesterConf.load(version = versionString).valueOr:
    error "failure while loading the configuration", error = error
    quit(QuitFailure)

  ## Logging setup
  logging.setupLog(conf.logLevel, conf.logFormat)

  info "Running Lite Protocol Tester node", version = waku_factory.git_version
  logConfig(conf)

  ##Prepare Waku configuration
  ## - load from config file
  ## - override according to tester functionality
  ##

  var wakuNodeConf: WakuNodeConf

  if conf.configFile.isSome():
    try:
      var configFile {.threadvar.}: InputFile
      configFile = conf.configFile.get()
      wakuNodeConf = WakuNodeConf.load(
        version = versionString,
        printUsage = false,
        secondarySources = proc(
            wnconf: WakuNodeConf, sources: auto
        ) {.gcsafe, raises: [ConfigurationError].} =
          echo "Loading secondary configuration file into WakuNodeConf"
          sources.addConfigFile(Toml, configFile),
      )
    except CatchableError:
      error "Loading Waku configuration failed", error = getCurrentExceptionMsg()
      quit(QuitFailure)

  wakuNodeConf.logLevel = conf.logLevel
  wakuNodeConf.logFormat = conf.logFormat
  wakuNodeConf.nat = conf.nat
  wakuNodeConf.maxConnections = 500
  wakuNodeConf.restAddress = conf.restAddress
  wakuNodeConf.restPort = conf.restPort
  wakuNodeConf.restAllowOrigin = conf.restAllowOrigin

  wakuNodeConf.dnsAddrsNameServers =
    @[parseIpAddress("8.8.8.8"), parseIpAddress("1.1.1.1")]

  wakuNodeConf.shards = @[conf.shard]
  wakuNodeConf.contentTopics = conf.contentTopics
  wakuNodeConf.clusterId = conf.clusterId
  ## TODO: Depending on the tester needs we might extend here with shards, clusterId, etc...

  wakuNodeConf.metricsServer = true
  wakuNodeConf.metricsServerAddress = parseIpAddress("0.0.0.0")
  wakuNodeConf.metricsServerPort = conf.metricsPort

  # If bootstrap option is chosen we expect our clients will not mounted
  # so we will mount PeerExchange manually to gather possible service peers,
  # if got some we will mount the client protocols afterward.
  wakuNodeConf.peerExchange = false
  wakuNodeConf.relay = false
  wakuNodeConf.filter = false
  wakuNodeConf.lightpush = false
  wakuNodeConf.store = false

  wakuNodeConf.rest = false
  wakuNodeConf.relayServiceRatio = "40:60"

  let wakuConf = wakuNodeConf.toWakuConf().valueOr:
    error "Issue converting toWakuConf", error = $error
    quit(QuitFailure)

  var waku = (waitFor Waku.new(wakuConf)).valueOr:
    error "Waku initialization failed", error = error
    quit(QuitFailure)

  (waitFor startWaku(addr waku)).isOkOr:
    error "Starting waku failed", error = error
    quit(QuitFailure)

  info "Setting up shutdown hooks"

  proc asyncStopper(waku: Waku) {.async: (raises: [Exception]).} =
    (await waku.stop()).isOkOr:
      error "Waku shutdown failed", error = error
    quit(QuitSuccess)

  # Handle Ctrl-C SIGINT
  proc handleCtrlC() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    notice "Shutting down after receiving SIGINT"
    asyncSpawn asyncStopper(waku)

  setControlCHook(handleCtrlC)

  # Handle SIGTERM
  when defined(posix):
    proc handleSigterm(signal: cint) {.noconv.} =
      notice "Shutting down after receiving SIGTERM"
      asyncSpawn asyncStopper(waku)

    c_signal(ansi_c.SIGTERM, handleSigterm)

  # Handle SIGSEGV
  when defined(posix):
    proc handleSigsegv(signal: cint) {.noconv.} =
      # Require --debugger:native
      fatal "Shutting down after receiving SIGSEGV", stacktrace = getBacktrace()

      # Not available in -d:release mode
      writeStackTrace()

      (waitFor waku.stop()).isOkOr:
        error "Waku shutdown failed", error = error
      quit(QuitFailure)

    c_signal(ansi_c.SIGSEGV, handleSigsegv)

  info "Node setup complete"

  var codec = WakuLightPushCodec
  # mounting relevant client, for PX filter client must be mounted ahead
  if conf.testFunc == TesterFunctionality.SENDER:
    codec = WakuLightPushCodec
  else:
    codec = WakuFilterSubscribeCodec

  var lookForServiceNode = false
  var serviceNodePeerInfo: RemotePeerInfo
  if conf.serviceNode.len == 0:
    if conf.bootstrapNode.len > 0:
      info "Bootstrapping with PeerExchange to gather random service node"
      let futForServiceNode = pxLookupServiceNode(waku.node, conf)
      if not (waitFor futForServiceNode.withTimeout(20.minutes)):
        error "Service node not found in time via PX"
        quit(QuitFailure)

      futForServiceNode.read().isOkOr:
        error "Service node for test not found via PX"
        quit(QuitFailure)

      serviceNodePeerInfo = selectRandomServicePeer(
        waku.node.peerManager, none(RemotePeerInfo), codec
      ).valueOr:
        error "Service node selection failed"
        quit(QuitFailure)
    else:
      error "No service or bootstrap node provided"
      quit(QuitFailure)
  else:
    # support for both ENR and URI formatted service node addresses
    serviceNodePeerInfo = translateToRemotePeerInfo(conf.serviceNode).valueOr:
      error "failed to parse service-node", node = conf.serviceNode
      quit(QuitFailure)

  info "Service node to be used", serviceNode = $serviceNodePeerInfo

  logSelfPeers(waku.node.peerManager)

  if conf.testFunc == TesterFunctionality.SENDER:
    setupAndPublish(waku.node, conf, serviceNodePeerInfo)
  else:
    setupAndListen(waku.node, conf, serviceNodePeerInfo)

  runForever()

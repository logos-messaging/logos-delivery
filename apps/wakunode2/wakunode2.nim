{.push raises: [].}

import
  std/[options, strutils, sequtils, net],
  chronicles,
  chronos,
  metrics,
  system/ansi_c,
  libp2p/crypto/crypto
import
  ../../tools/[rln_keystore_generator/rln_keystore_generator, confutils/cli_args],
  waku/[
    common/logging,
    factory/waku,
    node/health_monitor,
    rest_api/endpoint/builder as rest_server_builder,
    waku_core/message/default_values,
  ]

logScope:
  topics = "wakunode main"

const git_version* {.strdefine.} = "n/a"

{.pop.}
  # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
when isMainModule:
  ## Node setup happens in 6 phases:
  ## 1. Set up storage
  ## 2. Initialize node
  ## 3. Mount and initialize configured protocols
  ## 4. Start node and mounted protocols
  ## 5. Start monitoring tools and external interfaces
  ## 6. Setup graceful shutdown hooks

  const versionString = "version / git commit hash: " & waku.git_version

  var wakuNodeConf = WakuNodeConf.load(version = versionString).valueOr:
    error "failure while loading the configuration", error = error
    quit(QuitFailure)

  ## Also called within Waku.new. The call to startRestServerEssentials needs the following line
  logging.setupLog(wakuNodeConf.logLevel, wakuNodeConf.logFormat)

  case wakuNodeConf.cmd
  of generateRlnKeystore:
    let conf = wakuNodeConf.toKeystoreGeneratorConf()
    doRlnKeystoreGenerator(conf)
  of noCommand:
    let conf = wakuNodeConf.toWakuConf().valueOr:
      error "Waku configuration failed", error = error
      quit(QuitFailure)

    var waku = (waitFor Waku.new(conf)).valueOr:
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
        fatal "Shutting down after receiving SIGSEGV"

        # Not available in -d:release mode
        writeStackTrace()

        (waitFor waku.stop()).isOkOr:
          error "Waku shutdown failed", error = error
        quit(QuitFailure)

      c_signal(ansi_c.SIGSEGV, handleSigsegv)

    info "Node setup complete"

    runForever()

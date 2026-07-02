{.push raises: [].}

import
  std/[options, strutils, sequtils, net],
  chronicles,
  chronos,
  metrics,
  system/ansi_c,
  libp2p/crypto/crypto
import
  ../../tools/confutils/cli_args,
  logos_delivery/logos_delivery,
  logos_delivery/waku/common/logging

logScope:
  topics = "logosdeliverynode main"

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

  const versionString = "version / git commit hash: " & git_version

  var wakuNodeConf = WakuNodeConf.load(version = versionString).valueOr:
    error "failure while loading the configuration", error = error
    quit(QuitFailure)

  ## Also called within LogosDelivery.new. The call to startRestServerEssentials
  ## needs the following line
  logging.setupLog(wakuNodeConf.logLevel, wakuNodeConf.logFormat)

  case wakuNodeConf.cmd
  of generateRlnKeystore:
    error "generateRlnKeystore not supported by logos_delivery_node; use wakunode2"
    quit(QuitFailure)
  of noCommand:
    # `LogosDelivery` derives the per-layer config from `WakuNodeConf` itself
    # (it runs `toWakuConf` internally), then builds the full stack bottom-up:
    #   Waku <- MessagingClient <- ReliableChannelManager
    var node = (waitFor LogosDelivery.new(wakuNodeConf)).valueOr:
      error "LogosDelivery initialization failed", error = error
      quit(QuitFailure)

    (waitFor node.start()).isOkOr:
      error "Starting LogosDelivery failed", error = error
      quit(QuitFailure)

    info "Setting up shutdown hooks"
    proc asyncStopper(node: LogosDelivery) {.async: (raises: [Exception]).} =
      (await node.stop()).isOkOr:
        error "LogosDelivery shutdown failed", error = error
      quit(QuitSuccess)

    # Handle Ctrl-C SIGINT
    proc handleCtrlC() {.noconv.} =
      when defined(windows):
        # workaround for https://github.com/nim-lang/Nim/issues/4057
        setupForeignThreadGc()
      notice "Shutting down after receiving SIGINT"
      asyncSpawn asyncStopper(node)

    setControlCHook(handleCtrlC)

    # Handle SIGTERM
    when defined(posix):
      proc handleSigterm(signal: cint) {.noconv.} =
        notice "Shutting down after receiving SIGTERM"
        asyncSpawn asyncStopper(node)

      c_signal(ansi_c.SIGTERM, handleSigterm)

    # Handle SIGSEGV
    when defined(posix):
      proc handleSigsegv(signal: cint) {.noconv.} =
        # Require --debugger:native
        fatal "Shutting down after receiving SIGSEGV"

        # Not available in -d:release mode
        writeStackTrace()

        (waitFor node.stop()).isOkOr:
          error "LogosDelivery shutdown failed", error = error
        quit(QuitFailure)

      c_signal(ansi_c.SIGSEGV, handleSigsegv)

    info "Node setup complete"

    runForever()

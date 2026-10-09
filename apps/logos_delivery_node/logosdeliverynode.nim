{.push raises: [].}

import
  std/[atomics, options, strutils, sequtils, net],
  chronicles,
  chronos,
  metrics,
  system/ansi_c,
  libp2p/crypto/crypto
import
  tools/confutils/cli_args,
  logos_delivery/logos_delivery,
  logos_delivery/waku/common/logging,
  rest/rest_service

logScope:
  topics = "logosdeliverynode main"

const git_version* {.strdefine.} = "n/a"

# Written from signal handlers, so it must stay a lock-free atomic: nothing else
# (allocation, logging, chronos scheduling) is async-signal-safe.
var shutdownSignal: Atomic[int]

proc requestShutdown(signal: cint) {.noconv.} =
  shutdownSignal.store(int(signal))

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

  var nodeConf = LogosDeliveryNodeConf.load(version = versionString).valueOr:
    error "failure while loading the configuration", error = error
    quit(QuitFailure)

  ## Also called within LogosDelivery.new. The REST service needs the following
  ## line
  logging.setupLog(nodeConf.kernel.logLevel, nodeConf.kernel.logFormat)

  # `LogosDelivery` derives the per-layer config from `LogosDeliveryNodeConf` itself
  # (it runs `toWakuConf` internally), then builds the layers bottom-up:
  #   Waku <- MessagingClient <- ReliableChannelManager
  # How far up it goes is set by `--entry-layer` (default `kernel`: Waku only).
  var node = (waitFor LogosDelivery.new(nodeConf)).valueOr:
    error "LogosDelivery initialization failed", error = error
    quit(QuitFailure)

  # REST is an adapter above the node (like the FFI library): it owns the HTTP
  # server and every route, and answers health probes while the node boots.
  let rest = RestService.new(node)
  (waitFor rest.startNode()).isOkOr:
    error "Starting LogosDelivery failed", error = error
    quit(QuitFailure)

  info "Setting up shutdown hooks"
  proc handleCtrlC() {.noconv.} =
    requestShutdown(ansi_c.SIGINT)

  setControlCHook(handleCtrlC)

  when defined(posix):
    c_signal(ansi_c.SIGTERM, requestShutdown)

  # Handle SIGSEGV
  when defined(posix):
    proc handleSigsegv(signal: cint) {.noconv.} =
      # Require --debugger:native
      fatal "Shutting down after receiving SIGSEGV"

      # Not available in -d:release mode
      writeStackTrace()

      # No graceful stop: the process state is already corrupted and stopping
      # would re-enter the event loop from inside the signal handler.
      quit(QuitFailure)

    c_signal(ansi_c.SIGSEGV, handleSigsegv)

  # Polled from the dispatcher so the stop runs exactly once, outside any
  # signal handler. chronos' waitSignal is not used because signalfd needs the
  # signal blocked in every thread, and worker threads may already exist here.
  proc waitForShutdown(rest: RestService) {.async: (raises: [CancelledError]).} =
    while shutdownSignal.load() == 0:
      await sleepAsync(100.milliseconds)

    notice "Shutting down after receiving signal", signal = shutdownSignal.load()
    let stopRes =
      try:
        await rest.stopNode()
      except CancelledError as e:
        raise e
      except CatchableError as e:
        Result[void, string].err(e.msg)
    stopRes.isOkOr:
      error "LogosDelivery shutdown failed", error = error
    quit(QuitSuccess)

  info "Node setup complete"

  waitFor waitForShutdown(rest)

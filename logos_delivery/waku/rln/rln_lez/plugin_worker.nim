{.push raises: [].}

## The RLN plugin worker threads.
##
## Four threads, one per isolation lane, each running its own chronos loop
## and hosting the `(mt)` providers for its verbs (`./plugin_accessor`).
## Every vtable entry point is invoked here — blocking that lane's thread for
## as long as the call takes — so the node's event loop only ever awaits an
## MT request. Lanes exist so no verb can convoy behind another:
##
##   fast     — start, stop, get_epoch_quota, validate_proof (ms-scale)
##   register — register_membership (up to minutes: chain transaction)
##   state    — get_membership_state (the polls that observe a pending
##              register must not queue behind it)
##   generate — generate_proof (send path; must not wait on registry verbs)
##
## Providers check the request's deadline before touching the vtable: the
## (mt) queue does not drop a request whose requester already timed out, so
## without the check a burst would serve dead work. The remaining budget is
## what the plugin receives as timeout_ms.
##
## The vtable travels as the thread argument — plain pointers and scalars,
## copied onto each worker's stack, immutable while the workers live because
## install is refused until the previous plugin is cleared and the workers
## joined.

import std/atomics
import chronos, chronicles, results
import brokers/broker_context
import ./plugin_accessor

logScope:
  topics = "waku rln plugin worker"

type
  RlnLane = enum
    FastLane
    RegisterLane
    StateLane
    GenerateLane

  WorkerArg =
    tuple[
      ctx: BrokerContext,
      plugin: RlnPlugin,
      lane: RlnLane,
      shutdown: ptr Atomic[bool],
      ready: ptr Atomic[bool],
    ]

  LaneRec = object
    thread: Thread[WorkerArg]
    shutdown: ptr Atomic[bool]
    ready: ptr Atomic[bool]

  RlnPluginWorkers* = ref object
    lanes: array[RlnLane, LaneRec]
    running: bool

proc remainingMs(deadlineNs: int64): int64 =
  (deadlineNs - Moment.now().epochNanoSeconds) div 1_000_000

proc readErr(errBuf: string, rc: int32, op: string): string =
  ## Error string convention consumed by `./transport`'s error mapping: a
  ## leading rc tag ("not_ready" | "timeout" | "internal"), then the
  ## plugin's message.
  var msg = ""
  for c in errBuf:
    if c == '\0':
      break
    msg.add(c)
  if msg.len == 0:
    msg = "status " & $rc
  let tag =
    case rc
    of LdRlnNotReady: "not_ready"
    of LdRlnTimeout: "timeout"
    else: "internal"
  tag & ": rln plugin " & op & ": " & msg

proc takeJson(plugin: RlnPlugin, outJson: cstring): string =
  ## Copies the plugin-owned JSON, then hands the buffer back (same thread,
  ## per the ABI contract).
  if outJson.isNil():
    return ""
  result = $outJson
  plugin.freeString(plugin.pluginCtx, outJson)

template budgetOrBail(deadlineNs: int64, op: string): uint32 =
  ## Remaining budget for this call, or an immediate err without touching
  ## the vtable when the requester's deadline already passed in the queue.
  let remaining = remainingMs(deadlineNs)
  if remaining <= 0:
    return err("timeout: rln plugin " & op & ": expired in queue")
  uint32(remaining)

proc workerMain(arg: WorkerArg) {.thread.} =
  ## Owns a chronos loop for one lane; that lane's MT brokers dispatch onto
  ## it. Reprovide, not provide: a previous worker generation may still hold
  ## a registration pointing at a thread that has since been joined.
  let ctx = arg.ctx
  let plugin = arg.plugin
  setThreadBrokerContext(ctx)

  case arg.lane
  of FastLane:
    discard PluginRlnStart.reprovideIt(ctx):
      let budget = budgetOrBail(deadlineNs, "start")
      var
        errBuf = newString(LdRlnErrBufLen)
        outJson: cstring = nil
      let rc = plugin.start(
        plugin.pluginCtx, configJson.cstring, budget, addr outJson, errBuf.cstring,
        errBuf.len.csize_t,
      )
      if rc != LdRlnOk:
        return err(readErr(errBuf, rc, "start"))
      ok(plugin.takeJson(outJson))

    discard PluginRlnStop.reprovideIt(ctx):
      let budget = budgetOrBail(deadlineNs, "stop")
      var
        errBuf = newString(LdRlnErrBufLen)
        outJson: cstring = nil
      let rc = plugin.stop(
        plugin.pluginCtx, budget, addr outJson, errBuf.cstring, errBuf.len.csize_t
      )
      if rc != LdRlnOk:
        return err(readErr(errBuf, rc, "stop"))
      ok(plugin.takeJson(outJson))

    discard PluginRlnGetQuota.reprovideIt(ctx):
      let budget = budgetOrBail(deadlineNs, "get_epoch_quota")
      var
        errBuf = newString(LdRlnErrBufLen)
        outJson: cstring = nil
      let rc = plugin.getEpochQuota(
        plugin.pluginCtx, registryId.cstring, rlnIdentifier.cstring, timestamp,
        budget, addr outJson, errBuf.cstring, errBuf.len.csize_t,
      )
      if rc != LdRlnOk:
        return err(readErr(errBuf, rc, "get_epoch_quota"))
      ok(plugin.takeJson(outJson))

    discard PluginRlnValidate.reprovideIt(ctx):
      let budget = budgetOrBail(deadlineNs, "validate_proof")
      var
        errBuf = newString(LdRlnErrBufLen)
        outJson: cstring = nil
      let rc = plugin.validateProof(
        plugin.pluginCtx, registryId.cstring, rlnIdentifier.cstring,
        signalHex.cstring, timestamp, proofJson.cstring, budget, addr outJson,
        errBuf.cstring, errBuf.len.csize_t,
      )
      if rc != LdRlnOk:
        return err(readErr(errBuf, rc, "validate_proof"))
      ok(plugin.takeJson(outJson))
  of RegisterLane:
    discard PluginRlnRegister.reprovideIt(ctx):
      let budget = budgetOrBail(deadlineNs, "register_membership")
      var
        errBuf = newString(LdRlnErrBufLen)
        outJson: cstring = nil
      let rc = plugin.registerMembership(
        plugin.pluginCtx, registryId.cstring, rlnIdentifier.cstring,
        optionsJson.cstring, budget, addr outJson, errBuf.cstring,
        errBuf.len.csize_t,
      )
      if rc != LdRlnOk:
        return err(readErr(errBuf, rc, "register_membership"))
      ok(plugin.takeJson(outJson))
  of StateLane:
    discard PluginRlnGetState.reprovideIt(ctx):
      let budget = budgetOrBail(deadlineNs, "get_membership_state")
      var
        errBuf = newString(LdRlnErrBufLen)
        outJson: cstring = nil
      let rc = plugin.getMembershipState(
        plugin.pluginCtx, registryId.cstring, rlnIdentifier.cstring, budget,
        addr outJson, errBuf.cstring, errBuf.len.csize_t,
      )
      if rc != LdRlnOk:
        return err(readErr(errBuf, rc, "get_membership_state"))
      ok(plugin.takeJson(outJson))
  of GenerateLane:
    discard PluginRlnGenerate.reprovideIt(ctx):
      let budget = budgetOrBail(deadlineNs, "generate_proof")
      var
        errBuf = newString(LdRlnErrBufLen)
        outJson: cstring = nil
      let rc = plugin.generateProof(
        plugin.pluginCtx, registryId.cstring, rlnIdentifier.cstring,
        signalHex.cstring, timestamp, budget, addr outJson, errBuf.cstring,
        errBuf.len.csize_t,
      )
      if rc != LdRlnOk:
        return err(readErr(errBuf, rc, "generate_proof"))
      ok(plugin.takeJson(outJson))

  arg.ready[].store(true)
  info "rln plugin worker started", lane = $arg.lane, ctx = $ctx

  # A timer keeps the loop from parking forever with no pending work, so the
  # shutdown flag is observed promptly.
  proc tick() {.async: (raises: []).} =
    while not arg.shutdown[].load():
      try:
        await sleepAsync(chronos.milliseconds(50))
      except CancelledError:
        return

  let ticker = tick()
  while not arg.shutdown[].load():
    try:
      poll()
    except CatchableError:
      error "rln plugin worker poll failed",
        lane = $arg.lane, error = getCurrentExceptionMsg()
      break
  waitFor ticker.cancelAndWait()

  ## Hand the (mt) buckets back before the thread dies, so the next worker
  ## generation for this context can take over the registration.
  case arg.lane
  of FastLane:
    PluginRlnStart.clearProvider(ctx)
    PluginRlnStop.clearProvider(ctx)
    PluginRlnGetQuota.clearProvider(ctx)
    PluginRlnValidate.clearProvider(ctx)
  of RegisterLane:
    PluginRlnRegister.clearProvider(ctx)
  of StateLane:
    PluginRlnGetState.clearProvider(ctx)
  of GenerateLane:
    PluginRlnGenerate.clearProvider(ctx)

  info "rln plugin worker stopped", lane = $arg.lane

proc new*(T: type RlnPluginWorkers): RlnPluginWorkers =
  RlnPluginWorkers()

proc stop*(w: RlnPluginWorkers) =
  ## Signals every lane, then joins them. A vtable call already in flight
  ## keeps its thread busy until it returns on its own (bounded by the
  ## timeout_ms the plugin was handed).
  if not w.running:
    return

  for lane in RlnLane:
    w.lanes[lane].shutdown[].store(true)
  for lane in RlnLane:
    joinThread(w.lanes[lane].thread)
    deallocShared(w.lanes[lane].shutdown)
    deallocShared(w.lanes[lane].ready)
    w.lanes[lane].shutdown = nil
    w.lanes[lane].ready = nil
  w.running = false

proc start*(
    w: RlnPluginWorkers, ctx: BrokerContext, plugin: RlnPlugin
): Future[Result[void, string]] {.async: (raises: []).} =
  ## Spawns the four lanes and waits until their (mt) providers are
  ## registered — a request issued before that would find no provider.
  if w.running:
    return ok()

  var spawned: seq[RlnLane]
  for lane in RlnLane:
    w.lanes[lane].shutdown = createShared(Atomic[bool])
    w.lanes[lane].ready = createShared(Atomic[bool])
    w.lanes[lane].shutdown[].store(false)
    w.lanes[lane].ready[].store(false)
    try:
      createThread(
        w.lanes[lane].thread,
        workerMain,
        (
          ctx: ctx,
          plugin: plugin,
          lane: lane,
          shutdown: w.lanes[lane].shutdown,
          ready: w.lanes[lane].ready,
        ),
      )
    except ResourceExhaustedError:
      deallocShared(w.lanes[lane].shutdown)
      deallocShared(w.lanes[lane].ready)
      w.lanes[lane].shutdown = nil
      w.lanes[lane].ready = nil
      for prev in spawned:
        w.lanes[prev].shutdown[].store(true)
        joinThread(w.lanes[prev].thread)
        deallocShared(w.lanes[prev].shutdown)
        deallocShared(w.lanes[prev].ready)
        w.lanes[prev].shutdown = nil
        w.lanes[prev].ready = nil
      return err("could not spawn rln plugin worker thread for lane " & $lane)
    spawned.add(lane)

  w.running = true

  const ReadyTimeout = 100
  for _ in 0 ..< ReadyTimeout:
    var allReady = true
    for lane in RlnLane:
      if not w.lanes[lane].ready[].load():
        allReady = false
        break
    if allReady:
      return ok()
    try:
      await sleepAsync(chronos.milliseconds(20))
    except CancelledError:
      return err("cancelled while starting rln plugin workers")

  err("rln plugin workers did not become ready")

# --- plugin host: the SetRlnPlugin / ClearRlnPlugin providers ---

proc registerRlnPluginHost*(ctx: BrokerContext): Result[void, string] =
  ## Registers the install/clear providers on the calling (node) thread.
  ## Install validates the vtable and spawns the lane workers; clear joins
  ## them. Install is refused while a plugin is running — the previous one
  ## must be cleared first, so a worker's copy of the vtable can never
  ## change underneath it.
  let workers = RlnPluginWorkers.new()

  SetRlnPlugin.setProvider(
    ctx,
    proc(plugin: RlnPlugin): Future[Result[void, string]] {.async.} =
      ?plugin.validate()
      if workers.running:
        return err("rln plugin already installed; clear it first")
      await workers.start(ctx, plugin),
  ).isOkOr:
    return err("Failed to set SetRlnPlugin provider: " & error)

  ClearRlnPlugin.setProvider(
    ctx,
    proc(): Future[Result[void, string]] {.async.} =
      workers.stop()
      return ok(),
  ).isOkOr:
    return err("Failed to set ClearRlnPlugin provider: " & error)

  ok()

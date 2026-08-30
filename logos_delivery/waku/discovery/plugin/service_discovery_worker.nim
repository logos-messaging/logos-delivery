{.push raises: [].}

## The discovery worker thread.
##
## Runs its own chronos loop and hosts the `(mt)` broker providers that call
## the plugin vtable. Every plugin entry point is invoked here — blocking this
## thread for as long as the operation takes — so the node's event loop only
## ever awaits an MT request. Calls are serialized: the providers run one at a
## time on this single thread, so a plugin need not be reentrant.

import std/[json, base64]
import chronos, chronicles, results
import brokers/broker_context
import
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/discovery/plugin/service_discovery_accessor

logScope:
  topics = "waku discovery worker"

## One worker per discovery session, owned by the `ExternalServiceDiscovery`
## that spawns it: `startDiscovery` starts it, `stopDiscovery` joins it.
##
## The vtable travels as the thread argument. It is plain pointers and
## scalars, so it copies onto the worker's stack with nothing shared and
## nothing to guard -- and it cannot change underneath, because registering
## is refused while discovery runs. That is why no lock or lookup appears
## anywhere below.
##
## The stop/ready flags are the one thing both threads touch, so they live in
## shared memory rather than on either thread's heap.

type
  WorkerArg =
    tuple[
      ctx: BrokerContext,
      plugin: ServiceDiscoveryPlugin,
      shutdown: ptr Atomic[bool],
      ready: ptr Atomic[bool],
    ]

  ServiceDiscoveryWorker* = ref object
    ## Held by the backend that spawns it, so a worker belongs to exactly one
    ## node by construction rather than by keying a shared table. A ref both
    ## gives the thread a stable address and lets the async `start` capture it.
    thread: Thread[WorkerArg]
    shutdown: ptr Atomic[bool]
    ready: ptr Atomic[bool]
    running: bool

proc parsePeers(payload: string): Result[seq[DiscoveredPeer], string] =
  ## Parses the plugin's JSON array, shaped like the libp2p module's
  ## extended peer records: {peerId, seqNo, addrs, services:[{id, data}]}
  ## where each service `data` is base64.
  let parsed =
    try:
      parseJson(payload)
    except CatchableError:
      return err("invalid JSON from plugin: " & getCurrentExceptionMsg())

  if parsed.kind != JArray:
    return err("expected a JSON array from plugin, got " & $parsed.kind)

  var peers: seq[DiscoveredPeer]
  for node in parsed:
    if node.kind != JObject:
      continue
    var peer = DiscoveredPeer()
    try:
      if node.hasKey("peerId") and node["peerId"].kind == JString:
        peer.peerId = node["peerId"].getStr()
      if node.hasKey("seqNo") and node["seqNo"].kind == JInt:
        peer.seqNo = uint64(node["seqNo"].getBiggestInt())
      if node.hasKey("addrs") and node["addrs"].kind == JArray:
        for a in node["addrs"]:
          if a.kind == JString:
            peer.addrs.add(a.getStr())
      if node.hasKey("services") and node["services"].kind == JArray:
        for s in node["services"]:
          if s.kind != JObject:
            continue
          var svc = DiscoveredService()
          if s.hasKey("id") and s["id"].kind == JString:
            svc.id = s["id"].getStr()
          if s.hasKey("data") and s["data"].kind == JString:
            svc.data = cast[seq[byte]](base64.decode(s["data"].getStr()))
          peer.services.add(svc)
    except CatchableError:
      debug "skipping malformed peer record", error = getCurrentExceptionMsg()
      continue

    if peer.peerId.len > 0:
      peers.add(peer)

  ok(peers)

proc readErr(errBuf: string, code: cint, op: string): string =
  var msg = ""
  for c in errBuf:
    if c == '\0':
      break
    msg.add(c)
  if msg.len == 0:
    msg = "status " & $code
  "service discovery plugin: " & op & " failed: " & msg

proc takeJson(plugin: ServiceDiscoveryPlugin, outJson: cstring): string =
  ## Copies the plugin-owned JSON, then hands the buffer back.
  if outJson.isNil():
    return "[]"
  result = $outJson
  plugin.freeString(plugin.pluginCtx, outJson)

proc workerMain(arg: WorkerArg) {.thread.} =
  ## Owns a chronos loop for one discovery session; that node's MT brokers
  ## dispatch onto it.
  let ctx = arg.ctx
  ## Our own copy of the vtable, validated by `startDiscovery` before the
  ## thread was spawned and immutable for as long as it lives.
  let plugin = arg.plugin
  setThreadBrokerContext(ctx)

  # reprovide, not provide: a previous worker generation may still hold a
  # registration pointing at a thread that has since been joined.
  # One provider per plugin entry point -- each calls its own vtable slot.

  discard PluginStart.reprovideIt(ctx):
    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.start(plugin.pluginCtx, errBuf.cstring, errBuf.len.csize_t)
    if rc != LdDiscoOk:
      return err(readErr(errBuf, rc, "start"))
    ok()

  discard PluginStop.reprovideIt(ctx):
    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.stop(plugin.pluginCtx, errBuf.cstring, errBuf.len.csize_t)
    if rc != LdDiscoOk:
      return err(readErr(errBuf, rc, "stop"))
    ok()

  discard PluginLookup.reprovideIt(ctx):
    var
      errBuf = newString(LdDiscoErrBufLen)
      outJson: cstring = nil
    let rc = plugin.lookup(
      plugin.pluginCtx,
      key.cstring,
      limit.int64,
      addr outJson,
      errBuf.cstring,
      errBuf.len.csize_t,
    )
    if rc != LdDiscoOk:
      return err(readErr(errBuf, rc, "lookup"))
    parsePeers(plugin.takeJson(outJson))

  discard PluginRandomLookup.reprovideIt(ctx):
    var
      errBuf = newString(LdDiscoErrBufLen)
      outJson: cstring = nil
    let rc = plugin.randomLookup(
      plugin.pluginCtx, addr outJson, errBuf.cstring, errBuf.len.csize_t
    )
    if rc != LdDiscoOk:
      return err(readErr(errBuf, rc, "randomLookup"))
    parsePeers(plugin.takeJson(outJson))

  discard PluginStartAdvertising.reprovideIt(ctx):
    var
      errBuf = newString(LdDiscoErrBufLen)
      dataCopy = data
      recordCopy = record
    let
      dataPtr =
        if dataCopy.len == 0:
          nil
        else:
          cast[ptr UncheckedArray[uint8]](addr dataCopy[0])
      recordPtr =
        if recordCopy.len == 0:
          nil
        else:
          cast[ptr UncheckedArray[uint8]](addr recordCopy[0])
    let rc = plugin.startAdvertising(
      plugin.pluginCtx, key.cstring, dataPtr, dataCopy.len.csize_t, recordPtr,
      recordCopy.len.csize_t, errBuf.cstring, errBuf.len.csize_t,
    )
    if rc != LdDiscoOk:
      return err(readErr(errBuf, rc, "startAdvertising"))
    ok()

  discard PluginStopAdvertising.reprovideIt(ctx):
    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.stopAdvertising(
      plugin.pluginCtx, key.cstring, errBuf.cstring, errBuf.len.csize_t
    )
    if rc != LdDiscoOk:
      return err(readErr(errBuf, rc, "stopAdvertising"))
    ok()

  discard PluginRegisterInterest.reprovideIt(ctx):
    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.registerInterest(
      plugin.pluginCtx, key.cstring, errBuf.cstring, errBuf.len.csize_t
    )
    if rc != LdDiscoOk:
      return err(readErr(errBuf, rc, "registerInterest"))
    ok()

  discard PluginUnregisterInterest.reprovideIt(ctx):
    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.unregisterInterest(
      plugin.pluginCtx, key.cstring, errBuf.cstring, errBuf.len.csize_t
    )
    if rc != LdDiscoOk:
      return err(readErr(errBuf, rc, "unregisterInterest"))
    ok()

  discard PluginAddBootstrapEntries.reprovideIt(ctx):
    if entries.len == 0:
      return ok()
    var
      errBuf = newString(LdDiscoErrBufLen)
      entryCopies = entries
      cstrs = newSeq[cstring](entryCopies.len)
    for i in 0 ..< entryCopies.len:
      cstrs[i] = entryCopies[i].cstring
    let rc = plugin.addBootstrapEntries(
      plugin.pluginCtx,
      cast[ptr UncheckedArray[cstring]](addr cstrs[0]),
      cstrs.len.csize_t,
      errBuf.cstring,
      errBuf.len.csize_t,
    )
    if rc != LdDiscoOk:
      return err(readErr(errBuf, rc, "addBootstrapEntries"))
    ok()

  arg.ready[].store(true)
  info "service discovery worker started", ctx = $ctx

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
      error "discovery worker poll failed", error = getCurrentExceptionMsg()
      break
  waitFor ticker.cancelAndWait()

  ## Hand the (mt) buckets back before the thread dies. Without this the
  ## registry keeps pointing at a thread that has been joined, and the next
  ## worker for this context could never take over.
  PluginStart.clearProvider(ctx)
  PluginStop.clearProvider(ctx)
  PluginLookup.clearProvider(ctx)
  PluginRandomLookup.clearProvider(ctx)
  PluginStartAdvertising.clearProvider(ctx)
  PluginStopAdvertising.clearProvider(ctx)
  PluginRegisterInterest.clearProvider(ctx)
  PluginUnregisterInterest.clearProvider(ctx)
  PluginAddBootstrapEntries.clearProvider(ctx)

  info "service discovery worker stopped", ctx = $ctx

proc new*(T: type ServiceDiscoveryWorker): ServiceDiscoveryWorker =
  ServiceDiscoveryWorker()

proc start*(
    w: ServiceDiscoveryWorker, ctx: BrokerContext, plugin: ServiceDiscoveryPlugin
): Future[Result[void, string]] {.async: (raises: []).} =
  ## Spawns the worker and waits until its (mt) providers are registered — a
  ## request issued before that would find no provider.
  if w.running:
    return ok()

  w.shutdown = createShared(Atomic[bool])
  w.ready = createShared(Atomic[bool])
  w.shutdown[].store(false)
  w.ready[].store(false)

  try:
    createThread(
      w.thread,
      workerMain,
      (ctx: ctx, plugin: plugin, shutdown: w.shutdown, ready: w.ready),
    )
  except ResourceExhaustedError:
    deallocShared(w.shutdown)
    deallocShared(w.ready)
    w.shutdown = nil
    w.ready = nil
    return err("could not spawn service discovery worker thread")

  w.running = true

  const ReadyTimeout = 100
  for _ in 0 ..< ReadyTimeout:
    if w.ready[].load():
      return ok()
    try:
      await sleepAsync(chronos.milliseconds(20))
    except CancelledError:
      return err("cancelled while starting service discovery worker")

  err("service discovery worker did not become ready")

proc stop*(w: ServiceDiscoveryWorker) =
  ## Signals the worker and joins it. A plugin call already in flight keeps
  ## the thread busy until it returns on its own (the module side caps its own
  ## waits, so this is bounded).
  ##
  ## Safe to pair with a later `start` on the same context: the exiting thread
  ## hands its (mt) buckets back, so the next worker registers cleanly rather
  ## than inheriting a registration that points at a joined thread.
  if not w.running:
    return

  w.shutdown[].store(true)
  joinThread(w.thread)

  deallocShared(w.shutdown)
  deallocShared(w.ready)
  w.shutdown = nil
  w.ready = nil
  w.running = false

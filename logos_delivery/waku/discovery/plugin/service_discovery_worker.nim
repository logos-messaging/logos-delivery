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

type WorkerControl = object
  thread: Thread[BrokerContext]
  running: bool

var workerCtl: WorkerControl
var workerShutdown: ptr Atomic[bool]
var workerReady: ptr Atomic[bool]

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

proc pluginOrErr(): Result[ServiceDiscoveryPlugin, string] =
  let plugin = loadPlugin().valueOr:
    return err("service discovery plugin: none installed")
  ?plugin.validate()
  ok(plugin)

proc workerMain(ctx: BrokerContext) {.thread.} =
  ## Owns a chronos loop for the lifetime of the node; the MT brokers
  ## dispatch onto it.
  setThreadBrokerContext(ctx)

  # reprovide, not provide: a previous worker generation may still hold a
  # registration pointing at a thread that has since been joined.
  # One provider per plugin entry point -- each calls its own vtable slot.

  discard PluginStart.reprovideIt(ctx):
    let plugin = ?pluginOrErr()
    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.start(plugin.pluginCtx, errBuf.cstring, errBuf.len.csize_t)
    if rc != LdDiscoOk:
      return err(readErr(errBuf, rc, "start"))
    ok()

  discard PluginStop.reprovideIt(ctx):
    let plugin = ?pluginOrErr()
    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.stop(plugin.pluginCtx, errBuf.cstring, errBuf.len.csize_t)
    if rc != LdDiscoOk:
      return err(readErr(errBuf, rc, "stop"))
    ok()

  discard PluginLookup.reprovideIt(ctx):
    let plugin = ?pluginOrErr()
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
    let plugin = ?pluginOrErr()
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
    let plugin = ?pluginOrErr()
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
    let plugin = ?pluginOrErr()
    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.stopAdvertising(
      plugin.pluginCtx, key.cstring, errBuf.cstring, errBuf.len.csize_t
    )
    if rc != LdDiscoOk:
      return err(readErr(errBuf, rc, "stopAdvertising"))
    ok()

  discard PluginRegisterInterest.reprovideIt(ctx):
    let plugin = ?pluginOrErr()
    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.registerInterest(
      plugin.pluginCtx, key.cstring, errBuf.cstring, errBuf.len.csize_t
    )
    if rc != LdDiscoOk:
      return err(readErr(errBuf, rc, "registerInterest"))
    ok()

  discard PluginUnregisterInterest.reprovideIt(ctx):
    let plugin = ?pluginOrErr()
    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.unregisterInterest(
      plugin.pluginCtx, key.cstring, errBuf.cstring, errBuf.len.csize_t
    )
    if rc != LdDiscoOk:
      return err(readErr(errBuf, rc, "unregisterInterest"))
    ok()

  discard PluginAddBootstrapEntries.reprovideIt(ctx):
    let plugin = ?pluginOrErr()
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

  workerReady[].store(true)
  info "service discovery worker started"

  # A timer keeps the loop from parking forever with no pending work, so the
  # shutdown flag is observed promptly.
  proc tick() {.async: (raises: []).} =
    while not workerShutdown[].load():
      try:
        await sleepAsync(chronos.milliseconds(50))
      except CancelledError:
        return

  let ticker = tick()
  while not workerShutdown[].load():
    try:
      poll()
    except CatchableError:
      error "discovery worker poll failed", error = getCurrentExceptionMsg()
      break
  waitFor ticker.cancelAndWait()

  info "service discovery worker stopped"

proc startWorker*(
    ctx: BrokerContext
): Future[Result[void, string]] {.async: (raises: []).} =
  ## Spawns the discovery worker and waits until its (mt) providers are
  ## registered — a request issued before that would find no provider.
  ## Idempotent.
  if workerCtl.running:
    return ok()

  workerShutdown = createShared(Atomic[bool])
  workerShutdown[].store(false)
  workerReady = createShared(Atomic[bool])
  workerReady[].store(false)

  try:
    createThread(workerCtl.thread, workerMain, ctx)
  except ResourceExhaustedError:
    deallocShared(workerShutdown)
    deallocShared(workerReady)
    workerShutdown = nil
    workerReady = nil
    return err("could not spawn service discovery worker thread")

  workerCtl.running = true

  const ReadyTimeout = 100
  for _ in 0 ..< ReadyTimeout:
    if workerReady[].load():
      return ok()
    try:
      await sleepAsync(chronos.milliseconds(20))
    except CancelledError:
      return err("cancelled while starting service discovery worker")

  err("service discovery worker did not become ready")

proc stopWorker*() =
  ## Process teardown only. Signals the worker and joins it; a plugin call
  ## already in flight keeps the thread busy until it returns on its own (the
  ## module side caps its own waits, so this is bounded). Not called per
  ## start/stop cycle: (mt) dispatch is bound to the registering thread, so a
  ## joined worker cannot be replaced by a new one.
  if not workerCtl.running:
    return
  workerShutdown[].store(true)
  joinThread(workerCtl.thread)
  deallocShared(workerShutdown)
  deallocShared(workerReady)
  workerShutdown = nil
  workerReady = nil
  workerCtl.running = false

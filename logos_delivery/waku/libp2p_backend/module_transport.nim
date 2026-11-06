## Transport to an external libp2p Logos module.
##
## The host application embedding the library over its C ABI installs a
## `Libp2pModulePlugin` (`logosdelivery_libp2p_set_module`). Requests go out
## through its single `call` entry point, named by method and carrying a CBOR
## payload (see `libp2p_iface/module_contract`); each is answered later through
## `logosdelivery_libp2p_response` with the same request id. Events travel the
## other way through `logosdelivery_libp2p_event`.
##
## Host callbacks may complete on a foreign thread, so the crossing only uses a
## `ThreadSignalPtr` and `allocShared` memory, with one `Lock` over the plugin
## table, the in-flight requests and the pending events.
{.push raises: [].}

import std/[locks, tables]
import chronos, chronos/threadsync, chronicles, results
import ../libp2p_iface/module_contract

export module_contract

logScope:
  topics = "waku libp2p module"

type
  Libp2pModuleCallFn* = proc(
    reqId: uint64,
    meth: cstring,
    request: ptr UncheckedArray[byte],
    requestLen: csize_t,
    userData: pointer,
  ) {.cdecl, gcsafe, raises: [].}

  Libp2pModulePlugin* = object
    abiVersion*: uint32
    name*: cstring
      ## the module's name, matched against `libp2pImpl`; borrowed for the install call
    call*: Libp2pModuleCallFn

  ModuleReply* = Result[seq[byte], string]

  ModuleCallFn* = proc(
    meth: string, request: seq[byte]
  ): Future[ModuleReply].Raising([CancelledError]) {.gcsafe, raises: [].}

  ModuleEventHandler* = proc(payload: seq[byte]) {.gcsafe, raises: [].}

  ModuleTransport* = ref object
    ## What the adapters talk to: requests out, events in. Built from the
    ## installed plugin, or from any call function (tests, in-process modules).
    callFn: ModuleCallFn
    handlers: Table[string, seq[ModuleEventHandler]]
    pump: Future[void]

  Pending = object
    reqId: uint64
    signal: ThreadSignalPtr
    ok: bool
    payload: ptr UncheckedArray[byte] # allocShared copy of the host's reply
    payloadLen: int
    completed: bool
    next: ptr Pending

  PendingEvent = object
    name: cstring # allocShared copy
    payload: ptr UncheckedArray[byte]
    payloadLen: int
    next: ptr PendingEvent

const
  RequestTimeout = chronos.seconds(30)
  MaxModuleNameLen = 63

var
  gLock: Lock
  gPlugin: Libp2pModulePlugin
  gUserData: pointer
  gPending: ptr Pending
  gNextReqId: uint64
  gRegistered: bool
  gName: array[MaxModuleNameLen + 1, char] # NUL-terminated copy of the plugin's name
  gEvents: ptr PendingEvent # FIFO: appended at the tail through gEventsTail
  gEventsTail: ptr PendingEvent
  gEventSignal: ThreadSignalPtr

initLock(gLock)

# --- pending requests --------------------------------------------------------

proc newPending(): ptr Pending =
  let p = cast[ptr Pending](allocShared0(sizeof(Pending)))
  p.signal = ThreadSignalPtr.new().valueOr:
    deallocShared(p)
    return nil
  return p

proc linkPending(p: ptr Pending) =
  ## Caller holds gLock.
  p.reqId = gNextReqId
  inc gNextReqId
  p.next = gPending
  gPending = p

proc unlinkPending(target: ptr Pending) =
  ## Caller holds gLock.
  if gPending == target:
    gPending = target.next
    return
  var p = gPending
  while not p.isNil and p.next != target:
    p = p.next
  if not p.isNil:
    p.next = target.next

proc awaitReply(
    p: ptr Pending, timeout: Duration
): Future[ModuleReply] {.async: (raises: [CancelledError]).} =
  defer:
    withLock gLock:
      unlinkPending(p)
    discard p.signal.close()
    if not p.payload.isNil:
      deallocShared(p.payload)
    deallocShared(p)

  if not await p.signal.wait().withTimeout(timeout):
    return err("timeout")
  if not p.completed:
    return err("libp2p module unregistered while awaiting the reply")

  var bytes = newSeq[byte](p.payloadLen)
  if p.payloadLen > 0:
    copyMem(addr bytes[0], p.payload, p.payloadLen)
  if p.ok:
    return ok(bytes)
  return err(cast[string](bytes))

proc callInstalled(
    meth: string, request: seq[byte]
): Future[ModuleReply] {.async: (raises: [CancelledError]).} =
  var cb: Libp2pModuleCallFn
  var ud: pointer
  let pending = newPending()
  if pending.isNil:
    return err("failed to allocate a libp2p module request")
  withLock gLock:
    cb = gPlugin.call
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("libp2p module not installed")
    ud = gUserData
    linkPending(pending)

  # outside the lock: a host that answers synchronously must not deadlock
  cb(
    pending.reqId,
    meth.cstring,
    if request.len > 0:
      cast[ptr UncheckedArray[byte]](unsafeAddr request[0])
    else:
      nil,
    csize_t(request.len),
    ud,
  )
  return await awaitReply(pending, RequestTimeout)

# --- C entry points ----------------------------------------------------------

proc logosdelivery_libp2p_set_module*(
    plugin: ptr Libp2pModulePlugin, userData: pointer
): cint {.exportc, cdecl, dynlib.} =
  ## Installs the module (or clears it with nil, failing every in-flight
  ## request). Returns 0 on success, 2 for an ABI version mismatch.
  withLock gLock:
    if plugin.isNil:
      gPlugin = Libp2pModulePlugin()
      gUserData = nil
      gRegistered = false
      var p = gPending
      while not p.isNil:
        p.completed = false # "module cleared", not a real completion
        discard p.signal.fireSync()
        p = p.next
      return 0
    if plugin.abiVersion != Libp2pModuleAbiVersion:
      return 2
    gPlugin = plugin[]
    gPlugin.name = nil
    gUserData = userData
    gName = default(array[MaxModuleNameLen + 1, char])
    if not plugin.name.isNil:
      for i in 0 ..< min(plugin.name.len, MaxModuleNameLen):
        gName[i] = plugin.name[i]
    gRegistered = true
    return 0

proc libp2pModuleInstalled*(): bool =
  withLock gLock:
    return gRegistered

proc libp2pModuleName*(): string =
  ## The installed module's name; empty when none is installed.
  withLock gLock:
    if not gRegistered:
      return ""
    return $cast[cstring](addr gName[0])

proc logosdelivery_libp2p_response*(
    reqId: uint64, status: cint, payload: ptr UncheckedArray[byte], payloadLen: csize_t
): cint {.exportc, cdecl, dynlib.} =
  ## Answers a request. status 0: `payload` is the CBOR result; otherwise it is
  ## a UTF-8 error message. Thread-safe; the payload is copied before return.
  ## Returns non-zero for an unknown request id (a late answer after timeout).
  withLock gLock:
    var p = gPending
    while not p.isNil and p.reqId != reqId:
      p = p.next
    if p.isNil:
      return 1
    p.ok = status == 0
    p.payloadLen = int(payloadLen)
    if p.payloadLen > 0:
      p.payload = cast[ptr UncheckedArray[byte]](allocShared(p.payloadLen))
      copyMem(p.payload, payload, p.payloadLen)
    p.completed = true
    discard p.signal.fireSync()
    return 0

proc logosdelivery_libp2p_event*(
    name: cstring, payload: ptr UncheckedArray[byte], payloadLen: csize_t
): cint {.exportc, cdecl, dynlib.} =
  ## Delivers an event from the module. Thread-safe; name and payload are
  ## copied before return and handed to the node thread.
  let nameLen = name.len
  let ev = cast[ptr PendingEvent](allocShared0(sizeof(PendingEvent)))
  ev.name = cast[cstring](allocShared0(nameLen + 1))
  copyMem(ev.name, name, nameLen)
  ev.payloadLen = int(payloadLen)
  if ev.payloadLen > 0:
    ev.payload = cast[ptr UncheckedArray[byte]](allocShared(ev.payloadLen))
    copyMem(ev.payload, payload, ev.payloadLen)
  withLock gLock:
    if gEventSignal.isNil:
      deallocShared(ev.name)
      if not ev.payload.isNil:
        deallocShared(ev.payload)
      deallocShared(ev)
      return 1
    if gEventsTail.isNil:
      gEvents = ev
    else:
      gEventsTail.next = ev
    gEventsTail = ev
    discard gEventSignal.fireSync()
  return 0

# --- transport ---------------------------------------------------------------

proc new*(T: type ModuleTransport, callFn: ModuleCallFn): ModuleTransport =
  return ModuleTransport(
    callFn: callFn, handlers: initTable[string, seq[ModuleEventHandler]]()
  )

proc subscribe*(t: ModuleTransport, event: string, handler: ModuleEventHandler) =
  t.handlers.mgetOrPut(event, @[]).add(handler)

proc deliver*(t: ModuleTransport, event: string, payload: seq[byte]) =
  ## Hands an event to its handlers, on the calling thread.
  for handler in t.handlers.getOrDefault(event):
    handler(payload)

proc callRaw*(
    t: ModuleTransport, meth: string, request: seq[byte]
): Future[ModuleReply] {.async: (raises: [CancelledError]).} =
  return await t.callFn(meth, request)

proc call*[Req, Res](
    t: ModuleTransport, meth: string, request: Req, _: typedesc[Res]
): Future[Result[Res, string]] {.async: (raises: [CancelledError]).} =
  ## Sends a typed request and decodes the typed reply.
  let reply = (await t.callFn(meth, cborEncode(request))).valueOr:
    return err(meth & ": " & error)
  let decoded = cborDecode(reply, Res).valueOr:
    return err(meth & ": invalid reply: " & error)
  return ok(decoded)

proc drainEvents(t: ModuleTransport) =
  var head: ptr PendingEvent
  withLock gLock:
    head = gEvents
    gEvents = nil
    gEventsTail = nil
  while not head.isNil:
    let ev = head
    head = ev.next
    var payload = newSeq[byte](ev.payloadLen)
    if ev.payloadLen > 0:
      copyMem(addr payload[0], ev.payload, ev.payloadLen)
      deallocShared(ev.payload)
    t.deliver($ev.name, payload)
    deallocShared(ev.name)
    deallocShared(ev)

proc runEventPump(t: ModuleTransport, signal: ThreadSignalPtr) {.async: (raises: []).} =
  while true:
    try:
      await signal.wait()
    except CancelledError:
      return
    except AsyncError:
      return
    t.drainEvents()

proc installed*(T: type ModuleTransport): Result[ModuleTransport, string] =
  ## The transport to the installed plugin; also starts handing its events to
  ## the handlers on the calling thread's event loop.
  if not libp2pModuleInstalled():
    return err("libp2p module not installed")
  let signal = ThreadSignalPtr.new().valueOr:
    return err("failed to allocate the event signal: " & error)
  withLock gLock:
    gEventSignal = signal
  let t = ModuleTransport.new(callInstalled)
  t.pump = runEventPump(t, signal)
  return ok(t)

proc close*(t: ModuleTransport) {.async: (raises: []).} =
  if not t.pump.isNil:
    await t.pump.cancelAndWait()
    t.pump = nil
  withLock gLock:
    if not gEventSignal.isNil:
      discard gEventSignal.close()
      gEventSignal = nil

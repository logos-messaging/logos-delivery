{.used.}

## Kademlia discovery hosted by a plugin, driven through the real C ABI the
## way the logos-delivery-module hosts it: the driver `dlopen`s `liblogosdelivery`,
## listens for `onServiceDiscoveryRequest` events, and settles each request
## with `logosdelivery_complete_service_discovery_request`.
##
## The event listener runs on the library's event thread. It only copies the
## event into a shared-memory ring and returns; the test thread answers, as a
## host must never block inside the listener.
##
## Requires the shared library. Build it with `make liblogosdelivery`, or
## override its location with LIBLOGOSDELIVERY=<path>. Run:
##   make test tests/ffi/test_ffi_service_discovery.nim

import std/[atomics, dynlib, json, os, strutils]
import testutils/unittests

const
  RetOk = 0
  EventName = "onServiceDiscoveryRequest"

  LibSuffix =
    when defined(macosx):
      ".dylib"
    elif defined(windows):
      ".dll"
    else:
      ".so"

# ── C ABI surface (library/generated/logosdelivery.h) ──────────────────────

type
  CreateNodeReq {.bycopy.} = object
    configJson: cstring

  CompleteReq {.bycopy.} = object
    requestId: uint64
    success: bool
    payload: cstring

  RawFn = proc(ret: cint, msg: ptr cchar, len: csize_t, ud: pointer) {.
    cdecl, gcsafe, raises: []
  .}
  ReplyFn = proc(errCode: cint, reply, errMsg: cstring, ud: pointer) {.
    cdecl, gcsafe, raises: []
  .}

  CreateNodeFn =
    proc(req: ptr CreateNodeReq, cb: ReplyFn, ud: pointer): pointer {.cdecl, gcsafe.}
  CtxFn = proc(ctx: pointer, cb: RawFn, ud: pointer): cint {.cdecl, gcsafe.}
  CompleteFn = proc(ctx: pointer, cb: ReplyFn, ud: pointer, req: ptr CompleteReq): cint {.
    cdecl, gcsafe
  .}
  AddListenerFn =
    proc(ctx: pointer, name: cstring, cb: RawFn, ud: pointer): uint64 {.cdecl, gcsafe.}
  DestroyFn = proc(ctx: pointer): cint {.cdecl, gcsafe.}

  Api = object
    createNode: CreateNodeFn
    startNode, stopNode, requirements: CtxFn
    complete: CompleteFn
    addListener: AddListenerFn
    destroy: DestroyFn

# ── shared-memory landing pads (callbacks run on library threads) ──────────

const
  BufLen = 8192
  RingLen = 256

type
  Slot = object
    done: Atomic[bool]
    ret: Atomic[int]
    len: int
    buf: array[BufLen, char]

  Ring = object ## Single producer (event thread), single consumer (test thread).
    head, tail: Atomic[int]
    lens: array[RingLen, int]
    bufs: array[RingLen, array[BufLen, char]]
    overflow: Atomic[bool]

proc store(s: ptr Slot, ret: int, msg: ptr cchar, len: int) {.gcsafe, raises: [].} =
  let n = min(len, BufLen)
  if n > 0 and not msg.isNil():
    copyMem(addr s.buf[0], msg, n)
  s.len = n
  s.ret.store(ret)
  s.done.store(true)

proc onRaw(
    ret: cint, msg: ptr cchar, len: csize_t, ud: pointer
) {.cdecl, gcsafe, raises: [].} =
  store(cast[ptr Slot](ud), int(ret), msg, int(len))

proc onReply(
    errCode: cint, reply, errMsg: cstring, ud: pointer
) {.cdecl, gcsafe, raises: [].} =
  let text = if errCode == RetOk: reply else: errMsg
  let p =
    if text.isNil():
      nil
    else:
      cast[ptr cchar](text)
  store(cast[ptr Slot](ud), int(errCode), p, if text.isNil(): 0 else: text.len)

proc onEvent(
    ret: cint, msg: ptr cchar, len: csize_t, ud: pointer
) {.cdecl, gcsafe, raises: [].} =
  let ring = cast[ptr Ring](ud)
  let head = ring.head.load()
  if head - ring.tail.load() >= RingLen or int(len) > BufLen:
    ring.overflow.store(true)
    return
  let i = head mod RingLen
  copyMem(addr ring.bufs[i][0], msg, int(len))
  ring.lens[i] = int(len)
  ring.head.store(head + 1)

type Answer = tuple[ret: int, msg: string]

proc answer(s: var Slot): Answer =
  var msg = newString(s.len)
  if s.len > 0:
    copyMem(addr msg[0], addr s.buf[0], s.len)
  return (s.ret.load(), msg)

proc pop(ring: ptr Ring): string =
  let tail = ring.tail.load()
  if tail == ring.head.load():
    return ""
  let i = tail mod RingLen
  var s = newString(ring.lens[i])
  if s.len > 0:
    copyMem(addr s[0], addr ring.bufs[i][0], s.len)
  ring.tail.store(tail + 1)
  return s

proc libPath(): string =
  let fromEnv = getEnv("LIBLOGOSDELIVERY")
  if fromEnv.len > 0:
    return fromEnv
  return getCurrentDir() / "build" / ("liblogosdelivery" & LibSuffix)

proc loadApi(): Api =
  let lib = loadLib(libPath())
  doAssert not lib.isNil(), "cannot load " & libPath()
  template sym(name: string): pointer =
    let p = lib.symAddr(name)
    doAssert not p.isNil(), "missing symbol " & name
    p

  return Api(
    createNode: cast[CreateNodeFn](sym("logosdelivery_create_node")),
    startNode: cast[CtxFn](sym("logosdelivery_start_node")),
    stopNode: cast[CtxFn](sym("logosdelivery_stop_node")),
    requirements: cast[CtxFn](sym("logosdelivery_get_discovery_requirements")),
    complete: cast[CompleteFn](sym("logosdelivery_complete_service_discovery_request")),
    addListener: cast[AddListenerFn](sym("logosdelivery_add_event_listener")),
    destroy: cast[DestroyFn](sym("logosdelivery_destroy")),
  )

# ── the fake host ──────────────────────────────────────────────────────────

type Host = object
  api: Api
  ctx: pointer
  ring: ptr Ring
  requests: seq[JsonNode]

proc complete(host: Host, requestId: uint64, success: bool, payload: string): Answer =
  var slot: Slot
  var req =
    CompleteReq(requestId: requestId, success: success, payload: payload.cstring)
  doAssert host.api.complete(host.ctx, onReply, addr slot, addr req) == RetOk
  while not slot.done.load():
    sleep(5)
  return slot.answer()

proc pump(host: var Host) =
  ## Answers every queued request: lookups find nobody, the rest succeed.
  while true:
    let raw = host.ring.pop()
    if raw.len == 0:
      return
    let req = parseJson(raw)
    host.requests.add(req)
    let verb = req["verb"].getStr()
    let payload = if verb in ["lookup", "randomLookup"]: "[]" else: ""
    let res = host.complete(uint64(req["requestId"].getBiggestInt()), true, payload)
    doAssert res.ret == RetOk, "completion rejected: " & res.msg

proc callPumping(host: var Host, fn: CtxFn, timeout = 60.0): Answer =
  var slot: Slot
  doAssert fn(host.ctx, onRaw, addr slot) == RetOk
  var waited = 0.0
  while not slot.done.load() and waited < timeout:
    host.pump()
    sleep(10)
    waited += 0.01
  doAssert slot.done.load(), "call did not answer"
  host.pump()
  return slot.answer()

proc nodeConfig(): string =
  ## The flat (kernel) shape: the plugin flag is a node flag, not a messaging
  ## override.
  $(
    %*{
      "mode": "Core",
      "log-level": "INFO",
      "tcp-port": 60110,
      "discv5-discovery": false,
      "plugin-kad-discovery": true,
    }
  )

suite "Plugin-hosted kademlia discovery over the C ABI":
  test "a plugin answering events brings the node up and down":
    let api = loadApi()
    let ring = cast[ptr Ring](allocShared0(sizeof(Ring)))
    defer:
      deallocShared(ring)

    var created: Slot
    var createReq = CreateNodeReq(configJson: nodeConfig().cstring)
    let ctx = api.createNode(addr createReq, onReply, addr created)
    require not ctx.isNil()
    while not created.done.load():
      sleep(10)
    check created.answer().ret == RetOk
    var host = Host(api: api, ctx: ctx, ring: ring)

    ## The node tells its host what to set up.
    let reqs = host.callPumping(api.requirements)
    check reqs.ret == RetOk
    let requirements = parseJson(reqs.msg)
    check requirements["pluginKadDiscovery"].getBool()

    check api.addListener(ctx, EventName, onEvent, ring) != 0

    let started = host.callPumping(api.startNode)
    check:
      started.ret == RetOk
      not ring.overflow.load()

    check host.requests.len > 0
    for req in host.requests:
      check:
        req["eventType"].getStr() == "service_discovery_request"
        req["timeoutMs"].getInt() > 0
    check host.requests[0]["verb"].getStr() == "start"

    ## A completion for a request the node is not waiting on is refused.
    let stale = host.complete(uint64.high, true, "")
    check stale.ret != RetOk

    let stopped = host.callPumping(api.stopNode)
    check stopped.ret == RetOk
    check host.requests[^1]["verb"].getStr() == "stop"
    check api.destroy(ctx) == RetOk

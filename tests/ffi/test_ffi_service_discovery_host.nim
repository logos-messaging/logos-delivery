{.used.}

## External service discovery driven through the real C ABI, the way the
## logos-delivery-module hosts it: the driver `dlopen`s `liblogosdelivery`,
## registers an implementation for every `sd_*` reverse call with
## `logosdelivery_set_<wire>_impl`, and answers asynchronously.
##
## The implementations run on the library's reverse worker threads, which
## belong to the library's Nim runtime, not this binary's: they only copy the
## call into shared memory and return. A host thread of this binary answers it
## later with `logosdelivery_reverse_reply`, the async shape the module uses.
##
## Requires the shared library. Build it with:
##   nim c $(tr '\n' ' ' < nimble.paths) --nimMainPrefix:liblogosdelivery \
##     --out:build/liblogosdelivery.dylib --app:lib --noMain --threads:on \
##     --mm:refc --opt:speed --passL:librln_v2.0.2.a --passL:-lm \
##     -d:chronicles_log_level=INFO -d:discv5_protocol_id=d5waku \
##     library/liblogosdelivery.nim
## Override the location with LIBLOGOSDELIVERY=<path>.
##
## Not registered in an aggregate -- it needs the shared library built
## first (see above). Run:
##   make test tests/ffi/test_ffi_service_discovery_host.nim

import std/[atomics, dynlib, json, os, strutils]
import testutils/unittests
import ffi/cbor_serial

const
  RetOk = 0
  RetStaleWarn = 3
  ReverseAccepted = 0
  ReverseInvalidCtx = 1
  EmptyReq = [0xa0'u8] ## a parameterless request: an empty CBOR map
  SdWires = [
    "sd_start", "sd_stop", "sd_lookup", "sd_random_lookup", "sd_start_advertising",
    "sd_stop_advertising", "sd_register_interest", "sd_unregister_interest",
  ]
  LookupWire = 2
  AdvertWire = 4
  FakePeerId = "16Uiu2HAm4gVVMqAzg2gT5cBii3qfaXykUJoB7jyHgAu71RuiELmz"

  LibSuffix =
    when defined(macosx):
      ".dylib"
    elif defined(windows):
      ".dll"
    else:
      ".so"

# ── wire types: mirrors of the library's {.ffi.} types, CBOR-compatible ────

type
  CreateNodeReq = object
    configJson: string

  SdService = object
    id: string
    data: seq[byte]

  SdPeerRecord = object
    peerId: string
    seqNo: uint64
    addrs: seq[string]
    services: seq[SdService]

  SdPeerRecords = object
    peers: seq[SdPeerRecord]

  SdStartAdvertisingArgs = object
    key: string
    data: seq[byte]
    record: seq[byte]

# ── C ABI surface (library/generated/logosdelivery.h) ──────────────────────

type
  FfiCallback = proc(ret: cint, msg: ptr cchar, len: csize_t, ud: pointer) {.
    cdecl, gcsafe, raises: []
  .}
  ReverseImpl = proc(
    ctx: pointer,
    callId: uint64,
    args: ptr UncheckedArray[byte],
    len: csize_t,
    ud: pointer,
  ) {.cdecl, gcsafe, raises: [].}
  ReverseRelease = proc(ud: pointer) {.cdecl, gcsafe, raises: [].}

  CreateNodeFn = proc(
    req: ptr byte, len: csize_t, cb: FfiCallback, ud: pointer
  ): pointer {.cdecl, gcsafe.}
  CtxFn = proc(
    ctx: pointer, cb: FfiCallback, ud: pointer, req: ptr byte, len: csize_t
  ): cint {.cdecl, gcsafe.}
  DestroyFn = proc(ctx: pointer): cint {.cdecl, gcsafe.}
  SetImplFn = proc(
    ctx: pointer, impl: ReverseImpl, ud: pointer, release: ReverseRelease
  ): cint {.cdecl, gcsafe.}
  ReplyFn = proc(
    ctx: pointer, callId: uint64, retCode: cint, reply: ptr byte, len: csize_t
  ): cint {.cdecl, gcsafe, raises: [].}

  Api = object
    createNode: CreateNodeFn
    startNode, stopNode, requirements: CtxFn
    destroy: DestroyFn
    setImpl: array[SdWires.len, SetImplFn]
    reply: ReplyFn

# ── shared memory: library threads write here, never into GC memory ────────

const
  BufLen = 8192
  RingLen = 256

type
  Slot = object
    done: Atomic[bool]
    ret: Atomic[int]
    len: int
    buf: array[BufLen, byte]

  Call = object
    wire: int
    ctx: pointer
    callId: uint64
    len: int
    args: array[BufLen, byte]

  Host = object ## Calls the impls received, in order; the host thread answers them.
    head, answered: Atomic[int]
    calls: array[RingLen, Call]
    holdLookups: Atomic[bool] ## leave lookups unanswered (destroy test)
    heldCtx: Atomic[pointer]
    heldCall: Atomic[uint64]
    lateReplyRc: Atomic[int]
    quit: Atomic[bool]
    overflow: Atomic[bool]
    reply: ReplyFn

var host: ptr Host
var wireIds: array[SdWires.len, int] ## user_data of each impl: its wire index

proc store(s: ptr Slot, ret: int, msg: ptr cchar, len: int) {.gcsafe, raises: [].} =
  let n = min(len, BufLen)
  if n > 0 and not msg.isNil():
    copyMem(addr s.buf[0], msg, n)
  s.len = n
  s.ret.store(ret)
  s.done.store(true)

proc onDone(
    ret: cint, msg: ptr cchar, len: csize_t, ud: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## A long handler (start_node) pings with RET_STALE_WARN first; only the
  ## final reply settles the call.
  if ret == RetStaleWarn:
    return
  store(cast[ptr Slot](ud), int(ret), msg, int(len))

proc impl(
    ctx: pointer,
    callId: uint64,
    args: ptr UncheckedArray[byte],
    len: csize_t,
    ud: pointer,
) {.cdecl, gcsafe, raises: [].} =
  ## Copies the call and returns: the answer comes from the host thread.
  let i = host.head.load()
  if i >= RingLen or int(len) > BufLen:
    host.overflow.store(true)
    return
  host.calls[i].wire = cast[ptr int](ud)[]
  host.calls[i].ctx = ctx
  host.calls[i].callId = callId
  host.calls[i].len = int(len)
  if len > 0:
    copyMem(addr host.calls[i].args[0], args, int(len))
  host.head.store(i + 1)

proc answer(c: Call) {.gcsafe, raises: [].} =
  let rc =
    if c.wire in [LookupWire, LookupWire + 1]:
      let records = SdPeerRecords(
        peers: @[
          SdPeerRecord(
            peerId: FakePeerId,
            seqNo: 7,
            addrs: @["/ip4/1.2.3.4/tcp/60000"],
            services: @[SdService(id: "/logos/delivery", data: @[1'u8])],
          )
        ]
      )
      let bytes =
        try:
          cborEncode(records)
        except CatchableError:
          @[]
      host.reply(c.ctx, c.callId, RetOk, unsafeAddr bytes[0], csize_t(bytes.len))
    else:
      host.reply(c.ctx, c.callId, RetOk, nil, 0) # void reply
  doAssert rc == ReverseAccepted

proc hostThread() {.thread.} =
  while not host.quit.load():
    let next = host.answered.load()
    if next < host.head.load():
      let c = host.calls[next]
      if c.wire == LookupWire and host.holdLookups.load():
        if host.heldCtx.load().isNil():
          host.heldCall.store(c.callId)
          host.heldCtx.store(c.ctx)
      else:
        sleep(5) # well after the impl returned
        answer(c)
      host.answered.store(next + 1)
    else:
      sleep(2)

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

  var api = Api(
    createNode: cast[CreateNodeFn](sym("logosdelivery_create_node")),
    startNode: cast[CtxFn](sym("logosdelivery_start_node")),
    stopNode: cast[CtxFn](sym("logosdelivery_stop_node")),
    requirements: cast[CtxFn](sym("logosdelivery_get_discovery_requirements")),
    destroy: cast[DestroyFn](sym("logosdelivery_destroy")),
    reply: cast[ReplyFn](sym("logosdelivery_reverse_reply")),
  )
  for i, wire in SdWires:
    api.setImpl[i] = cast[SetImplFn](sym("logosdelivery_set_" & wire & "_impl"))
  return api

proc wait(s: var Slot, timeout = 60.0): tuple[ret: int, payload: seq[byte]] =
  var waited = 0.0
  while not s.done.load() and waited < timeout:
    sleep(10)
    waited += 0.01
  doAssert s.done.load(), "call did not answer"
  return (s.ret.load(), s.buf[0 ..< s.len])

proc text(ret: int, payload: seq[byte]): string =
  ## Ok payloads of string replies are CBOR strings; errors are plain UTF-8.
  if ret == RetOk:
    return cborDecode(payload, string).valueOr:
      raiseAssert "reply is not a CBOR string: " & error
  return cast[string](payload)

proc call(api: Api, fn: CtxFn, ctx: pointer): tuple[ret: int, msg: string] =
  var slot: Slot
  doAssert fn(ctx, onDone, addr slot, unsafeAddr EmptyReq[0], csize_t(EmptyReq.len)) ==
    RetOk
  let (ret, payload) = slot.wait()
  return (ret, text(ret, payload))

proc nodeConfig(port: int): string =
  $(
    %*{
      "mode": "Core",
      "messagingOverrides": {
        "log-level": "WARN",
        "local-storage-path": getTempDir() / ("ld-ffi-sd-host-" & $port),
        "tcp-port": port,
        "discv5-discovery": false,
        "plugin-kad-discovery": true,
      },
    }
  )

proc newNode(api: Api, port: int): pointer =
  var created: Slot
  let req = cborEncode(CreateNodeReq(configJson: nodeConfig(port)))
  let ctx = api.createNode(unsafeAddr req[0], csize_t(req.len), onDone, addr created)
  doAssert not ctx.isNil()
  let (ret, payload) = created.wait()
  doAssert ret == RetOk, "create_node failed: " & text(ret, payload)
  return ctx

proc registerAll(api: Api, ctx: pointer) =
  for i in 0 ..< SdWires.len:
    wireIds[i] = i
    doAssert api.setImpl[i](ctx, impl, addr wireIds[i], nil) == ReverseAccepted

proc wiresSeen(): seq[string] =
  for i in 0 ..< host.head.load():
    result.add(SdWires[host.calls[i].wire])

suite "External service discovery host over the C ABI":
  var thread: Thread[void]

  setup:
    host = cast[ptr Host](allocShared0(sizeof(Host)))
    createThread(thread, hostThread)

  teardown:
    host.quit.store(true)
    joinThread(thread)
    deallocShared(host)
    host = nil

  test "the node lists the impls it needs and will not start without them":
    let api = loadApi()
    host.reply = api.reply
    let ctx = api.newNode(60311)

    let reqs = api.call(api.requirements, ctx)
    check reqs.ret == RetOk
    let requirements = parseJson(reqs.msg)
    check:
      requirements["externalServiceDiscovery"].getBool()
      requirements["requiredHostImpls"].to(seq[string]) == @SdWires

    ## All but one registered: start fails and names the missing one.
    for i in 0 ..< SdWires.len:
      wireIds[i] = i
      if i != LookupWire:
        check api.setImpl[i](ctx, impl, addr wireIds[i], nil) == ReverseAccepted
    let started = api.call(api.startNode, ctx)
    check:
      started.ret != RetOk
      "sd_lookup" in started.msg
      host.head.load() == 0 # refused before any host call

    check api.destroy(ctx) == RetOk

  test "an async host brings the node up, is asked to advertise and look up":
    let api = loadApi()
    host.reply = api.reply
    let ctx = api.newNode(60312)
    api.registerAll(ctx)

    let started = api.call(api.startNode, ctx)
    check started.ret == RetOk
    check not host.overflow.load()

    ## The announce loop and the eager lookup run after start returns.
    var waited = 0
    while waited < 10_000 and
        not ("sd_lookup" in wiresSeen() and "sd_start_advertising" in wiresSeen()):
      sleep(20)
      waited += 20
    let seen = wiresSeen()
    check:
      seen[0] == "sd_start"
      "sd_register_interest" in seen
      "sd_start_advertising" in seen
      "sd_lookup" in seen

    ## The advert carries this node's signed record for the service.
    for i in 0 ..< host.head.load():
      if host.calls[i].wire == AdvertWire:
        let c = host.calls[i]
        let args = cborDecode(c.args[0 ..< c.len], SdStartAdvertisingArgs).valueOr:
          raiseAssert "advert args: " & error
        check:
          args.key.startsWith("service:")
          args.record.len > 0

    let stopped = api.call(api.stopNode, ctx)
    check stopped.ret == RetOk
    check "sd_stop" in wiresSeen()
    check api.destroy(ctx) == RetOk

  test "destroy while a host call is out; the late reply is refused":
    let api = loadApi()
    host.reply = api.reply
    host.holdLookups.store(true)
    let ctx = api.newNode(60313)
    api.registerAll(ctx)

    check api.call(api.startNode, ctx).ret == RetOk
    var waited = 0
    while waited < 10_000 and host.heldCtx.load().isNil():
      sleep(20)
      waited += 20
    require not host.heldCtx.load().isNil()

    ## The parked lookup fails with the node; the token outlives the context.
    check api.destroy(ctx) == RetOk
    let late = SdPeerRecords()
    let bytes = cborEncode(late)
    check api.reply(
      host.heldCtx.load(),
      host.heldCall.load(),
      RetOk,
      unsafeAddr bytes[0],
      csize_t(bytes.len),
    ) == ReverseInvalidCtx

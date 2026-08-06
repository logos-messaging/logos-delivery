{.used.}

## FFI-level regression guard for the former persistency singleton's
## thread/lifetime mismatch, driven through the real C ABI: the driver
## `dlopen`s `liblogosdelivery` and calls the exported `logosdelivery_*`
## entry points, exactly as a module host does.
##
## Historically `Persistency` was a process-global (`gPersistency`) whose
## memory belonged to the FFI thread that first initialised it; with two
## contexts alive the second one adopted the first one's instance and read
## a foreign heap. Persistency is now owned per node (`Waku.persistency`,
## resolved via the context-scoped `GetPersistency` broker), so every case
## below must pass:
##
##   case stop-steals-persistence
##     ctx1 stop_node closes only ctx1's own persistency; ctx2 must keep
##     its SDS persistence working.
##
##   case destroy-without-stop
##     destroying ctx1 without stop must not corrupt ctx2's persistency.
##     Historically a UB probe (stale global into a released heap ->
##     SIGSEGV on Linux, zombie singleton on macOS/arm64); kept as a guard.
##     The destroy-without-stop teardown gap itself is tracked separately
##     (issue #4108).
##
##   case different-storage-paths
##     two contexts with different local-storage-paths must both start;
##     the former singleton refused the second rootDir.
##
## Each case runs in a child process (the second one can fault) with its
## output captured to a file, so a crash is an exit code rather than a dead
## test binary.
##
## Requires the shared library. Build it with:
##   nim c $(tr '\n' ' ' < nimble.paths) --nimMainPrefix:liblogosdelivery \
##     --out:build/liblogosdelivery.dylib --app:lib --noMain --threads:on \
##     --mm:refc --opt:speed --passL:librln_v2.0.2.a --passL:-lm \
##     -d:chronicles_log_level=INFO library/liblogosdelivery.nim
## On Linux add `--passL:-Wl,-Bsymbolic` (as the repo's own Linux target
## does) so the driver's Nim runtime does not interpose the library's.
## Override the location with LIBLOGOSDELIVERY=<path>.
##
## Not registered in an aggregate -- it needs the shared library built
## first (see above). Run:
##   make test tests/ffi/test_ffi_persistency_lifecycle.nim

import std/[atomics, dynlib, json, os, osproc, strutils]
import testutils/unittests

const
  RetOk = 0

  CaseStopSteals = "--case-stop-steals-persistence"
  CaseDestroyOnly = "--case-destroy-without-stop"
  CaseTwoPaths = "--case-different-storage-paths"

  DisabledMarker = "SDS persistence disabled"
    ## Logged by `sdsPersistence()` when the singleton is unusable.

  ContentTopic = "/lm-repro/1/channel/proto"
  SenderId = "repro-sender"

  LibSuffix =
    when defined(macosx):
      ".dylib"
    elif defined(windows):
      ".dll"
    else:
      ".so"

# ── C ABI surface ───────────────────────────────────────────────────────

type
  FfiCallback = proc(callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.
    cdecl, gcsafe, raises: []
  .}

  CreateNodeFn = proc(configJson: cstring, cb: FfiCallback, userData: pointer): pointer {.
    cdecl, gcsafe
  .}
  CtxFn = proc(ctx: pointer, cb: FfiCallback, userData: pointer): cint {.cdecl, gcsafe.}
  ChannelCreateFn = proc(
    ctx: pointer,
    cb: FfiCallback,
    userData: pointer,
    channelId, contentTopic, senderId: cstring,
  ): cint {.cdecl, gcsafe.}
  ChannelExistsFn = proc(
    ctx: pointer, cb: FfiCallback, userData: pointer, channelId: cstring
  ): cint {.cdecl, gcsafe.}

  Api = object
    createNode: CreateNodeFn
    startNode: CtxFn
    stopNode: CtxFn
    destroy: CtxFn
    channelCreate: ChannelCreateFn
    channelExists: ChannelExistsFn

  Slot = object
    ## Shared-memory callback landing pad. The callback fires on the
    ## library's FFI thread, so nothing GC'd may cross it.
    done: Atomic[int]
    ret: Atomic[int]
    len: Atomic[int]
    buf: array[2048, char]

proc libPath(): string =
  let fromEnv = getEnv("LIBLOGOSDELIVERY")
  if fromEnv.len > 0:
    return fromEnv
  return getCurrentDir() / "build" / ("liblogosdelivery" & LibSuffix)

proc onDone(
    callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let s = cast[ptr Slot](userData)
  if s.isNil():
    return
  var n = int(len)
  if n > s.buf.len - 1:
    n = s.buf.len - 1
  if n > 0 and not msg.isNil():
    copyMem(addr s.buf[0], msg, n)
  s.buf[n] = '\0'
  s.len.store(n)
  s.ret.store(int(callerRet))
  s.done.store(1)

proc armSlot(s: ptr Slot) =
  s.done.store(0)
  s.ret.store(-1)
  s.len.store(0)

proc awaitSlot(
    s: ptr Slot, timeoutMs = 60_000
): tuple[ok: bool, ret: int, msg: string] =
  ## `msg` is returned raw. It is CBOR, not a bare string: a channel id
  ## "before" arrives as 0x66 'b' 'e' 'f' 'o' 'r' 'e' (major type 3, len 6),
  ## which prints as "fbefore". Only `ret` is used for assertions here.
  var waited = 0
  while s.done.load() == 0 and waited < timeoutMs:
    sleep(10)
    waited += 10
  if s.done.load() == 0:
    return (false, -1, "timeout after " & $timeoutMs & "ms")
  let n = s.len.load()
  var m = newString(n)
  if n > 0:
    copyMem(addr m[0], addr s.buf[0], n)
  return (true, s.ret.load(), m)

proc need(lib: LibHandle, name: string): pointer =
  let p = lib.symAddr(name)
  if p.isNil():
    quit("missing symbol " & name & " in " & libPath(), 2)
  return p

proc loadApi(): Api =
  let lib = loadLib(libPath())
  if lib.isNil():
    quit("cannot load " & libPath(), 2)

  Api(
    createNode: cast[CreateNodeFn](lib.need("logosdelivery_create_node")),
    startNode: cast[CtxFn](lib.need("logosdelivery_start_node")),
    stopNode: cast[CtxFn](lib.need("logosdelivery_stop_node")),
    destroy: cast[CtxFn](lib.need("logosdelivery_destroy")),
    channelCreate: cast[ChannelCreateFn](lib.need("logosdelivery_channel_create")),
    channelExists: cast[ChannelExistsFn](lib.need("logosdelivery_channel_exists")),
  )

# ── driver helpers ──────────────────────────────────────────────────────

var failed = false

proc note(step: string, r: tuple[ok: bool, ret: int, msg: string]) =
  echo "  [", step, "] ok=", r.ok, " ret=", r.ret, " msg=", r.msg

proc expectOk(step: string, r: tuple[ok: bool, ret: int, msg: string]) =
  note(step, r)
  if not r.ok or r.ret != RetOk:
    echo "  FAIL: ", step, " expected RET_OK"
    failed = true

proc nodeConfig(storagePath: string, tcpPort, discv5Port: int): string =
  $(
    %*{
      "mode": "Core",
      "preset": "logos.dev",
      "messagingOverrides": {
        "log-level": "INFO",
        "local-storage-path": storagePath,
        "tcp-port": $tcpPort,
        "discv5-udp-port": $discv5Port,
      },
    }
  )

proc createCtx(
    api: Api, s: ptr Slot, label, storagePath: string, tcpPort, discv5Port: int
): pointer =
  armSlot(s)
  let ctx =
    api.createNode(nodeConfig(storagePath, tcpPort, discv5Port).cstring, onDone, s)
  if ctx.isNil():
    echo "  FAIL: ", label, " create_node returned nil"
    failed = true
    return nil
  expectOk(label & " create_node", awaitSlot(s))
  return ctx

proc call(api: Api, s: ptr Slot, label: string, fn: CtxFn, ctx: pointer) =
  armSlot(s)
  discard fn(ctx, onDone, s)
  expectOk(label, awaitSlot(s))

proc createChannel(api: Api, s: ptr Slot, label: string, ctx: pointer, id: string) =
  armSlot(s)
  discard api.channelCreate(
    ctx, onDone, s, id.cstring, ContentTopic.cstring, SenderId.cstring
  )
  expectOk(label, awaitSlot(s))

proc churn(api: Api, s: ptr Slot, ctx: pointer, rounds = 500) =
  ## Allocate and release on the *target context's* FFI thread without
  ## touching persistency (`channel_exists` is a manager-table lookup), so
  ## the pages released by the other context's thread get recycled before
  ## the stale singleton is dereferenced. tests/persistency/test_thread_affinity
  ## shows this is what turns a dormant stale ref into an observable one.
  for i in 0 ..< rounds:
    armSlot(s)
    let id = "churn-" & $i & repeat("x", 64)
    discard api.channelExists(ctx, onDone, s, id.cstring)
    discard awaitSlot(s, 5_000)

proc caseRoot(name: string): string =
  getTempDir() / ("ffi_persistency_repro_" & name)

# ── cases ───────────────────────────────────────────────────────────────

proc runStopSteals(api: Api, s: ptr Slot) =
  ## ctx1 and ctx2 share one storage path. Stopping ctx1 runs
  ## Persistency.reset(), which closes ctx2's jobs and nils the global.
  let root = caseRoot("shared")
  let ctx1 = createCtx(api, s, "ctx1", root, 60010, 60011)
  let ctx2 = createCtx(api, s, "ctx2", root, 60020, 60021)
  if failed:
    return

  api.call(s, "ctx1 start_node", api.startNode, ctx1)
  api.call(s, "ctx2 start_node", api.startNode, ctx2)
  api.createChannel(s, "ctx2 channel_create (before ctx1 stop)", ctx2, "before")

  api.call(s, "ctx1 stop_node", api.stopNode, ctx1)
  api.call(s, "ctx1 destroy", api.destroy, ctx1)

  api.createChannel(s, "ctx2 channel_create (after ctx1 stop)", ctx2, "after")

  api.call(s, "ctx2 stop_node", api.stopNode, ctx2)
  api.call(s, "ctx2 destroy", api.destroy, ctx2)

proc runDestroyOnly(api: Api, s: ptr Slot) =
  ## Same, but ctx1 is destroyed without stop_node -- reset() never runs, so
  ## the global keeps pointing into ctx1's released FFI-thread heap.
  let root = caseRoot("shared")
  let ctx1 = createCtx(api, s, "ctx1", root, 60030, 60031)
  let ctx2 = createCtx(api, s, "ctx2", root, 60040, 60041)
  if failed:
    return

  api.call(s, "ctx1 start_node", api.startNode, ctx1)
  api.call(s, "ctx2 start_node", api.startNode, ctx2)

  ## The dying context owns the singleton *and* the sds Job; ctx2 only
  ## reaches for them afterwards, so its first persistency touch is already
  ## against released memory.
  api.createChannel(s, "ctx1 channel_create (opens the sds job)", ctx1, "owned-by-ctx1")

  api.call(s, "ctx1 destroy (no stop_node)", api.destroy, ctx1)

  api.churn(s, ctx2)
  api.createChannel(s, "ctx2 channel_create (after ctx1 destroy)", ctx2, "after")

  api.call(s, "ctx2 stop_node", api.stopNode, ctx2)
  api.call(s, "ctx2 destroy", api.destroy, ctx2)

proc runTwoPaths(api: Api, s: ptr Slot) =
  ## Two contexts, two storage paths. The singleton refuses to be re-targeted,
  ## so the second node cannot start at all.
  let rootA = caseRoot("path_a")
  let rootB = caseRoot("path_b")
  let ctx1 = createCtx(api, s, "ctx1", rootA, 60050, 60051)
  let ctx2 = createCtx(api, s, "ctx2", rootB, 60060, 60061)
  if failed:
    return

  api.call(s, "ctx1 start_node", api.startNode, ctx1)
  api.call(s, "ctx2 start_node (different local-storage-path)", api.startNode, ctx2)

  api.call(s, "ctx1 stop_node", api.stopNode, ctx1)
  api.call(s, "ctx1 destroy", api.destroy, ctx1)
  api.call(s, "ctx2 destroy", api.destroy, ctx2)

proc runChild(which: string) =
  let api = loadApi()
  let s = createShared(Slot)

  case which
  of CaseStopSteals:
    runStopSteals(api, s)
  of CaseDestroyOnly:
    runDestroyOnly(api, s)
  of CaseTwoPaths:
    runTwoPaths(api, s)
  else:
    quit("unknown case " & which, 2)

  quit(if failed: 1 else: 0)

if paramCount() >= 1 and paramStr(1).startsWith("--case-"):
  runChild(paramStr(1))

# ── parent ──────────────────────────────────────────────────────────────

proc runCase(flag: string): tuple[code: int, output: string] =
  let logFile = getTempDir() / ("ffi_persistency_repro" & flag & ".log")
  discard tryRemoveFile(logFile)
  let cmd =
    quoteShell(getAppFilename()) & " " & flag & " > " & quoteShell(logFile) & " 2>&1"

  let child = startProcess("/bin/sh", args = @["-c", cmd], options = {})
  let code = child.waitForExit(timeout = 300_000)
  child.close()

  let output =
    try:
      readFile(logFile)
    except IOError:
      ""
  discard tryRemoveFile(logFile)
  return (code, output)

proc report(flag: string, r: tuple[code: int, output: string]) =
  echo "--- ", flag, " (exit ", r.code, ") ---"
  for line in r.output.splitLines():
    if line.contains("[ctx") or line.contains("FAIL:") or line.contains(DisabledMarker):
      echo line

suite "FFI - persistency lifecycle across library contexts":
  test "stopping one context must not disable persistence in the other":
    if not fileExists(libPath()):
      echo "skipped: no ", libPath()
      skip()
    else:
      removeDir(caseRoot("shared"))
      let r = runCase(CaseStopSteals)
      report(CaseStopSteals, r)
      removeDir(caseRoot("shared"))

      check r.code == 0
      check not r.output.contains(DisabledMarker)

  test "destroying one context must not corrupt the other's persistency":
    if not fileExists(libPath()):
      echo "skipped: no ", libPath()
      skip()
    else:
      removeDir(caseRoot("shared"))
      let r = runCase(CaseDestroyOnly)
      report(CaseDestroyOnly, r)
      removeDir(caseRoot("shared"))

      check r.code == 0
      check not r.output.contains(DisabledMarker)

  test "two contexts with different storage paths must both start":
    if not fileExists(libPath()):
      echo "skipped: no ", libPath()
      skip()
    else:
      removeDir(caseRoot("path_a"))
      removeDir(caseRoot("path_b"))
      let r = runCase(CaseTwoPaths)
      report(CaseTwoPaths, r)
      removeDir(caseRoot("path_a"))
      removeDir(caseRoot("path_b"))

      check r.code == 0

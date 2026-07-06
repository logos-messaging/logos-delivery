## Internal per-job storage thread.
##
## Exposes two operations to ``persistency.nim``:
##   * ``startStorageThread(ctx, dbPath)`` — spawn one worker, block until
##     it signals ready (or error). Returns a ``JobRuntime``.
##   * ``stopStorageThread(rt)`` — signal shutdown, join, free.
##
## The worker:
##   1. installs the supplied BrokerContext on its threadvar
##   2. opens the SQLite backend (creating the file + schema if absent)
##   3. registers the PersistEvent listener and the 5 RequestBroker
##      providers under that context
##   4. runs the chronos event loop until shutdown is signalled
##   5. clears providers + listeners, closes the backend
##
## The arg struct lives in shared memory (``allocShared0``). The dbPath is
## carried as a shared cstring buffer rather than a Nim string to avoid
## refc ref-count traffic across threads. The arg is freed by
## ``stopStorageThread`` after ``joinThread`` returns.

import std/[options, os]
import std/atomics # std/concurrency/atomics is the same module in Nim 2.2
import chronos, chronicles, results
import brokers/[event_broker, request_broker, broker_context]
import ./[types, backend_comm, backend_sqlite]

export broker_context, backend_comm

logScope:
  topics = "persistency thread"

type
  ReadyState {.pure.} = enum
    Pending = 0
    Ready = 1
    Error = 2

  StorageThreadArg = object
    ctx: BrokerContext
    dbPath: cstring ## allocShared0'd; freed in closeJob
    dbPathLen: int ## bytes including the trailing NUL
    shutdownFlag: Atomic[int]
    readyFlag: Atomic[int] ## values from ReadyState
    errBuf: array[256, char] ## last error message, NUL-terminated

  StorageThread = Thread[ptr StorageThreadArg]

# ── arg helpers ─────────────────────────────────────────────────────────

proc allocArg(ctx: BrokerContext, dbPath: string): ptr StorageThreadArg =
  let arg = cast[ptr StorageThreadArg](allocShared0(sizeof(StorageThreadArg)))
  arg.ctx = ctx
  arg.dbPathLen = dbPath.len + 1
  arg.dbPath = cast[cstring](allocShared0(arg.dbPathLen))
  if dbPath.len > 0:
    copyMem(arg.dbPath, unsafeAddr dbPath[0], dbPath.len)
  return arg

proc freeArg(a: ptr StorageThreadArg) =
  if a.isNil():
    return
  if a.dbPath != nil:
    deallocShared(a.dbPath)
  deallocShared(a)

proc recordErr(a: ptr StorageThreadArg, msg: string) =
  let n = min(msg.len, a.errBuf.len - 1)
  for i in 0 ..< n:
    a.errBuf[i] = msg[i]
  a.errBuf[n] = '\0'
  a.readyFlag.store(int(ReadyState.Error), moRelease)

proc errMsg(a: ptr StorageThreadArg): string =
  $cast[cstring](a.errBuf[0].addr)

# ── provider closures ───────────────────────────────────────────────────

proc encode(e: PersistencyError): string =
  encodeErr(e)

template unwrapErr(r: untyped): string =
  ## Disambiguates Result's `error` accessor from chronicles' `error` macro
  ## by binding through an explicitly-typed local before stringifying.
  block:
    let pe: PersistencyError = r.error()
    encode(pe)

proc registerProviders(backend: KvBackend, ctx: BrokerContext): Result[void, string] =
  ## Wires the 5 RequestBroker providers + the PersistEvent listener.
  ## All closures capture `backend` by reference (it lives for the entire
  ## thread lifetime).

  proc onGet(category: string, key: Key): Future[Result[KvGet, string]] {.async.} =
    let r = backend.getOne(category, key)
    if r.isErr:
      return err(unwrapErr(r))
    return ok(KvGet(value: r.get()))

  proc onExists(
      category: string, key: Key
  ): Future[Result[KvExists, string]] {.async.} =
    let r = backend.existsOne(category, key)
    if r.isErr:
      return err(unwrapErr(r))
    return ok(KvExists(value: r.get()))

  proc onScan(
      category: string, range: KeyRange, reverse: bool
  ): Future[Result[KvScan, string]] {.async.} =
    let r = backend.scanRange(category, range, reverse)
    if r.isErr:
      return err(unwrapErr(r))
    return ok(KvScan(rows: r.get()))

  proc onCount(
      category: string, range: KeyRange
  ): Future[Result[KvCount, string]] {.async.} =
    let r = backend.countRange(category, range)
    if r.isErr:
      return err(unwrapErr(r))
    return ok(KvCount(n: r.get()))

  proc onDelete(
      category: string, key: Key
  ): Future[Result[KvDelete, string]] {.async.} =
    let r = backend.deleteOne(category, key)
    if r.isErr:
      return err(unwrapErr(r))
    return ok(KvDelete(existed: r.get()))

  # PersistEvent listener — fire-and-forget; we log on backend failure
  # because the caller has no return channel.
  proc onPersist(ev: PersistEvent): Future[void] {.async: (raises: []).} =
    let r = backend.applyOps(ev.ops)
    if r.isErr:
      let pe: PersistencyError = r.error()
      error "PersistEvent applyOps failed",
        error = pe.msg, kind = $pe.kind, opCount = ev.ops.len

  KvGet.setProvider(ctx, onGet).isOkOr:
    return err("KvGet.setProvider: " & error)

  let existsRes = KvExists.setProvider(ctx, onExists)
  if existsRes.isErr:
    return err("KvExists.setProvider: " & existsRes.error())

  let scanRes = KvScan.setProvider(ctx, onScan)
  if scanRes.isErr:
    return err("KvScan.setProvider: " & scanRes.error())

  let countRes = KvCount.setProvider(ctx, onCount)
  if countRes.isErr:
    return err("KvCount.setProvider: " & countRes.error())

  let delRes = KvDelete.setProvider(ctx, onDelete)
  if delRes.isErr:
    return err("KvDelete.setProvider: " & delRes.error())

  let listenRes = PersistEvent.listen(ctx, onPersist)
  if listenRes.isErr:
    return err("PersistEvent.listen: " & listenRes.error())

  return ok()

proc clearProviders(ctx: BrokerContext) {.async.} =
  KvGet.clearProvider(ctx)
  KvExists.clearProvider(ctx)
  KvScan.clearProvider(ctx)
  KvCount.clearProvider(ctx)
  KvDelete.clearProvider(ctx)
  await PersistEvent.dropAllListeners(ctx)

# ── thread proc ─────────────────────────────────────────────────────────

proc storageThreadMain(arg: ptr StorageThreadArg) {.thread.} =
  ## Worker thread entrypoint. Errors during setup are surfaced via
  ## arg.errBuf + readyFlag=ReadyState.Error; the spawning thread checks both.

  setThreadBrokerContext(arg.ctx)

  let path = $arg.dbPath

  let backendRes =
    try:
      openBackend(path)
    except CatchableError as e:
      arg.recordErr("openBackend raised: " & e.msg)
      return
  if backendRes.isErr:
    arg.recordErr("openBackend: " & backendRes.error.msg)
    return
  let backend = backendRes.get()

  let regRes =
    try:
      registerProviders(backend, arg.ctx)
    except CatchableError as e:
      backend.close()
      arg.recordErr("registerProviders raised: " & e.msg)
      return
  if regRes.isErr:
    backend.close()
    arg.recordErr(regRes.error)
    return

  arg.readyFlag.store(int(ReadyState.Ready), moRelease)

  proc awaitShutdown() {.async.} =
    while arg.shutdownFlag.load(moAcquire) != 1:
      try:
        await sleepAsync(milliseconds(10))
      except CatchableError:
        discard

  try:
    waitFor awaitShutdown()
  except CatchableError as e:
    error "storage thread loop crashed", err = e.msg

  waitFor clearProviders(arg.ctx)
  backend.close()

# ── lifecycle ───────────────────────────────────────────────────────────

type JobRuntime* = ref object
  ## Opaque per-job runtime owned by `persistency.nim`. Holds the typed
  ## Thread handle + shared arg pointer so closeJob can shut the worker
  ## down. Created by `startStorageThread` and torn down by
  ## `stopStorageThread`.
  arg*: ptr StorageThreadArg
  thread*: StorageThread

proc startStorageThread*(
    ctx: BrokerContext, dbPath: string
): Result[JobRuntime, PersistencyError] =
  ## Spawn a storage worker for one job. Blocks until the worker either
  ## signals ready (returns the runtime) or signals error (joins, frees,
  ## returns peBackend with the worker's error message).
  let arg = allocArg(ctx, dbPath)
  arg.shutdownFlag.store(0, moRelease)
  arg.readyFlag.store(int(ReadyState.Pending), moRelease)

  var rt = JobRuntime(arg: arg)
  try:
    createThread(rt.thread, storageThreadMain, arg)
  except ResourceExhaustedError as e:
    freeArg(arg)
    return err(persistencyErr(peBackend, "createThread: " & e.msg))

  # Spin-wait for ready or error. The thread does its setup synchronously
  # before signaling, so this is bounded by SQLite open time.
  while true:
    let s = arg.readyFlag.load(moAcquire)
    if s == int(ReadyState.Ready):
      return ok(rt)
    if s == int(ReadyState.Error):
      let msg = errMsg(arg)
      joinThread(rt.thread)
      freeArg(arg)
      return err(persistencyErr(peBackend, msg))
    sleep(1)

proc stopStorageThread*(rt: JobRuntime) =
  ## Signal shutdown, join the worker, free the shared arg. Idempotent in
  ## the sense that it tolerates a nil arg (already stopped).
  if rt == nil or rt.arg == nil:
    return
  rt.arg.shutdownFlag.store(1, moRelease)
  joinThread(rt.thread)
  freeArg(rt.arg)
  rt.arg = nil

## FFIContext type plus lifecycle (init / signal-stop / join / destroy).

{.passc: "-fPIC".}

import std/[atomics, locks, options, sequtils, tables]
import chronicles, chronos, results
import ./ffi_config
when singleThreaded:
  # chronos/threadsync is a {.fatal.} under --threads:off, and so is
  # system.Thread. ffi_singlethread supplies API-compatible no-ops so the
  # lifecycle code below compiles unchanged. See ffi_config.nim.
  import ./ffi_singlethread
else:
  import chronos/threadsync
import
  ./ffi_types,
  ./ffi_events,
  ./ffi_handles,
  ./ffi_thread_request,
  ./ffi_request_queue,
  ./logging,
  ./cbor_serial

export ffi_events, ffi_handles

type CtxLifecycle* {.pure.} = enum
  ## State machine guarding a pooled FFI context (Atomic on FFIContext).
  ##   Active         -> RecyclePending   when the ffiDtor requests recycle
  ##   RecyclePending -> Recycling        FFI loop claimed it, draining handlers
  ##   Recycling      -> Active           createFFIContext reuses the slot
  Active
  RecyclePending
  Recycling

type FFIContext*[T] = object
  myLib*: ptr T # main library object (Waku, LibP2P, SDS, …)
  myLibRefd*: bool
    # refc only: true once myLib[] (a ref) has been GC_ref'd to root it against
    # the cycle collector. Balanced by GC_unref in freeLib.
  myLibOwned*: bool
    # true once a ctor stored a createShared'd lib into myLib (vs the worker's
    # stack fallback). freeLib only frees/destroys owned libs.
  inUse*: Atomic[bool]
    # Whether this pooled context is claimed. The recycle handler clears it on
    # the FFI thread so the slot returns to the pool without recreating threads.
  lifecycle*: Atomic[CtxLifecycle]
  recycleDoneSignal: ThreadSignalPtr
    # fired by the recycle handler once the lib is freed, just before it releases
    # the slot; the synchronous recycleFFIContext caller waits on it.
  libReady*: Atomic[bool]
    # False until a {.ffiCtor.} stores the library. Before that, `myLib` points
    # at the default fallback of the FFI thread. For a `ref` type that fallback
    # is nil.
  ffiThread: Thread[(ptr FFIContext[T])]
  eventThread: Thread[(ptr FFIContext[T])]
  reqQueueBank: RequestQueueBank
  reqSignal: ThreadSignalPtr
  stopSignal: ThreadSignalPtr
  threadExitSignal: ThreadSignalPtr
  eventQueueSignal: ThreadSignalPtr
  eventThreadExitSignal: ThreadSignalPtr
  userData*: pointer
  eventRegistry*: FFIEventRegistry
  handles*: FFIHandleRegistry
  eventQueue*: EventQueue
  ffiHeartbeat*: Atomic[int64]
  eventQueueStuck*: Atomic[bool]
  ffiThreadExited*: Atomic[bool]
    # set once FFI thread (incl. async {.ffiDtor.}) is done; event thread drains until then
  running: Atomic[bool]
  registeredRequests: ptr Table[cstring, FFIRequestProc]
  staleWarnInterval*: Duration

var onFFIThread* {.threadvar.}: bool

const git_version* {.strdefine.} = "n/a"

const RecycleTimeoutMs* {.intdefine: "ffiRecycleTimeoutMs".} = 1500
  ## Bounds one drain round of the recycle handler. The handler runs at most two
  ## rounds: it waits for the in-flight handlers, then cancels them and waits
  ## again. Override with `-d:ffiRecycleTimeoutMs=<ms>`.
const RecycleTimeout* = RecycleTimeoutMs.milliseconds

const
  RecycleWaitTimeout* = 2 * RecycleTimeout + 2.seconds
    ## Caller-side bound for synchronous recycle. It covers both drain rounds
    ## plus slack, so it only fires when the worker itself is wedged.
  EventThreadTickInterval* = 1.seconds
  FFIHeartbeatStartDelay* = 10.seconds
  FFIHeartbeatStaleThreshold* = 1.seconds

const StaleWarnIntervalMs* {.intdefine: "ffiStaleWarnIntervalMs".} = 5000
  ## `RET_STALE_WARN` cadence; handlers are never timed out.
const StaleWarnInterval* = StaleWarnIntervalMs.milliseconds

type FFITeardownProc*[T] = proc(lib: ptr T): Future[void] {.async.}

proc ffiTeardownHook*[T](): var FFITeardownProc[T] =
  ## Per-library teardown slot (one `{.global.}` per `T`), awaited by the FFI thread before exit.
  ## Runtime slot not an overload: an overload would bind the no-op default before the dtor is visible.
  var hook {.global.}: FFITeardownProc[T]
  hook

include ./event_thread
include ./ffi_thread

template closeAndNil(field: untyped) =
  if not field.isNil():
    ?field.close()
    field = nil

proc deinitContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Mirror of `initContextResources`. Threads MUST be joined first; fields nil'd after close.
  deinitRequestQueue(ctx[].reqQueueBank)
  deinitEventRegistry(ctx[].eventRegistry)
  deinitHandleRegistry(ctx[].handles)
  deinitEventQueue(ctx[].eventQueue)
  when defined(gcRefc):
    # ThreadSignalPtr.close() under refc hangs via signal-handler re-entry; the
    # recycle pool makes full destroy rare, so the leaked fd stays bounded.
    discard
  else:
    closeAndNil(ctx.reqSignal)
    closeAndNil(ctx.stopSignal)
    closeAndNil(ctx.threadExitSignal)
    closeAndNil(ctx.eventQueueSignal)
    closeAndNil(ctx.eventThreadExitSignal)
    closeAndNil(ctx.recycleDoneSignal)
  ok()

template newSignalOrErr(field: untyped, name: string) =
  field = ThreadSignalPtr.new().valueOr:
    return err("couldn't create ThreadSignalPtr: " & name & ": " & $error)

proc initContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## On failure, deferred cleanup closes partial state; caller releases the slot.
  # Nil first so deferred cleanup can't double-close a reused pool slot.
  ctx.reqSignal = nil
  ctx.stopSignal = nil
  ctx.threadExitSignal = nil
  ctx.eventQueueSignal = nil
  ctx.eventThreadExitSignal = nil
  ctx.recycleDoneSignal = nil
  ctx.myLibOwned = false
  ctx.myLibRefd = false
  ctx.lifecycle.store(CtxLifecycle.Active)
  initRequestQueue(ctx[].reqQueueBank)
  initEventRegistry(ctx[].eventRegistry)
  initHandleRegistry(ctx[].handles)
  initEventQueue(ctx[].eventQueue)
  ctx.ffiHeartbeat.store(0)
  ctx.libReady.store(false)
  ctx.eventQueueStuck.store(false)
  ctx.ffiThreadExited.store(false)
  ctx.staleWarnInterval = StaleWarnInterval

  var success = false
  defer:
    if not success:
      # `ctx` is a pool slot the caller owns; close what was opened, never free it.
      ctx.deinitContextResources().isOkOr:
        error "failed to clean up resources after createFFIContext failure",
          error = error

  newSignalOrErr(ctx.reqSignal, "reqSignal")
  newSignalOrErr(ctx.stopSignal, "stopSignal")
  newSignalOrErr(ctx.threadExitSignal, "threadExitSignal")
  newSignalOrErr(ctx.eventQueueSignal, "eventQueueSignal")
  newSignalOrErr(ctx.eventThreadExitSignal, "eventThreadExitSignal")
  newSignalOrErr(ctx.recycleDoneSignal, "recycleDoneSignal")

  ctx.registeredRequests = addr ffi_types.registeredRequests

  ctx.running.store(true)

  try:
    createThread(ctx.ffiThread, ffiThreadBody[T], ctx)
  except ValueError, ResourceExhaustedError:
    return err("failed to create the FFI thread: " & getCurrentExceptionMsg())

  try:
    createThread(ctx.eventThread, eventThreadBody[T], ctx)
  except ValueError, ResourceExhaustedError:
    # Join ffiThread before deferred cleanup closes signals it's waiting on.
    ctx.running.store(false)
    let fireRes = ctx.reqSignal.fireSync()
    if fireRes.isErr():
      error "failed to signal ffiThread during event-thread cleanup",
        error = fireRes.error
    joinThread(ctx.ffiThread)
    return err("failed to create the event thread: " & getCurrentExceptionMsg())

  success = true
  ok()

proc fireOrErr(sig: ThreadSignalPtr, name: string): Result[void, string] =
  let fired = sig.fireSync().valueOr:
    return err("error signaling: " & name & ": " & $error)
  if not fired:
    return err("failed to signal: " & name & " on time")
  ok()

proc waitExitOrErr(
    sig: ThreadSignalPtr, name: string, timeout: Duration
): Result[void, string] =
  let exited = sig.waitSync(timeout).valueOr:
    return err("error waiting for exit: " & name & ": " & $error)
  if not exited:
    return err("did not exit in time: " & name & " (leaking ctx to avoid hang)")
  ok()

proc signalStop*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  # Skip onNotResponding on error: it takes reg.lock a stuck listener may hold (deadlock risk).
  ctx.running.store(false)
  ?ctx.reqSignal.fireOrErr("reqSignal")
  ?ctx.stopSignal.fireOrErr("stopSignal")
  ctx.eventQueueSignal.fireOrErr("eventQueueSignal").isOkOr:
    error "failed to signal eventQueueSignal in signalStop", error = error
  ok()

proc tryClaim*[T](ctx: ptr FFIContext[T]): bool =
  ## Atomically claim a free pooled context (false -> true).
  var expected = false
  ctx.inUse.compareExchange(expected, true)

proc releaseClaim*[T](ctx: ptr FFIContext[T]) =
  ctx.inUse.store(false)

proc isInUse*[T](ctx: ptr FFIContext[T]): bool =
  ctx.inUse.load()

proc markAsActive*[T](ctx: ptr FFIContext[T]) =
  ## Reused context: its worker threads are still alive; re-arm for requests.
  ctx.lifecycle.store(CtxLifecycle.Active)

proc requestRecycle*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Ask the FFI thread to drain, free the lib and release the slot, WITHOUT
  ## stopping its worker/event threads, so the next createFFIContext reuses them.
  ## Synchronous: waits on recycleDoneSignal. No fd churn -> no select() limit.
  var expected = CtxLifecycle.Active
  if not ctx.lifecycle.compareExchange(expected, CtxLifecycle.RecyclePending):
    return err("requestRecycle: context is not Active (already recycling)")

  # A recycle that timed out can fire late. The CAS makes this the only recycle
  # in flight, so drop that stale fire before the wait below can answer to it.
  discard ctx.recycleDoneSignal.waitSync(ZeroDuration)

  let fired = ctx.reqSignal.fireSync().valueOr:
    return err("requestRecycle: failed to signal the FFI thread: " & $error)
  if not fired:
    return err("requestRecycle: failed to signal the FFI thread in time")

  let done = ctx.recycleDoneSignal.waitSync(RecycleWaitTimeout).valueOr:
    return err("requestRecycle: failed waiting for recycle: " & $error)
  if not done:
    return err("requestRecycle: recycle did not complete in time")
  ok()

## Per-thread exit wait before stopAndJoinThreads leaks ctx rather than hanging; async
## `{.ffiDtor.}` teardown can outlast the default. Override `-d:ffiThreadExitTimeoutMs=<ms>`.
const ThreadExitTimeoutMs* {.intdefine: "ffiThreadExitTimeoutMs".} = 1500
const ThreadExitTimeout* = ThreadExitTimeoutMs.milliseconds

proc stopAndJoinThreads*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## On timeout, returns err and skips remaining joins (leaves threads live); caller cleans up.
  ctx.signalStop().isOkOr:
    return err("signalStop failed: " & $error)

  ?ctx.threadExitSignal.waitExitOrErr("FFI thread", ThreadExitTimeout)
  joinThread(ctx.ffiThread)
  ?ctx.eventThreadExitSignal.waitExitOrErr("event thread", ThreadExitTimeout)
  joinThread(ctx.eventThread)
  ok()

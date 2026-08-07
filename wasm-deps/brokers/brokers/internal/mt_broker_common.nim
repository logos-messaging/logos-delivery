## Multi-Thread Broker Common
## --------------------------
## Shared runtime helpers used by both mt_request_broker and mt_event_broker.
## These are not generated — they are used directly by generated code.

{.push raises: [].}

import chronos, chronos/threadsync
import std/atomics
import std/[os, locks] # `sleep`; `Lock` for the API listener-installer registry
import results
import ../broker_context
import ./mt_queue
export chronos, threadsync, atomics

# ---------------------------------------------------------------------------
# reduced-A: per-classCtx event-listener installer registry.
#
# An EventBroker(API) event only reaches the foreign event courier if the
# library's `installAllListeners` has been called for the *emitting* ctx. The
# main library ctx is handled at createContext, but a SUB-INSTANCE (created via
# a create-instance request, sharing the library classCtx with a distinct
# instanceCtx) needs its listeners installed too. registerBrokerLibrary records
# its installer keyed by classCtx here; the create-instance adapter calls
# `installApiListenersForCtx(subCtx)` on the processing thread.
#
# Storage is a fixed POD array (the installer is a bare `nimcall` function
# pointer, the key a uint16) so it is safe to share across threads under both
# --mm:refc and --mm:orc — no GC'd container crosses the thread boundary.
# ---------------------------------------------------------------------------

const maxApiCtxInstallers* = 64

type ApiCtxListenerInstaller* =
  proc(ctx: BrokerContext): Result[void, string] {.nimcall.}

var gApiCtxInstallers:
  array[maxApiCtxInstallers, tuple[classCtx: uint16, fn: ApiCtxListenerInstaller]]
var gApiCtxInstallerCount: int
var gApiCtxInstallerLock: Lock
var gApiCtxInstallerLockInit: Atomic[int]

proc ensureApiCtxInstallerLock() {.gcsafe.} =
  var expected = 0
  if gApiCtxInstallerLockInit.compareExchange(expected, 1, moAcquire, moRelaxed):
    {.cast(gcsafe).}:
      initLock(gApiCtxInstallerLock)
    gApiCtxInstallerLockInit.store(2, moRelease)
  else:
    while gApiCtxInstallerLockInit.load(moAcquire) != 2:
      sleep(0)

proc registerApiCtxListenerInstaller*(
    classCtx: uint16, fn: ApiCtxListenerInstaller
) {.gcsafe.} =
  ## Record (or replace) the listener installer for a library, keyed by its
  ## classCtx. Called once per `createContext`.
  ensureApiCtxInstallerLock()
  {.cast(gcsafe).}:
    withLock gApiCtxInstallerLock:
      for i in 0 ..< gApiCtxInstallerCount:
        if gApiCtxInstallers[i].classCtx == classCtx:
          gApiCtxInstallers[i].fn = fn
          return
      if gApiCtxInstallerCount < maxApiCtxInstallers:
        gApiCtxInstallers[gApiCtxInstallerCount] = (classCtx, fn)
        inc gApiCtxInstallerCount

proc installApiListenersForCtx*(ctx: BrokerContext) {.gcsafe.} =
  ## Install the owning library's event-courier listeners for a sub-instance
  ## ctx (looked up by classCtx). Best-effort: if no installer is registered
  ## (e.g. a library with no events) or it fails, the sub-instance simply has no
  ## event delivery. Runs on the processing thread.
  ensureApiCtxInstallerLock()
  var fn: ApiCtxListenerInstaller = nil
  let cc = classCtx(ctx)
  {.cast(gcsafe).}:
    withLock gApiCtxInstallerLock:
      for i in 0 ..< gApiCtxInstallerCount:
        if gApiCtxInstallers[i].classCtx == cc:
          fn = gApiCtxInstallers[i].fn
          break
  if not fn.isNil:
    try:
      {.cast(gcsafe).}:
        discard fn(ctx)
    except Exception:
      discard

# ---------------------------------------------------------------------------
# Thread identity
# ---------------------------------------------------------------------------

var mtThreadIdMarker* {.threadvar.}: bool
  ## Each thread gets its own copy; `addr mtThreadIdMarker` is a unique thread id.

template currentMtThreadId*(): pointer =
  addr mtThreadIdMarker

# ---------------------------------------------------------------------------
# Thread generation — monotonically increasing, unique per thread incarnation.
# Under refc, threadvar addresses can be reused when threads exit and new
# ones are created. The generation counter disambiguates reused addresses.
# ---------------------------------------------------------------------------

var gMtThreadGenCounter: Atomic[uint64]

var mtThreadGen* {.threadvar.}: uint64
var mtThreadGenInitialized {.threadvar.}: bool

proc currentMtThreadGen*(): uint64 =
  if not mtThreadGenInitialized:
    mtThreadGen = gMtThreadGenCounter.fetchAdd(1, moRelaxed)
    mtThreadGenInitialized = true
  mtThreadGen

# ---------------------------------------------------------------------------
# Blocking await for {.thread.} procs
# ---------------------------------------------------------------------------

template blockingAwait*[T](f: Future[T]): T =
  ## Blocking await for use inside non-async `{.thread.}` procs.
  ## Use this instead of `await` (which conflicts with chronos's async-only
  ## `await`) or call `waitFor` directly.
  waitFor(f)

# ---------------------------------------------------------------------------
# Per-thread shared signal + dispatcher
# ---------------------------------------------------------------------------
# Instead of one ThreadSignalPtr (2 fds on macOS, 1 on Linux) per broker
# type per thread, every broker type on the same thread shares a single
# ThreadSignalPtr.  Fd count drops from O(broker_types × threads) to
# O(threads).
#
# Each broker type registers a poll proc (ThreadDispatchPollFn).  The
# shared brokerDispatchLoop coroutine fires whenever ANY channel on this
# thread has a new message, then drains all registered poll procs.
# Poll proc return values:
#   0  — nothing to process; keep registered
#   1  — message processed; keep registered
#   2  — done (shutdown or one-shot complete); remove from dispatcher
# ---------------------------------------------------------------------------

type ThreadDispatchPollFn* = proc(): int {.gcsafe, raises: [].}

var gBrokerThreadSignal* {.threadvar.}: ThreadSignalPtr
var gBrokerThreadPollers* {.threadvar.}: seq[ThreadDispatchPollFn]
var gBrokerDispatchStarted* {.threadvar.}: bool
var gBrokerDispatchStopRequested* {.threadvar.}: bool
  ## Set by stopBrokerDispatchHere() to ask the loop to exit on its next
  ## drain pass. Used by FFI entry points so that transient foreign threads
  ## (e.g. the C++ caller of <lib>_request_*/<lib>_shutdown) don't accumulate
  ## a persistent suspended coroutine and its associated chronos/GC state
  ## across calls. The flag is cleared by stopBrokerDispatchHere() after the
  ## loop confirms exit.

proc getOrInitBrokerSignal*(): ThreadSignalPtr =
  ## Get (or lazily create) the per-thread signal shared by all broker types.
  if gBrokerThreadSignal.isNil:
    let res = ThreadSignalPtr.new()
    if res.isErr():
      raiseAssert "BrokerDispatcher: failed to create thread signal: " & res.error
    gBrokerThreadSignal = res.get()
  gBrokerThreadSignal

proc fireBrokerSignal*(signal: ThreadSignalPtr) {.gcsafe, raises: [].} =
  ## Wake the target thread's broker dispatcher. Safe to call from any thread.
  discard signal.fireSync()

proc registerBrokerPoller*(fn: ThreadDispatchPollFn) =
  ## Register a poll function with this thread's dispatcher.
  ## Must be called from the owning thread.
  gBrokerThreadPollers.add(fn)

proc brokerDispatchLoop*(signal: ThreadSignalPtr) {.async: (raises: []).} =
  ## Single dispatch loop per chronos thread.  Drains all registered broker
  ## channel pollers whenever the shared signal fires.
  while true:
    # Drain: keep polling until every channel is empty.
    var anyWork = true
    while anyWork:
      anyWork = false
      var i = 0
      while i < gBrokerThreadPollers.len:
        let r = gBrokerThreadPollers[i]()
        case r
        of 2:
          # Poller is done — remove it.
          gBrokerThreadPollers.del(i)
        of 1:
          anyWork = true
          inc i
        else:
          inc i
    # FFI-caller teardown hook: an external caller (stopBrokerDispatchHere)
    # asked the loop to exit. Drain pass is complete, exit cleanly.
    if gBrokerDispatchStopRequested:
      break
    # Wait for next signal.
    let waitRes = catch:
      await signal.wait()
    if waitRes.isErr():
      break
    if gBrokerDispatchStopRequested:
      break
  # Dispatcher is exiting (e.g. thread shutting down).  Close the per-thread
  # signal so its OS handle (eventfd on Linux, pipe pair on macOS) is reclaimed
  # instead of leaking on every createContext/processing-thread cycle.  Reset
  # the threadvar state so a future ensureBrokerDispatchStarted() on a reused
  # threadvar address (refc) starts fresh.
  let sig = gBrokerThreadSignal
  gBrokerThreadSignal = nil
  gBrokerDispatchStarted = false
  if not sig.isNil:
    let closeRes = sig.close()
    if closeRes.isErr():
      discard

# ---------------------------------------------------------------------------
# Pending-ring-free registry — synchronous deferred cleanup at thread exit
# ---------------------------------------------------------------------------
# When clearProvider(ctx) closes a request broker's ring on the provider
# thread, the corresponding poll fn (registered via brokerDispatchLoop's
# pollers seq) detects `ring.isClosed()` on its next iteration and needs to
# free the shared-memory (ring, slab, pool) triple — but only after a grace
# window long enough for any cross-thread sender that snapshotted those
# pointers under the previous globalLock state to finish its enqueue.
#
# Previous design: `asyncSpawn deferredFreeReqRing(...)` — start an async
# proc that does `await sleepAsync(50ms)` then frees. Two problems:
#
#   1. Allocating the sleepAsync Future inside an asyncSpawn started during
#      `cleanupAllRequestsIdent` runs the refc allocator at a moment where
#      the thread's gch state is fragile from teardown churn. Observed as a
#      hard SEGV in rawAlloc on Linux refc + ASAN (PR #13).
#
#   2. drainAsyncOps only polls chronos for 1ms — the 50ms sleepAsync would
#      never fire before the processing thread exits, so the buffers either
#      leak or are freed by an orphaned coroutine racing thread teardown.
#
# Current design: the poll fn instead records the triple in a thread-local
# seq; the processing-thread proc drains the seq AFTER drainAsyncOps via a
# single synchronous `sleep(50)` followed by direct free calls. No chronos
# involvement in the cleanup path; the grace window applies once for the
# whole ctx instead of once per broker.
type PendingRingFree* = object
  ring*: ptr VyukovMpscRing[uint32]
  slab*: ptr PayloadSlab
  pool*: ptr ResponseSlotPool

var gPendingRingFrees* {.threadvar.}: seq[PendingRingFree]

proc enqueuePendingRingFree*(
    ring: ptr VyukovMpscRing[uint32], slab: ptr PayloadSlab, pool: ptr ResponseSlotPool
) {.gcsafe.} =
  ## Called from a broker poll fn on the provider thread when its ring has
  ## been closed by clearProvider(). The (ring, slab, pool) triple will be
  ## freed by `drainPendingRingFrees()` at thread shutdown.
  {.cast(gcsafe).}:
    gPendingRingFrees.add(PendingRingFree(ring: ring, slab: slab, pool: pool))

proc drainPendingRingFrees*() {.gcsafe.} =
  ## Drain the per-thread pending-ring-free registry synchronously.
  ## Sleeps once for a 50ms grace window covering all queued frees, then
  ## releases each (ring, slab, pool) triple. Must be called from the owning
  ## thread AFTER any chronos work that may still touch the buffers has
  ## completed (i.e. after `drainAsyncOps` in the processing-thread proc).
  if gPendingRingFrees.len == 0:
    return
  # Single grace window: 50ms is enough for any sender that snapshotted
  # pool/slab/ring pointers before clearProvider closed the ring to either
  # complete its enqueue (which then fails on isClosed()) or abort. Without
  # this, a stale sender deref'ing the about-to-be-freed slab/pool crashes.
  sleep(50)
  for entry in gPendingRingFrees:
    if not entry.ring.isNil:
      freeVyukovMpscRing(entry.ring)
    if not entry.slab.isNil:
      deinitPayloadSlab(entry.slab[])
      deallocShared(entry.slab)
    if not entry.pool.isNil:
      deinitResponseSlotPool(entry.pool[])
      deallocShared(entry.pool)
  gPendingRingFrees.setLen(0)

proc ensureBrokerDispatchStarted*() =
  ## Start the per-thread dispatch loop if not already running.
  ## Must be called from within a chronos async context.
  if not gBrokerDispatchStarted:
    gBrokerDispatchStarted = true
    asyncSpawn brokerDispatchLoop(getOrInitBrokerSignal())

proc stopBrokerDispatchHere*() =
  ## Tear down the per-thread brokerDispatchLoop on the calling thread.
  ##
  ## Intended for **FFI entry points** (procs exported with `cdecl, dynlib`
  ## that run on a foreign caller's thread). The dispatch loop was designed
  ## for chronos-loop-owning threads (processing/delivery threads), which
  ## are torn down via joinThread. An FFI caller's thread instead lives for
  ## the entire process and re-enters Nim per call; without teardown its
  ## suspended `await signal.wait()` future, registered pollers seq, and
  ## chronos pending-callback list accumulate across calls and eventually
  ## drag the thread's refc ZCT/heap into corruption (PR #13).
  ##
  ## Safe to call from sync context (after `waitFor` returns). No-op if the
  ## loop was never started on this thread. Drives chronos via an internal
  ## `waitFor` until the loop's coroutine actually exits.
  if not gBrokerDispatchStarted:
    return
  gBrokerDispatchStopRequested = true
  let sig = gBrokerThreadSignal
  if not sig.isNil:
    discard sig.fireSync()

  proc awaitLoopExit() {.async: (raises: []).} =
    let deadline = Moment.now() + chronos.seconds(2)
    while gBrokerDispatchStarted and Moment.now() < deadline:
      let sleepRes = catch:
        await sleepAsync(milliseconds(1))
      if sleepRes.isErr():
        break

  waitFor awaitLoopExit()
  gBrokerDispatchStopRequested = false

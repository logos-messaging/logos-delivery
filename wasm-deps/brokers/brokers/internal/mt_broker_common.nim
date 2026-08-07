## Multi-Thread Broker Common
## --------------------------
## Shared runtime helpers used by both mt_request_broker and mt_event_broker.
## These are not generated — they are used directly by generated code.

{.push raises: [].}

import chronos, chronos/threadsync
when not defined(windows):
  import chronos/selectors2 # `close2` on the per-thread dispatcher's Selector
else:
  # IOCP HANDLE close: forward-declare CloseHandle inline rather than
  # importing `chronos/osdefs`. Pulling osdefs into this module's compile
  # unit destabilises Windows + Nim 2.2.4 + --mm:refc + -d:release builds
  # (test/test_multi_thread_request_broker silently crashes on createThread
  # in that combination; ORC + same Nim + same matrix is fine, as is every
  # other Nim version refc + release). Declaring just the proc we need
  # keeps the symbol surface of this module unchanged from the pre-PR shape.
  proc closeHandle(
    h: pointer
  ): int32 {.stdcall, dynlib: "kernel32", importc: "CloseHandle", sideEffect.}

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

# ---------------------------------------------------------------------------
# BrokerSignalShared — type-stable, close-safe wrapper around ThreadSignalPtr
# ---------------------------------------------------------------------------
# Raw ThreadSignalPtr pointers stored in shared buckets / request messages
# can outlive the owning thread: a provider's clearProvider fires the
# providerSignal after bucket removal, sendReply fires the requesterSignal of
# a requester that may have timed out and exited, and emit snapshots fire
# listener signals concurrently with listener-thread teardown. Firing a
# closed-and-freed ThreadSignalPtr is a stray write() to a possibly-reused fd
# on POSIX and feeds Windows handle recycling into the RegisterWaitForSingle-
# Object thread-pool callback path (the win+refc 0xC0000005 crash).
#
# The wrapper makes cross-thread firing safe:
#   - `state` packs a closed bit (bit 63) + an in-flight-firer count.
#   - fireBrokerSignal CAS-acquires a firer slot (fails fast if closed),
#     fires, then releases the slot.
#   - The owner's close sets the closed bit, waits out in-flight firers,
#     closes the inner ThreadSignalPtr, and RECYCLES the wrapper onto a
#     process-global freelist instead of freeing it. Wrapper memory is
#     therefore type-stable for the process lifetime: a stale pointer held
#     by another thread either observes the closed bit (no-op) or fires a
#     recycled wrapper's new signal (a spurious, harmless dispatcher wake).
#
# Works identically under --mm:refc and --mm:orc on all platforms: the
# wrapper lives in allocShared memory and holds no GC'd data.

const
  bssClosedBit = 1'u64 shl 63
  bssFirerMask = bssClosedBit - 1

type BrokerSignalShared* = object
  state: Atomic[uint64] # bit 63 = closed; low bits = in-flight firer count
  signal: ThreadSignalPtr
  next: ptr BrokerSignalShared # intrusive freelist link (guarded by gBssLock)

var gBssLock: Atomic[bool]
var gBssFreeHead: ptr BrokerSignalShared

proc newBrokerSignalShared(): ptr BrokerSignalShared {.gcsafe, raises: [].} =
  ## Pop a recycled wrapper (or allocate a fresh one) and arm it with a new
  ## ThreadSignalPtr. The open state is published with release ordering AFTER
  ## the new signal is installed, so a stale firer that wins the CAS always
  ## sees a valid signal.
  var w: ptr BrokerSignalShared = nil
  while gBssLock.exchange(true, moAcquire):
    cpuRelax()
  {.cast(gcsafe).}:
    w = gBssFreeHead
    if not w.isNil:
      gBssFreeHead = w.next
  gBssLock.store(false, moRelease)
  if w.isNil:
    w = cast[ptr BrokerSignalShared](allocShared0(sizeof(BrokerSignalShared)))
  let res = ThreadSignalPtr.new()
  if res.isErr():
    raiseAssert "BrokerDispatcher: failed to create thread signal: " & res.error
  w.signal = res.get()
  w.next = nil
  w.state.store(0, moRelease)
  w

proc closeBrokerSignalShared(s: ptr BrokerSignalShared) {.gcsafe, raises: [].} =
  ## Owner-side close: refuse new firers, wait out in-flight ones, close the
  ## inner ThreadSignalPtr and recycle the wrapper. The closed bit stays set
  ## while the wrapper sits on the freelist.
  if s.isNil:
    return
  discard s.state.fetchOr(bssClosedBit, moAcquireRelease)
  while (s.state.load(moAcquire) and bssFirerMask) != 0'u64:
    cpuRelax()
  let sig = s.signal
  s.signal = nil
  if not sig.isNil:
    let closeRes = sig.close()
    if closeRes.isErr():
      discard
  while gBssLock.exchange(true, moAcquire):
    cpuRelax()
  {.cast(gcsafe).}:
    s.next = gBssFreeHead
    gBssFreeHead = s
  gBssLock.store(false, moRelease)

var gBrokerThreadSignal* {.threadvar.}: ptr BrokerSignalShared
var gBrokerThreadPollers* {.threadvar.}: seq[ThreadDispatchPollFn]
var gBrokerDispatchStarted* {.threadvar.}: bool
var gBrokerDispatchStopRequested* {.threadvar.}: bool
  ## Set by stopBrokerDispatchHere() to ask the loop to exit on its next
  ## drain pass. Used by FFI entry points so that transient foreign threads
  ## (e.g. the C++ caller of <lib>_request_*/<lib>_shutdown) don't accumulate
  ## a persistent suspended coroutine and its associated chronos/GC state
  ## across calls. The flag is cleared by stopBrokerDispatchHere() after the
  ## loop confirms exit.

proc getOrInitBrokerSignal*(): ptr BrokerSignalShared =
  ## Get (or lazily create) the per-thread signal shared by all broker types.
  if gBrokerThreadSignal.isNil:
    gBrokerThreadSignal = newBrokerSignalShared()
  gBrokerThreadSignal

proc fireBrokerSignal*(signal: ptr BrokerSignalShared) {.gcsafe, raises: [].} =
  ## Wake the target thread's broker dispatcher. Safe to call from any thread
  ## at any time — including after the owning thread has closed the signal
  ## and exited (no-op) or after the wrapper has been recycled to a new
  ## thread (spurious wake, harmless).
  if signal.isNil:
    return
  var cur = signal.state.load(moAcquire)
  while true:
    if (cur and bssClosedBit) != 0'u64:
      return
    if signal.state.compareExchange(cur, cur + 1'u64, moAcquire, moAcquire):
      break
  discard signal.signal.fireSync()
  discard signal.state.fetchSub(1'u64, moRelease)

proc registerBrokerPoller*(fn: ThreadDispatchPollFn) =
  ## Register a poll function with this thread's dispatcher.
  ## Must be called from the owning thread.
  gBrokerThreadPollers.add(fn)

proc brokerDispatchLoop*(signal: ptr BrokerSignalShared) {.async: (raises: []).} =
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
    # Wait for next signal. Waiting on the inner ThreadSignalPtr is owner-only
    # and the owner never closes it while the loop runs, so this is safe.
    let waitRes = catch:
      await signal.signal.wait()
    if waitRes.isErr():
      break
    if gBrokerDispatchStopRequested:
      break
  # Dispatcher is exiting (e.g. thread shutting down).  Close the per-thread
  # signal so its OS handle (eventfd on Linux, pipe pair on macOS, event on
  # Windows) is reclaimed instead of leaking on every createContext/
  # processing-thread cycle. closeBrokerSignalShared waits out concurrent
  # firers before closing, and recycles the wrapper (type-stable memory), so
  # stale bucket/message pointers to it stay safe to fire through. Reset the
  # threadvar state so a future ensureBrokerDispatchStarted() on a reused
  # threadvar address (refc) starts fresh.
  #
  # NOTE for --mm:refc on Windows: exiting this loop is what dismantles the
  # pending `signal.wait()` — and with it the Win32 RegisterWaitForSingleObject
  # registration whose thread-pool callback dereferences a GC-heap
  # PostCallbackData. The loop MUST therefore be stopped (teardownBrokerThread/
  # stopBrokerDispatchHere) before the thread returns, i.e. before refc frees
  # the whole thread heap via deallocOsPages().
  let sig = gBrokerThreadSignal
  gBrokerThreadSignal = nil
  gBrokerDispatchStarted = false
  closeBrokerSignalShared(sig)

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

var gBrokerThreadTeardownDone {.threadvar.}: bool
var gBrokerThreadHookRegistered {.threadvar.}: bool

proc teardownBrokerThread*() {.gcsafe, raises: [].}

proc ensureBrokerDispatchStarted*() =
  ## Start the per-thread dispatch loop if not already running.
  ## Must be called from within a chronos async context.
  ##
  ## The first call on a Nim-created thread also registers an
  ## `onThreadDestruction` hook running `teardownBrokerThread()`. The hook
  ## fires in the thread wrapper's `finally` — BEFORE refc's
  ## `deallocOsPages()` frees the thread heap — so existing user code gets
  ## the ordered teardown automatically. Foreign threads (created outside
  ## Nim, e.g. FFI callers) never run Nim's destruction handlers and must
  ## call `teardownBrokerThread()` explicitly before their final return
  ## into foreign code.
  if not gBrokerDispatchStarted:
    gBrokerDispatchStarted = true
    # Broker use (re)starts on this thread: re-arm the teardown latch so the
    # destruction hook (or a later explicit call) tears down this incarnation
    # of the dispatch state too.
    gBrokerThreadTeardownDone = false
    if not gBrokerThreadHookRegistered:
      gBrokerThreadHookRegistered = true
      onThreadDestruction(
        proc() {.gcsafe, raises: [].} =
          teardownBrokerThread()
      )
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
  fireBrokerSignal(gBrokerThreadSignal)

  proc awaitLoopExit() {.async: (raises: []).} =
    let deadline = Moment.now() + chronos.seconds(2)
    while gBrokerDispatchStarted and Moment.now() < deadline:
      let sleepRes = catch:
        await sleepAsync(milliseconds(1))
      if sleepRes.isErr():
        break

  waitFor awaitLoopExit()
  gBrokerDispatchStopRequested = false

proc closeThreadDispatcherSelector*() {.gcsafe, raises: [].} =
  ## Close the calling thread's chronos dispatcher OS handle:
  ## - POSIX (kqueue / epoll / poll engine): the `Selector` fd
  ## - Windows (IOCP engine):                 the IOCP `HANDLE`
  ##
  ## chronos (4.2.2) has no `PDispatcher` teardown and neither `SelectorImpl`
  ## (POSIX) nor the Windows IOCP `PDispatcher` has a `=destroy` — the
  ## per-thread handle opened by `newDispatcher` (`kqueue()` / `epoll_create()`
  ## / `CreateIoCompletionPort`) is never closed, so it leaks once per thread
  ## that ever ran a chronos loop. The broker per-context threads
  ## (processing + delivery) are spawned and joined per `_createContext` /
  ## `_shutdown`, so without this every context lifecycle leaks 2 handles
  ## regardless of --mm:refc vs --mm:orc.
  ##
  ## Call as the LAST action of a broker thread proc, AFTER
  ## `stopBrokerDispatchHere()` has closed the per-thread `ThreadSignalPtr`
  ## and the dispatch loop has exited; at that point the dispatcher holds no
  ## live registered handles, so closing it only reclaims the dispatcher
  ## handle itself.
  {.cast(gcsafe).}:
    let disp = getThreadDispatcher()
    if disp.isNil:
      return
    when defined(windows):
      # chronos `HANDLE = distinct uint`; cast through pointer for our
      # inline CloseHandle prototype (Win32 `HANDLE` is `void*` ABI-wise).
      discard closeHandle(cast[pointer](getIoHandler(disp)))
    else:
      discard close2(getIoHandler(disp))

proc teardownBrokerThread*() {.gcsafe, raises: [].} =
  ## Ordered, idempotent teardown of ALL per-thread broker dispatch state.
  ## Call as the LAST broker-related action of a thread, from sync context:
  ##
  ##   1. stopBrokerDispatchHere() — drives chronos until brokerDispatchLoop
  ##      exits; the loop's exit path closes the per-thread signal wrapper
  ##      (waiting out concurrent firers) and, on Windows, dismantles the
  ##      pending RegisterWaitForSingleObject registration whose thread-pool
  ##      callback would otherwise dereference this thread's freed refc heap.
  ##   2. drainPendingRingFrees() — releases (ring, slab, pool) triples of
  ##      brokers cleared on this thread, after the 50 ms sender grace window.
  ##   3. closeThreadDispatcherSelector() — reclaims the chronos dispatcher
  ##      OS handle. The thread must not run chronos again afterwards.
  ##
  ## Runs automatically for Nim-created threads via the onThreadDestruction
  ## hook registered by ensureBrokerDispatchStarted (before refc's
  ## deallocOsPages). Foreign/FFI threads and the MAIN thread must call it
  ## explicitly (the main thread never runs thread-destruction handlers).
  ## Idempotent per broker-use incarnation: ensureBrokerDispatchStarted
  ## re-arms the latch, so explicit callers and the automatic hook compose.
  ## Identical behavior under --mm:refc and --mm:orc; under orc it fixes
  ## only handle/fd leaks (orc skips deallocOsPages, so the refc UAF window
  ## does not exist there).
  if gBrokerThreadTeardownDone:
    return
  gBrokerThreadTeardownDone = true
  stopBrokerDispatchHere()
  # Defensive: if a signal wrapper exists but the loop never ran (or already
  # exited without clearing it), close it here so the OS handle is reclaimed
  # while this thread's heap is still alive.
  let sig = gBrokerThreadSignal
  if not sig.isNil:
    gBrokerThreadSignal = nil
    closeBrokerSignalShared(sig)
  drainPendingRingFrees()
  closeThreadDispatcherSelector()

## api_cbor_courier — runtime support for the CBOR FFI "buffer courier".
## =====================================================================
## Part C of the CBOR refactoring (doc/CBOR_Refactoring.md §6).
##
## A CBOR-mode `<lib>_call` runs on a foreign caller's thread. Instead of
## decoding CBOR and driving a momentary chronos loop on that foreign
## thread, it becomes a pure courier:
##
##   1. copy the API name into a fixed POD message,
##   2. hand the raw request buffer (by pointer, ownership transferred)
##      to the processing thread over a `Channel`,
##   3. block on a per-call response slot until the processing thread
##      writes the response back.
##
## The processing thread owns CBOR decode/encode and the provider call.
##
## This module is plain runtime code (NOT codegen) used by the generated
## library runtime in `api_library.nim`. It deliberately contains no Nim
## GC types on the cross-thread message path: `CborCallMsg` is pure POD,
## so a foreign thread can enqueue one with zero GC involvement.
##
## Memory model:
##   - `reqBuf`  — `allocShared0` by `<lib>_allocBuffer`; ownership moves
##     into the `CborCallMsg`; the processing thread frees it exactly once
##     after copying the bytes out.
##   - `respBuf` — `allocShared0` on the processing thread; ownership
##     returns to the `_call` thread via the slot; the foreign caller
##     frees it via `<lib>_freeBuffer`.
##   - Response slots use a `Lock`+`Cond` (zero OS handles) for the
##     blocking handoff — no busy-poll, no per-slot `ThreadSignalPtr`.

{.push raises: [].}

import std/[atomics, locks]

const CborApiNameMax* = 256
  ## Inline fixed-size buffer for the ASCII API name carried in a courier
  ## message. Carrying the name itself (rather than an interned id) keeps
  ## the message self-describing and avoids a separate id table that could
  ## silently desync from the dispatch `case`.

const CborMaxSlotSegments = 4
  ## Doubling the slot pool from `origSlotCount` to the 4× ceiling appends at
  ## most two segments beyond the initial one (N → +N → +2N), so three are
  ## ever live; 4 leaves a margin.

type
  CborCallMsg* = object
    ## Pure-POD message a foreign `_call` thread hands to the processing
    ## thread. No Nim `string`/`seq`/`ref` — safe to copy through a
    ## `Channel` with zero GC involvement on the foreign thread.
    apiName*: array[CborApiNameMax, char] ## NUL-terminated ASCII
    reqBuf*: pointer ## allocShared0; ownership transfers to the processing thread
    reqLen*: int32
    slotIdx*: int32 ## index of the response slot to complete
    targetCtx*: uint32
      ## reduced-A: the FULL BrokerContext the foreign caller addressed. For a
      ## main-context call this equals the library ctx; for a sub-instance call
      ## it carries the sub ctx (same classCtx as the library, distinct
      ## instanceCtx). The processing thread dispatches the adapter against this
      ## so the provider keyed by the sub ctx is reached.

  CborRespSlot = object
    lock: Lock
    cond: Cond
    inUse: Atomic[int] ## 0 free, 1 claimed — claimed via CAS
    ready: int ## guarded by `lock`: 0 pending, 1 complete
    respBuf: pointer ## allocShared0; ownership returns to the `_call` thread
    respLen: int32
    status: int32 ## the int32 `<lib>_call` returns to the foreign caller

  CborCallRing* = object
    ## Single-lock POD-element MPSC ring, allocated wholly in shared
    ## heap. Replaces `system.Channel[CborCallMsg]` deliberately: that
    ## channel allocates its message slots out of the sender thread's
    ## per-thread Nim allocator, and once the sender thread exits its
    ## TLS-tied allocator descriptor is freed by pthread cleanup. A
    ## subsequent `close()` on the shutdown thread walks straight into
    ## that dead descriptor (caught by ASAN on the stress_mt teardown
    ## path). This ring uses `allocShared` for its storage — single
    ## owner (the `CborCourier`), freed from the same thread that
    ## allocated it, no per-thread allocator involvement.
    buf: ptr UncheckedArray[CborCallMsg]
    cap: int
    head: int ## next index the consumer reads
    tail: int ## next index a producer writes
    count: int ## guarded by `lock`
    lock: Lock

  CborSlotSegment = object
    ## One append-only block of response slots. Existing segments are never
    ## moved or freed until teardown, so a foreign thread blocked in
    ## `waitSlot` on a slot's `Cond` keeps a stable address. This is the
    ## reason the pool grows by *appending* segments rather than
    ## reallocating one array: relocating a slot whose `Lock`/`Cond` a
    ## blocked `_call` is waiting on is a use-after-free.
    slots: ptr UncheckedArray[CborRespSlot]
    base: int ## global index of `slots[0]`
    len: int ## number of slots in this segment

  PodRing*[T] = object
    ## Minimal single-lock POD-element MPSC ring, fixed capacity (no growth).
    ## Storage in shared heap, single owner; never copied. Used for both the
    ## async call ring and the response ring. `false` from `tryPush` is real
    ## backpressure here (EAGAIN), unlike the sync `CborCallRing`.
    buf: ptr UncheckedArray[T]
    cap: int
    head: int ## next index the consumer reads
    tail: int ## next index a producer writes
    count: int ## guarded by `lock`
    lock: Lock

  CborAsyncCallMsg* = object
    ## Pure-POD message a foreign `_callAsync` thread hands to the processing
    ## thread. Mirrors `CborCallMsg` but carries the foreign response callback
    ## + opaque `userData` (response↔request correlation) and the caller's
    ## `reqId` instead of a response-slot index.
    apiName*: array[CborApiNameMax, char] ## NUL-terminated ASCII
    reqBuf*: pointer ## allocShared0; ownership transfers to the processing thread
    reqLen*: int32
    targetCtx*: uint32
      ## reduced-A full BrokerContext — same meaning as `CborCallMsg.targetCtx`
    reqId*: uint64 ## carried for logging/cancel/idempotency; NOT used for matching
    timeoutMs*: uint32
      ## Dispatch-scoped timeout. 0 = infinite (no timeout); N = N milliseconds.
      ## The processing thread RACES the provider dispatch against a chronos timer
      ## (`race`, deliberately not `withTimeout` — the broker/provider machinery
      ## swallows `withTimeout`'s cancellation into a normal completion, masking
      ## the timeout). On expiry it delivers status -12 exactly once and
      ## best-effort-cancels the provider. The library default (when a
      ## wrapper/caller wants it) is applied at the call site, NOT here — this
      ## field is the literal effective value.
    cb*: pointer ## the foreign `<lib>_response_cb_t`; never interpreted by the library
    userData*: pointer ## opaque correlation handle; handed back verbatim in `cb`

  CborCourier* = object
    ## One per library context. Lives in shared heap; created in
    ## `_createContext`, freed in `_shutdown` after the processing thread
    ## has joined and all in-flight `_call`s have drained.
    ring*: CborCallRing
    segs: array[CborMaxSlotSegments, CborSlotSegment]
    nSegs: Atomic[int]
      ## Live segment count. Published with `moRelease` after a new segment is
      ## fully populated; the lock-free claim scan reads it with `moAcquire`.
      ## Append-only — segments are never removed before teardown.
    slotCount: int
      ## Total live slots across all segments. Read/written only under
      ## `ring.lock` (growth coordinates the slot pool and the ring together).
    origSlotCount: int
      ## Set once at construction; the growth ceiling is `4 * origSlotCount`.
    inFlight*: Atomic[int]
      ## Count of `_call`s AND `_callAsync`s that passed the active-check but
      ## have not yet released the path. Sync: decremented after the slot is
      ## read. Async: decremented when the response is handed to the response
      ## courier (the processing thread is done with it). `_shutdown` waits for
      ## this to reach zero before telling the processing thread to stop.
    asyncRing*: PodRing[CborAsyncCallMsg]
      ## Fire-and-forget request ring for `_callAsync`. Separate from `ring`;
      ## fixed-capacity, full ⇒ EAGAIN. Never gated by the slot pool.
    asyncCap: int ## In-flight ceiling for async calls (== `asyncRing` capacity).
    asyncDepth*: Atomic[int]
      ## Accept→delivery counter bounding outstanding async calls so the
      ## response ring (sized to `asyncCap`) can never overflow. Incremented at
      ## `_callAsync` accept, decremented after the foreign callback fires on
      ## the delivery thread. Distinct from `inFlight` (the shutdown gate),
      ## which spans accept→response-enqueue only.

# ---------------------------------------------------------------------------
# Async call path (side by side with the sync slot/Cond machinery above).
#
# `<lib>_callAsync` is fire-and-forget: it never claims a response slot and
# never blocks on a `Cond`. The request rides its OWN ring (`asyncRing`,
# fixed-capacity — full ⇒ EAGAIN, no growth) into the processing thread; the
# response rides a separate `CborRespCourier` ring that the EXISTING event
# delivery thread drains and hands to a foreign callback. The sync types,
# `CborCallRing`, the slot pool, and every proc above are intentionally
# untouched.
# ---------------------------------------------------------------------------

type
  CborRespMsg* = object
    ## Pure-POD message the processing thread hands to the delivery thread to
    ## fan a single async response back to its foreign callback.
    cb*: pointer ## the `<lib>_response_cb_t` copied from the originating call
    userData*: pointer ## opaque correlation handle, verbatim
    reqId*: uint64
    status*: int32
    buf*: pointer ## allocShared0 CBOR response; delivery thread frees after `cb`
    bufLen*: int32

  CborRespCourier* = object
    ## One per library context. Lives in shared heap; created in
    ## `_createContext`, drained + freed in `_shutdown`. Drained by the
    ## existing event delivery thread via a second broker poller.
    ring*: PodRing[CborRespMsg]

# ---------------------------------------------------------------------------
# PodRing[T] — generic fixed-capacity MPSC ring for the async paths
# ---------------------------------------------------------------------------

proc initPodRing[T](r: var PodRing[T], cap: int) =
  r.buf = cast[ptr UncheckedArray[T]](allocShared0(cap * sizeof(T)))
  r.cap = cap
  r.head = 0
  r.tail = 0
  r.count = 0
  initLock(r.lock)

proc deinitPodRing[T](r: var PodRing[T]) =
  deinitLock(r.lock)
  if not r.buf.isNil:
    deallocShared(r.buf)
    r.buf = nil

proc tryPush[T](r: var PodRing[T], msg: T): bool =
  ## Multi-producer. Returns false on full (real backpressure / EAGAIN).
  acquire(r.lock)
  if r.count >= r.cap:
    release(r.lock)
    return false
  r.buf[r.tail] = msg
  r.tail = (r.tail + 1) mod r.cap
  inc r.count
  release(r.lock)
  true

proc tryPop[T](r: var PodRing[T], dst: var T): bool =
  ## Single consumer. Returns false on empty.
  acquire(r.lock)
  if r.count == 0:
    release(r.lock)
    return false
  dst = r.buf[r.head]
  r.head = (r.head + 1) mod r.cap
  dec r.count
  release(r.lock)
  true

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc newCborCourier*(slotCount: int, asyncCap = 0): ptr CborCourier =
  ## Allocate a courier. `slotCount` is the *initial* ceiling on concurrent
  ## in-flight SYNC `_call`s; the sync request ring is sized the same, so the
  ## slot pool gates the ring (a `_call` always claims a slot before enqueuing).
  ## On exhaustion the sync pool and ring grow together by doubling, up to a
  ## hard ceiling of `4 * slotCount` — see `claimSlot`.
  ##
  ## `asyncCap` is the SEPARATE, fixed ceiling on concurrent in-flight
  ## `_callAsync`s (the async ring does not grow). `asyncCap <= 0` defaults it to
  ## `slotCount`. The owning context's response courier MUST be sized
  ## `>= asyncCap` so a bounded set of outstanding async calls can never overflow
  ## the response ring.
  let effAsyncCap = if asyncCap > 0: asyncCap else: slotCount
  let c = cast[ptr CborCourier](allocShared0(sizeof(CborCourier)))
  c.ring.buf =
    cast[ptr UncheckedArray[CborCallMsg]](allocShared0(slotCount * sizeof(CborCallMsg)))
  c.ring.cap = slotCount
  c.ring.head = 0
  c.ring.tail = 0
  c.ring.count = 0
  initLock(c.ring.lock)
  c.origSlotCount = slotCount
  c.slotCount = slotCount
  let seg0 = cast[ptr UncheckedArray[CborRespSlot]](allocShared0(
    slotCount * sizeof(CborRespSlot)
  ))
  for i in 0 ..< slotCount:
    initLock(seg0[i].lock)
    initCond(seg0[i].cond)
    seg0[i].inUse.store(0, moRelaxed)
  c.segs[0] = CborSlotSegment(slots: seg0, base: 0, len: slotCount)
  c.nSegs.store(1, moRelease)
  # Async path: own fixed-capacity ring + in-flight ceiling (independent of the
  # sync slot pool, which may grow).
  initPodRing(c.asyncRing, effAsyncCap)
  c.asyncCap = effAsyncCap
  c.asyncDepth.store(0, moRelaxed)
  c

proc freeCborCourier*(c: ptr CborCourier) =
  ## Release a courier. MUST be called only after the processing thread
  ## has joined and `inFlight` has reached zero — see `_shutdown`.
  if c.isNil:
    return
  for s in 0 ..< c.nSegs.load(moAcquire):
    let seg = addr c.segs[s]
    for i in 0 ..< seg.len:
      deinitCond(seg.slots[i].cond)
      deinitLock(seg.slots[i].lock)
    deallocShared(seg.slots)
  deinitLock(c.ring.lock)
  if not c.ring.buf.isNil:
    deallocShared(c.ring.buf)
  # Free any async request buffers still queued (never reached the processing
  # thread): their `reqBuf` ownership was transferred to the message on enqueue.
  var am: CborAsyncCallMsg
  while tryPop(c.asyncRing, am):
    if not am.reqBuf.isNil:
      deallocShared(am.reqBuf)
  deinitPodRing(c.asyncRing)
  deallocShared(c)

# ---------------------------------------------------------------------------
# Ring — MPSC over a fixed-size POD slot array. Single lock for both ends;
# the ring is not the contended path (per-call cost is dominated by the
# Cond handoff and the chronos coroutine spawn).
# ---------------------------------------------------------------------------

proc growRingLocked(r: ptr CborCallRing, newCap: int): bool =
  ## Grow the POD ring to `newCap` (> `r.cap`), linearising live elements.
  ## Caller MUST hold `r.lock`. Safe because `CborCallMsg` is pure POD and no
  ## thread holds a pointer into `buf` across the lock.
  ##
  ## Returns false — leaving the ring completely untouched — if the new buffer
  ## cannot be allocated, so the caller can roll back the coordinated pool+ring
  ## growth instead of dereferencing nil while holding the lock.
  let newBuf =
    cast[ptr UncheckedArray[CborCallMsg]](allocShared0(newCap * sizeof(CborCallMsg)))
  if newBuf.isNil:
    return false
  for i in 0 ..< r.count:
    newBuf[i] = r.buf[(r.head + i) mod r.cap]
  deallocShared(r.buf)
  r.buf = newBuf
  r.head = 0
  r.tail = r.count
  r.cap = newCap
  true

proc tryEnqueue*(r: ptr CborCallRing, msg: CborCallMsg): bool =
  ## Multi-producer. Returns false on full. A `_call` always claims a
  ## response slot before enqueuing and the ring is grown in step with the
  ## slot pool (see `claimSlot`), so the ring cap always matches the live
  ## slot count and a `false` here is a programming error, not backpressure.
  acquire(r.lock)
  if r.count >= r.cap:
    release(r.lock)
    return false
  r.buf[r.tail] = msg
  r.tail = (r.tail + 1) mod r.cap
  inc r.count
  release(r.lock)
  true

proc tryDequeue*(r: ptr CborCallRing, dst: var CborCallMsg): bool =
  ## Single consumer. Returns false on empty.
  acquire(r.lock)
  if r.count == 0:
    release(r.lock)
    return false
  dst = r.buf[r.head]
  r.head = (r.head + 1) mod r.cap
  dec r.count
  release(r.lock)
  true

# ---------------------------------------------------------------------------
# Response slots
# ---------------------------------------------------------------------------

proc slotAt(c: ptr CborCourier, idx: int): ptr CborRespSlot {.inline.} =
  ## Map a global slot index to its slot in the owning segment. Segments are
  ## append-only and never relocated, so a published index stays valid.
  for s in 0 ..< c.nSegs.load(moAcquire):
    let seg = addr c.segs[s]
    if idx >= seg.base and idx < seg.base + seg.len:
      return addr seg.slots[idx - seg.base]
  nil

proc initClaimedSlot(s: ptr CborRespSlot) {.inline.} =
  acquire(s.lock)
  s.ready = 0
  s.respBuf = nil
  s.respLen = 0
  s.status = 0
  release(s.lock)

proc tryClaimScan(c: ptr CborCourier): int =
  ## Scan all live slots for a free one; CAS-claim and reset it. Returns the
  ## global index, or -1 if none free. Lock-free over the published segments.
  for sgi in 0 ..< c.nSegs.load(moAcquire):
    let seg = addr c.segs[sgi]
    for i in 0 ..< seg.len:
      var expected = 0
      if seg.slots[i].inUse.compareExchange(expected, 1, moAcquire, moRelaxed):
        initClaimedSlot(addr seg.slots[i])
        return seg.base + i
  -1

proc claimSlot*(c: ptr CborCourier): int =
  ## Claim a free response slot. Returns its index, or -1 only when the pool
  ## is at its `4 * origSlotCount` ceiling and fully in-use. On exhaustion
  ## below the ceiling the pool grows by appending a new segment (existing
  ## slots are never moved) and the ring grows in step — both under
  ## `ring.lock`. Growth is the rare slow path.
  let fast = tryClaimScan(c)
  if fast >= 0:
    return fast
  # Pool exhausted. Coordinate growth under the ring lock.
  acquire(c.ring.lock)
  # Re-scan under the lock: a concurrent release or a concurrent grow may
  # have produced a usable slot since the lock-free scan above.
  let again = tryClaimScan(c)
  if again >= 0:
    release(c.ring.lock)
    return again
  let curCount = c.slotCount
  let newCount = min(curCount * 2, c.origSlotCount * 4)
  let segIdx = c.nSegs.load(moAcquire)
  if newCount == curCount or segIdx >= CborMaxSlotSegments:
    release(c.ring.lock) # at the ceiling — retain the drop contract
    return -1
  let addLen = newCount - curCount
  let seg =
    cast[ptr UncheckedArray[CborRespSlot]](allocShared0(addLen * sizeof(CborRespSlot)))
  if seg.isNil:
    # OOM allocating the new slot segment: nothing has been mutated yet, so
    # release the lock and retain the refusal (drop) contract rather than
    # crashing in initLock/initCond.
    release(c.ring.lock)
    return -1
  for i in 0 ..< addLen:
    initLock(seg[i].lock)
    initCond(seg[i].cond)
    seg[i].inUse.store(0, moRelaxed)
  # Grow the ring in step BEFORE committing any pool state. If the ring buffer
  # can't be allocated, roll back the freshly-built segment (nothing has been
  # published — slotCount/segs/nSegs are untouched and the ring is left intact)
  # and retain the refusal contract.
  if not growRingLocked(addr c.ring, newCount):
    for i in 0 ..< addLen:
      deinitCond(seg[i].cond)
      deinitLock(seg[i].lock)
    deallocShared(seg)
    release(c.ring.lock)
    return -1
  # Ring grown; the pool+ring growth is guaranteed to complete. Claim slot 0 of
  # the new segment BEFORE publishing it, so no concurrent scanner can race us.
  var expected = 0
  discard seg[0].inUse.compareExchange(expected, 1, moAcquire, moRelaxed)
  initClaimedSlot(addr seg[0])
  c.segs[segIdx] = CborSlotSegment(slots: seg, base: curCount, len: addLen)
  c.slotCount = newCount # ring cap already == newCount
  c.nSegs.store(segIdx + 1, moRelease) # publish last
  release(c.ring.lock)
  curCount # global index of seg[0], already claimed

proc releaseSlot*(c: ptr CborCourier, idx: int) =
  ## Return a slot to the free pool. Call only after `waitSlot` returned.
  slotAt(c, idx).inUse.store(0, moRelease)

proc completeSlot*(
    c: ptr CborCourier, idx: int, respBuf: pointer, respLen: int32, status: int32
) =
  ## Processing-thread side: publish a response and wake the waiting
  ## `_call`. `respBuf` ownership passes to the `_call` thread.
  let s = slotAt(c, idx)
  acquire(s.lock)
  s.respBuf = respBuf
  s.respLen = respLen
  s.status = status
  s.ready = 1
  signal(s.cond)
  release(s.lock)

proc waitSlot*(
    c: ptr CborCourier, idx: int
): tuple[respBuf: pointer, respLen: int32, status: int32] =
  ## Foreign `_call` side: block until `completeSlot` publishes a response.
  ## Zero-fd blocking handoff via `Cond` — no busy-poll.
  let s = slotAt(c, idx)
  acquire(s.lock)
  while s.ready == 0:
    wait(s.cond, s.lock)
  result = (s.respBuf, s.respLen, s.status)
  s.ready = 0
  release(s.lock)

# ---------------------------------------------------------------------------
# Async call path — enqueue / dequeue + depth accounting
# ---------------------------------------------------------------------------

proc tryEnqueueAsync*(c: ptr CborCourier, msg: CborAsyncCallMsg): bool =
  ## Foreign `_callAsync` side. Reserves an in-flight depth slot (bounding
  ## outstanding async calls so the response ring cannot overflow) and pushes
  ## the message. Returns false — having reserved nothing — when the async ring
  ## is full or the in-flight ceiling is reached (EAGAIN). On success the caller
  ## owns the depth reservation; it is released by `asyncDepthDec` after the
  ## foreign callback fires. `msg.reqBuf` ownership transfers on success.
  if c.asyncDepth.fetchAdd(1, moAcquireRelease) >= c.asyncCap:
    discard c.asyncDepth.fetchSub(1, moRelease)
    return false
  if not tryPush(c.asyncRing, msg):
    discard c.asyncDepth.fetchSub(1, moRelease)
    return false
  true

proc tryDequeueAsync*(c: ptr CborCourier, dst: var CborAsyncCallMsg): bool =
  ## Processing-thread side: pull the next queued async request. Returns false
  ## on empty.
  tryPop(c.asyncRing, dst)

proc asyncDepthDec*(c: ptr CborCourier) =
  ## Delivery-thread side: release one in-flight depth reservation after the
  ## foreign response callback has fired.
  discard c.asyncDepth.fetchSub(1, moRelease)

# ---------------------------------------------------------------------------
# Response courier — processing thread → delivery thread async-response ring
# ---------------------------------------------------------------------------

proc newCborRespCourier*(cap: int): ptr CborRespCourier =
  ## Allocate a response courier with `cap` ring slots. `cap` MUST be >= the
  ## owning call courier's `asyncCap`, so a bounded set of outstanding async
  ## calls can never overflow the ring.
  let rc = cast[ptr CborRespCourier](allocShared0(sizeof(CborRespCourier)))
  initPodRing(rc.ring, cap)
  rc

proc freeCborRespCourier*(rc: ptr CborRespCourier) =
  ## Release a response courier. Call only after `_shutdown` has drained it
  ## (invoking each pending callback). As a backstop, frees any response buffer
  ## still queued.
  if rc.isNil:
    return
  var m: CborRespMsg
  while tryPop(rc.ring, m):
    if not m.buf.isNil:
      deallocShared(m.buf)
  deinitPodRing(rc.ring)
  deallocShared(rc)

proc tryEnqueueResp*(rc: ptr CborRespCourier, msg: CborRespMsg): bool =
  ## Processing-thread side: hand a response to the delivery thread. Returns
  ## false only if the ring is full (cannot happen while outstanding async
  ## calls are bounded to <= ring cap); caller then frees `msg.buf`.
  tryPush(rc.ring, msg)

proc tryDequeueResp*(rc: ptr CborRespCourier, dst: var CborRespMsg): bool =
  ## Delivery-thread side: pull the next response to fan out. Returns false on
  ## empty.
  tryPop(rc.ring, dst)

{.pop.}

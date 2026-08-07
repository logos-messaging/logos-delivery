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
      ## Count of `_call`s that passed the active-check but have not yet
      ## finished reading their slot. `_shutdown` waits for this to reach
      ## zero — while the processing thread is still handling — before it
      ## tells the processing thread to stop.

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc newCborCourier*(slotCount: int): ptr CborCourier =
  ## Allocate a courier with `slotCount` response slots. `slotCount` is the
  ## *initial* ceiling on concurrent in-flight `_call`s; the request ring is
  ## sized the same, so the slot pool gates the ring (a `_call` always claims
  ## a slot before enqueuing). On exhaustion the pool and ring grow together
  ## by doubling, up to a hard ceiling of `4 * slotCount` — see `claimSlot`.
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

{.pop.}

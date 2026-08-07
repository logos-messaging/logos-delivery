## Multi-Thread Broker Queue Primitives
## ------------------------------------
## Lock-free MPSC primitives used to replace `Channel[T]` in the (mt)
## brokers. Implements `doc/REFACTOR_MT_QUEUE.md` §3.
##
## Invariants enforced by *structural design*, not by runtime asserts:
##
## I0  every `createShared` / `deallocShared` runs on a persistent owner
##     thread (bucket-owner for per-bucket structures, global-slab-owner
##     for events). Hot path (claim / release / enqueue / dequeue) never
##     calls any Nim allocator.
##     CARVE-OUT (flexible-mt-dispatch): when a marshaled payload exceeds the
##     fixed cell, the producer `allocShared0`s a heap-spill buffer and the
##     consumer-side `release` `deallocShared`s it. So the spill path DOES
##     allocate on the hot path — a deliberate trade so oversized payloads
##     (>cell, e.g. >1 MiB) succeed instead of being dropped. The common
##     fits-the-cell path is unchanged and allocator-free. Spill buffers are
##     POD bytes with single producer→consumer ownership, same cross-thread
##     contract as `storage` itself.
## I1  Senders only execute: atomic load / store / CAS, memcpy into
##     pre-allocated cells, and `ThreadSignalPtr.fireSync()` (external).
## I2  The owner thread must outlive every structure it owns.
##
## Phase 1 deliverable: this module + its tests. No broker code calls it
## yet — that lands in Phases 2-4.

{.push raises: [].}

import std/atomics

# ---------------------------------------------------------------------------
# Cache-line padding helpers
# ---------------------------------------------------------------------------

const CacheLineBytes* = 64

type CacheLineGap = array[CacheLineBytes, byte]

# ---------------------------------------------------------------------------
# ShardedFreeList — Treiber stack with ABA tagging, sharded by thread hash
# ---------------------------------------------------------------------------
#
# Head word layout (uint64):
#   bits  0..31  index into the free-list's external `nextLinks` array
#   bits 32..63  ABA tag (incremented on every successful CAS)
#
# A special INDEX value `EmptyIdx` means "this shard is empty".
# The free-list does NOT own the storage — callers manage capacity and
# the `nextLinks` array externally. This keeps the primitive composable.

const EmptyIdx*: uint32 = high(uint32)

template makeHead(idx, tag: uint32): uint64 =
  (uint64(tag) shl 32) or uint64(idx)

template headIdx(v: uint64): uint32 =
  uint32(v and 0xFFFFFFFF'u64)

template headTag(v: uint64): uint32 =
  uint32(v shr 32)

type
  FreeListShard = object
    head: Atomic[uint64]
    gap: CacheLineGap

  ShardedFreeList* = object
    nShardsMask: uint32 ## nShards - 1; nShards is power-of-2
    nShards: uint32
    shards: ptr UncheckedArray[FreeListShard]
    nextLinks: ptr UncheckedArray[uint32] ## idx → next idx (or EmptyIdx)

proc initShardedFreeList*(
    fl: var ShardedFreeList, nShards: uint32, capacity: uint32
) {.gcsafe.} =
  ## Initialize a sharded free-list. `nShards` MUST be a power of two.
  ## `nextLinks` is allocated as a parallel array of `capacity` indices,
  ## all initialised to `EmptyIdx`.
  doAssert nShards > 0 and (nShards and (nShards - 1)) == 0,
    "nShards must be power of two"
  fl.nShards = nShards
  fl.nShardsMask = nShards - 1
  fl.shards =
    cast[ptr UncheckedArray[FreeListShard]](createShared(FreeListShard, nShards.int))
  for i in 0 ..< nShards.int:
    fl.shards[i].head.store(makeHead(EmptyIdx, 0), moRelaxed)
  fl.nextLinks = cast[ptr UncheckedArray[uint32]](createShared(uint32, capacity.int))
  for i in 0 ..< capacity.int:
    fl.nextLinks[i] = EmptyIdx

proc deinitShardedFreeList*(fl: var ShardedFreeList) {.gcsafe.} =
  if not fl.shards.isNil:
    deallocShared(fl.shards)
    fl.shards = nil
  if not fl.nextLinks.isNil:
    deallocShared(fl.nextLinks)
    fl.nextLinks = nil

proc push*(fl: var ShardedFreeList, idx: uint32, shardHint: uint32) {.gcsafe.} =
  ## Push `idx` onto the free-list. `shardHint` selects the shard to push to.
  let shardIdx = shardHint and fl.nShardsMask
  let shard = addr fl.shards[shardIdx]
  while true:
    let oldHead = shard.head.load(moAcquire)
    fl.nextLinks[idx] = headIdx(oldHead)
    # Tag increments on every successful push to dodge ABA.
    let newHead = makeHead(idx, headTag(oldHead) + 1)
    var expected = oldHead
    if shard.head.compareExchangeWeak(expected, newHead, moAcquireRelease, moAcquire):
      return

proc pop*(fl: var ShardedFreeList, shardHint: uint32): uint32 {.gcsafe.} =
  ## Pop an index from the free-list. Tries `shardHint`'s shard first;
  ## if empty, scans other shards. Returns `EmptyIdx` if all shards are empty.
  let preferred = shardHint and fl.nShardsMask
  for offset in 0'u32 ..< fl.nShards:
    let shardIdx = (preferred + offset) and fl.nShardsMask
    let shard = addr fl.shards[shardIdx]
    while true:
      let oldHead = shard.head.load(moAcquire)
      let idx = headIdx(oldHead)
      if idx == EmptyIdx:
        break # try next shard
      let nextIdx = fl.nextLinks[idx]
      let newHead = makeHead(nextIdx, headTag(oldHead) + 1)
      var expected = oldHead
      if shard.head.compareExchangeWeak(expected, newHead, moAcquireRelease, moAcquire):
        return idx
      # CAS failed; loop and retry on this shard.
  return EmptyIdx

# ---------------------------------------------------------------------------
# VyukovMpscRing[T] — bounded MPSC ring with closed-flag handoff
# ---------------------------------------------------------------------------
#
# Atomic protocol:
# Producer (`tryEnqueue`):
#   1. closed-check (acquire) → if closed, return false.
#   2. pos = enqPos.load(relaxed)
#   3. loop:
#        slot = &slots[pos & mask]
#        seq = slot.seq.load(acquire)
#        diff = seq - pos  (as signed)
#        if diff == 0:
#          CAS enqPos: pos → pos+1 (acquireRelease on success, acquire on failure)
#          if success: break  (slot is claimed; must publish)
#          else: pos was reloaded into `expected`; loop
#        elif diff < 0:
#          return false (full)
#        else:
#          another producer claimed this slot already; reload pos, loop
#   4. write slot.payload
#   5. slot.seq.store(pos+1, release)  -- publish
#
# Consumer (`tryDequeue`, single-thread):
#   1. pos = deqPos
#   2. seq = slots[pos & mask].seq.load(acquire)
#   3. if seq != pos+1: return false (empty / not yet published)
#   4. read payload
#   5. slots[pos & mask].seq.store(pos + capacity, release) -- slot reusable
#   6. deqPos = pos + 1
#
# Closed-flag handoff (`drain` called by owner):
#   1. closed.store(true, release)
#   2. spin-loop: tryDequeue all visible items; sleep if there's a gap
#      (slot not yet published by an in-flight producer that already CAS'd).
#      Exit when deqPos == enqPos.

type
  Slot*[T] = object
    seq: Atomic[uint64]
    payload*: T

  VyukovMpscRing*[T] = object
    capacity*: uint64
    mask: uint64
    closed: Atomic[bool]
    gap0: CacheLineGap
    enqPos: Atomic[uint64]
    gap1: CacheLineGap
    deqPos: uint64
    gap2: CacheLineGap
    slots: ptr UncheckedArray[Slot[T]]

proc newVyukovMpscRing*[T](capacity: int): ptr VyukovMpscRing[T] {.gcsafe.} =
  ## Allocate a ring of the given capacity (must be power-of-2).
  ## Returns ownership; deinit via `freeVyukovMpscRing`.
  doAssert capacity > 0 and (capacity and (capacity - 1)) == 0,
    "capacity must be power-of-2"
  result = cast[ptr VyukovMpscRing[T]](createShared(VyukovMpscRing[T], 1))
  result.capacity = uint64(capacity)
  result.mask = uint64(capacity - 1)
  result.closed.store(false, moRelaxed)
  result.enqPos.store(0, moRelaxed)
  result.deqPos = 0
  result.slots = cast[ptr UncheckedArray[Slot[T]]](createShared(Slot[T], capacity))
  for i in 0 ..< capacity:
    result.slots[i].seq.store(uint64(i), moRelaxed)

proc freeVyukovMpscRing*[T](ring: ptr VyukovMpscRing[T]) {.gcsafe.} =
  ## Deallocate. Must be called on the owner thread, with the ring already
  ## drained (caller responsibility).
  if ring.isNil:
    return
  if not ring.slots.isNil:
    deallocShared(ring.slots)
  deallocShared(ring)

proc isClosed*[T](ring: ptr VyukovMpscRing[T]): bool {.gcsafe.} =
  ring.closed.load(moAcquire)

proc close*[T](ring: ptr VyukovMpscRing[T]) {.gcsafe.} =
  ring.closed.store(true, moRelease)

proc tryEnqueue*[T](ring: ptr VyukovMpscRing[T], item: sink T): bool {.gcsafe.} =
  ## Returns true if enqueued, false if full or closed.
  ## Safe to call from any number of producer threads.
  if ring.closed.load(moAcquire):
    return false
  var pos = ring.enqPos.load(moRelaxed)
  while true:
    let slot = addr ring.slots[pos and ring.mask]
    let seqV = slot.seq.load(moAcquire)
    let diff = cast[int64](seqV) - cast[int64](pos)
    if diff == 0:
      var expected = pos
      if ring.enqPos.compareExchangeWeak(expected, pos + 1, moAcquireRelease, moAcquire):
        # We own slot[pos]. Re-check closed for the "closed after our
        # initial check but before CAS" race; if closed, we must still
        # publish so the consumer can observe and drain it. The drain
        # protocol counts on the slot being published.
        slot.payload = item
        slot.seq.store(pos + 1, moRelease)
        return true
      # CAS failed; `expected` now holds the latest enqPos; retry.
      pos = expected
    elif diff < 0:
      # Full: slot.seq lags pos, which means the prior occupant hasn't
      # been consumed yet.
      return false
    else:
      # diff > 0: another producer is ahead of us; reload pos.
      pos = ring.enqPos.load(moRelaxed)

proc tryDequeue*[T](ring: ptr VyukovMpscRing[T], outItem: var T): bool {.gcsafe.} =
  ## Returns true if an item was dequeued, false if empty.
  ## MUST be called from a single consumer thread.
  let pos = ring.deqPos
  let slot = addr ring.slots[pos and ring.mask]
  let seqV = slot.seq.load(moAcquire)
  let diff = cast[int64](seqV) - cast[int64](pos + 1)
  if diff != 0:
    return false
  outItem = slot.payload
  slot.seq.store(pos + ring.capacity, moRelease)
  ring.deqPos = pos + 1
  return true

proc isEmpty*[T](ring: ptr VyukovMpscRing[T]): bool {.gcsafe.} =
  ## Consumer-side observation; producers may concurrently enqueue,
  ## so callers must treat the result as a hint unless they also hold
  ## a guarantee that no producers are active.
  ring.enqPos.load(moAcquire) == ring.deqPos

# ---------------------------------------------------------------------------
# RefCountedCell + PayloadSlab — pre-allocated payload cells
# ---------------------------------------------------------------------------
#
# Cell layout (computed at runtime, since payload bytes are variable-size):
#   CellHeader fields:  refcount (Atomic[int]), payloadSize (uint32),
#                       overflowLen (uint32), overflow (pointer)
#   then:               payloadBytes[]  (payloadCap bytes; from
#                       slab.cellPayloadCap), starting at sizeof(CellHeader).
# (cellStride is alignUp(sizeof(CellHeader) + payloadCap, 8), so the exact
#  payload offset is always sizeof(CellHeader) regardless of field packing —
#  do not assume a hard-coded offset, the header grew with the spill fields.)
#
# We address cells by index (uint32) so the free-list can ABA-tag indices
# rather than pointers. Pointer access is via `slab.cellPtr(idx)`.

type
  CellHeader* = object
    refcount*: Atomic[int]
    payloadSize*: uint32
      ## inline marshaled bytes used. uint32 (not uint16) so a configured cell
      ## may exceed 64 KiB — broker messages can be >1 MiB. 0 when the payload
      ## spilled to the heap (see `overflow`).
    overflowLen*: uint32 ## spilled byte count; 0 when the payload fit inline.
    overflow*: pointer
      ## heap-spill buffer (`allocShared0`) when the marshaled payload exceeded
      ## the fixed cell; `nil` on the inline fast path. Owned by the cell: freed
      ## in `release` (refcount→0 chokepoint) and walked by `deinitPayloadSlab`.
      ## POD bytes only — same cross-thread ownership contract as `storage`.

  PayloadSlab* = object
    capacity: uint32
    cellPayloadCap*: uint32 ## bytes available for marshaled data per cell
    cellStride: uint32 ## sizeof(CellHeader) + cellPayloadCap, aligned
    storage: ptr UncheckedArray[byte]
    freeList: ShardedFreeList

proc cellHeaderSize(): uint32 {.compileTime.} =
  uint32(sizeof(CellHeader))

proc alignUp(v, a: uint32): uint32 =
  (v + a - 1) and not (a - 1)

proc initPayloadSlab*(
    slab: var PayloadSlab, capacity: uint32, payloadBytes: uint32, nShards: uint32
) {.gcsafe.} =
  ## Pre-allocates `capacity` cells, each with `payloadBytes` of payload
  ## space. Uses `nShards` (must be power-of-2) for free-list contention.
  ## All cells start on the free-list.
  doAssert capacity > 0
  doAssert payloadBytes > 0
  slab.capacity = capacity
  slab.cellPayloadCap = payloadBytes
  slab.cellStride = alignUp(cellHeaderSize() + payloadBytes, 8'u32)
  slab.storage = cast[ptr UncheckedArray[byte]](createShared(
    byte, int(capacity) * int(slab.cellStride)
  ))
  initShardedFreeList(slab.freeList, nShards, capacity)
  # Seed the free-list with every cell.
  for i in 0 ..< capacity:
    push(slab.freeList, i, i)

proc cellPtr*(slab: PayloadSlab, idx: uint32): ptr CellHeader {.gcsafe.} =
  ## Returns the header pointer for the cell at `idx`. The payload bytes
  ## immediately follow the header (at `cast[ptr byte](header) +%
  ## sizeof(CellHeader)`).
  cast[ptr CellHeader](addr slab.storage[int(idx) * int(slab.cellStride)])

proc cellPayloadPtr*(
    slab: PayloadSlab, idx: uint32
): ptr UncheckedArray[byte] {.gcsafe.} =
  cast[ptr UncheckedArray[byte]](cast[uint](addr slab.storage[
    int(idx) * int(slab.cellStride)
  ]) + uint(sizeof(CellHeader)))

proc deinitPayloadSlab*(slab: var PayloadSlab) {.gcsafe.} =
  ## MUST be called on the owner thread after every outstanding cell has
  ## been released (caller responsibility). Frees the slab's storage and
  ## the free-list's internal arrays. Also walks every cell to free any
  ## heap-spill buffer still attached — covers shutdown / clearProvider with
  ## undelivered in-flight cells (a cell closed before delivery never passes
  ## through `release`, so its spill would otherwise leak).
  if not slab.storage.isNil:
    for i in 0'u32 ..< slab.capacity:
      let cell = slab.cellPtr(i)
      if not cell.overflow.isNil:
        deallocShared(cell.overflow)
        cell.overflow = nil
        cell.overflowLen = 0
  deinitShardedFreeList(slab.freeList)
  if not slab.storage.isNil:
    deallocShared(slab.storage)
    slab.storage = nil

proc setOverflow*(
    slab: PayloadSlab, idx: uint32, buf: pointer, len: uint32
) {.gcsafe.} =
  ## Attach a heap-spill buffer to a cell (payload exceeded the inline cell).
  ## The cell takes ownership; `release`/`deinitPayloadSlab` free it.
  let cell = slab.cellPtr(idx)
  cell.overflow = buf
  cell.overflowLen = len
  cell.payloadSize = 0

proc dataPtr*(slab: PayloadSlab, idx: uint32): ptr UncheckedArray[byte] {.gcsafe.} =
  ## Pointer to the marshaled bytes for a cell — the heap-spill buffer when the
  ## payload spilled, else the inline payload region.
  let cell = slab.cellPtr(idx)
  if not cell.overflow.isNil:
    cast[ptr UncheckedArray[byte]](cell.overflow)
  else:
    slab.cellPayloadPtr(idx)

proc dataLen*(slab: PayloadSlab, idx: uint32): int {.gcsafe.} =
  ## Marshaled byte count for a cell (spill length or inline payloadSize).
  let cell = slab.cellPtr(idx)
  if not cell.overflow.isNil:
    int(cell.overflowLen)
  else:
    int(cell.payloadSize)

proc claim*(slab: var PayloadSlab, shardHint: uint32): uint32 {.gcsafe.} =
  ## Returns a cell index or `EmptyIdx` if the slab is exhausted.
  pop(slab.freeList, shardHint)

proc release*(slab: var PayloadSlab, idx: uint32, shardHint: uint32) {.gcsafe.} =
  ## Returns a cell to the free-list. Caller must ensure no other thread
  ## still holds a reference (refcount == 0). This is the single chokepoint a
  ## cell passes through on its way back to the free-list (all delivery / drop /
  ## error paths funnel here once refcount hits 0), so any heap-spill buffer is
  ## freed here exactly once.
  let cell = slab.cellPtr(idx)
  if not cell.overflow.isNil:
    deallocShared(cell.overflow)
    cell.overflow = nil
    cell.overflowLen = 0
  push(slab.freeList, idx, shardHint)

proc incRef*(slab: PayloadSlab, idx: uint32) {.gcsafe.} =
  discard slab.cellPtr(idx).refcount.fetchAdd(1, moAcquireRelease)

proc decRefAndCheck*(slab: PayloadSlab, idx: uint32): bool {.gcsafe.} =
  ## Returns true if this decrement brought refcount to zero (caller should
  ## then `release(idx)`).
  let prev = slab.cellPtr(idx).refcount.fetchSub(1, moAcquireRelease)
  prev == 1

# ---------------------------------------------------------------------------
# ResponseSlot[T] + ResponseSlotPool[T] — single-shot request reply
# ---------------------------------------------------------------------------
#
# State machine on the slot's `state` byte:
#   Empty(0) ── requester claimed; provider hasn't written yet
#     │
#     ├── (provider) CAS Empty→Ready, write payload, signal requester
#     │       │
#     │       └── (requester) read payload; release slot
#     │
#     └── (requester timeout) CAS Empty→Abandoned
#             │
#             └── (provider) sees Abandoned; releases slot
#
# In both terminal cases the slot returns to the pool's free-list
# exactly once.

type
  ResponseState* {.pure.} = enum
    Empty = 0'u8
    Writing = 1'u8 ## reserved by provider; bytes in flight
    Ready = 2'u8
    Abandoned = 3'u8

  ResponseSlotHeader = object
    state: Atomic[uint8]
    pad0: array[3, byte] ## align the uint32 payloadSize to a 4-byte boundary
    payloadSize: uint32
      ## uint32 (not uint16) so a response slot may exceed 64 KiB.
      ## state(1) + pad0(3) + payloadSize(4) = 8 bytes → 8-aligned.
    overflowLen: uint32 ## spilled response byte count; 0 when the response fit inline.
    pad1: uint32 ## keep the pointer that follows 8-aligned (overflowLen at +8)
    overflow: pointer
      ## heap-spill buffer for an oversized response; `nil` inline. Owned by the
      ## slot: freed in `release` and walked by `deinitResponseSlotPool`.

  ResponseSlotPool* = object
    capacity*: uint32
    slotPayloadCap*: uint32
    slotStride: uint32
    storage: ptr UncheckedArray[byte]
    freeList: ShardedFreeList

proc respSlotHeaderSize(): uint32 {.compileTime.} =
  uint32(sizeof(ResponseSlotHeader))

proc slotHeaderPtr(
    pool: ResponseSlotPool, idx: uint32
): ptr ResponseSlotHeader {.gcsafe.} =
  cast[ptr ResponseSlotHeader](addr pool.storage[int(idx) * int(pool.slotStride)])

proc slotPayloadPtr*(
    pool: ResponseSlotPool, idx: uint32
): ptr UncheckedArray[byte] {.gcsafe.} =
  cast[ptr UncheckedArray[byte]](cast[uint](addr pool.storage[
    int(idx) * int(pool.slotStride)
  ]) + uint(sizeof(ResponseSlotHeader)))

proc initResponseSlotPool*(
    pool: var ResponseSlotPool,
    capacity: uint32,
    maxPayloadBytes: uint32,
    nShards: uint32,
) {.gcsafe.} =
  pool.capacity = capacity
  pool.slotPayloadCap = maxPayloadBytes
  pool.slotStride = alignUp(respSlotHeaderSize() + maxPayloadBytes, 8'u32)
  pool.storage = cast[ptr UncheckedArray[byte]](createShared(
    byte, int(capacity) * int(pool.slotStride)
  ))
  initShardedFreeList(pool.freeList, nShards, capacity)
  for i in 0 ..< capacity:
    let hdr = pool.slotHeaderPtr(i)
    hdr.state.store(uint8(ResponseState.Empty), moRelaxed)
    hdr.payloadSize = 0
    push(pool.freeList, i, i)

proc deinitResponseSlotPool*(pool: var ResponseSlotPool) {.gcsafe.} =
  ## Walk every slot to free any heap-spill buffer still attached (shutdown
  ## with an undelivered response), then free storage + free-list arrays.
  if not pool.storage.isNil:
    for i in 0'u32 ..< pool.capacity:
      let hdr = pool.slotHeaderPtr(i)
      if not hdr.overflow.isNil:
        deallocShared(hdr.overflow)
        hdr.overflow = nil
        hdr.overflowLen = 0
  deinitShardedFreeList(pool.freeList)
  if not pool.storage.isNil:
    deallocShared(pool.storage)
    pool.storage = nil

proc claim*(pool: var ResponseSlotPool, shardHint: uint32): uint32 {.gcsafe.} =
  let idx = pop(pool.freeList, shardHint)
  if idx != EmptyIdx:
    let hdr = pool.slotHeaderPtr(idx)
    hdr.payloadSize = 0
    # release() already frees+nils any spill, but defend against a slot that
    # reached the free-list without passing release (it should not).
    if not hdr.overflow.isNil:
      deallocShared(hdr.overflow)
      hdr.overflow = nil
    hdr.overflowLen = 0
    hdr.state.store(uint8(ResponseState.Empty), moRelease)
  idx

proc release*(pool: var ResponseSlotPool, idx: uint32, shardHint: uint32) {.gcsafe.} =
  ## Single chokepoint a slot passes through back to the free-list (requester
  ## after read, or provider on abandon). Free any heap-spill buffer here.
  let hdr = pool.slotHeaderPtr(idx)
  if not hdr.overflow.isNil:
    deallocShared(hdr.overflow)
    hdr.overflow = nil
    hdr.overflowLen = 0
  push(pool.freeList, idx, shardHint)

proc beginWrite*(pool: ResponseSlotPool, idx: uint32): bool {.gcsafe.} =
  ## Provider: CAS Empty→Writing. Returns false if the requester abandoned
  ## the slot first (caller should release without writing).
  let hdr = pool.slotHeaderPtr(idx)
  var expected = uint8(ResponseState.Empty)
  hdr.state.compareExchange(
    expected, uint8(ResponseState.Writing), moAcquireRelease, moAcquire
  )

proc commitWrite*(pool: ResponseSlotPool, idx: uint32, payloadSize: uint32) {.gcsafe.} =
  ## Provider: finalize after writing payload bytes. Stores size + flips
  ## state to Ready (release-ordered, so the bytes-write is visible to
  ## any acquire-loader on the state).
  let hdr = pool.slotHeaderPtr(idx)
  hdr.payloadSize = payloadSize
  hdr.state.store(uint8(ResponseState.Ready), moRelease)

proc commitWriteOverflow*(
    pool: ResponseSlotPool, idx: uint32, buf: pointer, len: uint32
) {.gcsafe.} =
  ## Provider: finalize an oversized response that spilled to the heap. The
  ## slot takes ownership of `buf` (freed in `release`/`deinitResponseSlotPool`).
  ## Sets inline payloadSize = 0 and flips state to Ready (release-ordered so the
  ## buffer pointer + the bytes it points to are visible to an acquire-loader).
  let hdr = pool.slotHeaderPtr(idx)
  hdr.overflow = buf
  hdr.overflowLen = len
  hdr.payloadSize = 0
  hdr.state.store(uint8(ResponseState.Ready), moRelease)

proc respDataPtr*(
    pool: ResponseSlotPool, idx: uint32
): ptr UncheckedArray[byte] {.gcsafe.} =
  ## Pointer to the marshaled response bytes — spill buffer when spilled, else
  ## the inline slot payload region.
  let hdr = pool.slotHeaderPtr(idx)
  if not hdr.overflow.isNil:
    cast[ptr UncheckedArray[byte]](hdr.overflow)
  else:
    pool.slotPayloadPtr(idx)

proc respDataLen*(pool: ResponseSlotPool, idx: uint32): int {.gcsafe.} =
  let hdr = pool.slotHeaderPtr(idx)
  if not hdr.overflow.isNil:
    int(hdr.overflowLen)
  else:
    int(hdr.payloadSize)

proc abandon*(pool: ResponseSlotPool, idx: uint32): bool {.gcsafe.} =
  ## Requester: CAS Empty→Abandoned. Returns true if abandonment took
  ## effect (provider hadn't started writing yet). If false, requester
  ## must still wait for state==Ready and consume normally — provider
  ## is mid-write or already done.
  let hdr = pool.slotHeaderPtr(idx)
  var expected = uint8(ResponseState.Empty)
  hdr.state.compareExchange(
    expected, uint8(ResponseState.Abandoned), moAcquireRelease, moAcquire
  )

proc readyState*(pool: ResponseSlotPool, idx: uint32): bool {.gcsafe.} =
  pool.slotHeaderPtr(idx).state.load(moAcquire) == uint8(ResponseState.Ready)

proc payloadSize*(pool: ResponseSlotPool, idx: uint32): uint32 {.gcsafe.} =
  pool.slotHeaderPtr(idx).payloadSize

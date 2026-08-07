## CBOR Subscription Registry
## --------------------------
## Refc-safe subscription book-keeping for the CBOR FFI listener path.
##
## The CBOR-mode listener delivery thread crosses GC boundaries with the
## subscriber registration path (subscribe/unsubscribe run on foreign caller
## threads via the C ABI). Under `--mm:orc` atomic refcounts make a plain
## `Table[(uint32, string), seq[Subscription]]` work; under `--mm:refc` the
## per-thread heaps + STW collector cannot safely see another thread's
## refcounted pointers, which used to gate the Phase 9F listener stress
## under macOS+Nim 2.2.4+refc+debug.
##
## This module replaces that GC'd container with a hand-rolled shared-heap
## hash table:
##   - `BucketHead` (one per `(ctx, eventName)` key) and `SubNode` (one per
##     subscription) are allocated via `allocShared0`.
##   - The event-name key is stored as an owned `cstring`
##     (`allocCStringCopy` at insertion, `freeCString` when the bucket goes
##     away).
##   - Bucket arrays are `ptr UncheckedArray[ptr BucketHead]`, never `seq`.
##
## All public procs are `{.gcsafe, raises: [].}` and acquire the registry's
## internal `Lock`. Snapshot copies `(cb, userData)` to a freshly-allocated
## shared buffer under the lock, so callbacks fan out unlocked against POD
## values that no concurrent unsubscriber can free.
##
## Callback type: stored as `pointer` so this module is generic across
## libraries. Callers cast back to the per-library `<lib>CborEventCallback`
## (a `cdecl, gcsafe, raises: []` proc type) at the call site.

{.push raises: [].}

import std/locks

type
  SubSnapshot* = object ## A POD copy of `(cb, userData)`. Callbacks fan out unlocked.
    cb*: pointer
    userData*: pointer

  SubNode = object
    handle: uint64
    cb: pointer
    userData: pointer
    next: ptr SubNode

  BucketHead = object
    ctx: uint32
    eventName: cstring # owned (allocCStringCopy)
    eventNameLen: int
    subsHead: ptr SubNode
    subsCount: int
    next: ptr BucketHead # collision chain

  SubsRegistry* = object
    buckets: ptr UncheckedArray[ptr BucketHead]
    bucketsLen: uint32 # always a power of two; mask = bucketsLen - 1
    entryCount: int # live BucketHead count, drives resize
    lock: Lock

const
  InitialBuckets: uint32 = 32
  ResizeNumerator = 3
  ResizeDenominator = 4 # resize at load factor 0.75

# ---------------------------------------------------------------------------
# Internal helpers (no locking — caller must hold reg.lock)
# ---------------------------------------------------------------------------

proc cstrLen(s: cstring): int {.inline, raises: [].} =
  if s.isNil:
    return 0
  var p = cast[ptr UncheckedArray[char]](s)
  var i = 0
  while p[i] != '\0':
    inc i
  i

proc cstrEq(a: cstring, aLen: int, b: cstring, bLen: int): bool {.inline.} =
  if aLen != bLen:
    return false
  if aLen == 0:
    return true
  let ap = cast[ptr UncheckedArray[byte]](a)
  let bp = cast[ptr UncheckedArray[byte]](b)
  for i in 0 ..< aLen:
    if ap[i] != bp[i]:
      return false
  true

proc cstrAlloc(s: cstring, sLen: int): cstring {.inline, raises: [].} =
  ## Local mirror of `allocCStringCopy(string)` for `cstring` input — avoids
  ## pulling in `api_common` (and its chronos chain) here.
  if sLen == 0:
    return cast[cstring](nil)
  let buf = cast[cstring](allocShared(sLen + 1))
  let src = cast[pointer](s)
  copyMem(buf, src, sLen)
  cast[ptr char](cast[int](buf) + sLen)[] = '\0'
  buf

proc cstrFree(s: cstring) {.inline.} =
  if not s.isNil:
    deallocShared(s)

proc keyHash(ctx: uint32, name: cstring, nameLen: int): uint32 {.inline.} =
  # FNV-1a-ish, seeded with ctx so two ctxs sharing a name spread across buckets.
  var h: uint32 = 2166136261'u32 xor ctx
  if nameLen > 0:
    let p = cast[ptr UncheckedArray[byte]](name)
    for i in 0 ..< nameLen:
      h = h xor uint32(p[i])
      h = h * 16777619'u32
  h

proc bucketIndex(
    reg: ptr SubsRegistry, ctx: uint32, name: cstring, nameLen: int
): uint32 {.inline.} =
  keyHash(ctx, name, nameLen) and (reg.bucketsLen - 1'u32)

proc findBucket(
    reg: ptr SubsRegistry, ctx: uint32, name: cstring, nameLen: int
): ptr BucketHead =
  let idx = bucketIndex(reg, ctx, name, nameLen)
  var b = reg.buckets[idx]
  while not b.isNil:
    if b.ctx == ctx and cstrEq(b.eventName, b.eventNameLen, name, nameLen):
      return b
    b = b.next
  nil

proc unlinkBucket(reg: ptr SubsRegistry, target: ptr BucketHead) =
  let idx = bucketIndex(reg, target.ctx, target.eventName, target.eventNameLen)
  var prev: ptr BucketHead = nil
  var cur = reg.buckets[idx]
  while not cur.isNil:
    if cur == target:
      if prev.isNil:
        reg.buckets[idx] = cur.next
      else:
        prev.next = cur.next
      return
    prev = cur
    cur = cur.next

proc freeNodeChain(head: ptr SubNode) =
  var cur = head
  while not cur.isNil:
    let nxt = cur.next
    deallocShared(cur)
    cur = nxt

proc disposeBucket(b: ptr BucketHead) =
  freeNodeChain(b.subsHead)
  cstrFree(b.eventName)
  deallocShared(b)

proc resize(reg: ptr SubsRegistry, newLen: uint32) =
  ## Double-or-larger rehash. Caller holds the lock.
  let bytes = sizeof(ptr BucketHead) * int(newLen)
  let newBuckets = cast[ptr UncheckedArray[ptr BucketHead]](allocShared0(bytes))
  let oldBuckets = reg.buckets
  let oldLen = reg.bucketsLen
  reg.buckets = newBuckets
  reg.bucketsLen = newLen
  for i in 0 ..< oldLen:
    var cur = oldBuckets[i]
    while not cur.isNil:
      let nxt = cur.next
      let idx = bucketIndex(reg, cur.ctx, cur.eventName, cur.eventNameLen)
      cur.next = reg.buckets[idx]
      reg.buckets[idx] = cur
      cur = nxt
  deallocShared(oldBuckets)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc subsRegistryNew*(): ptr SubsRegistry {.gcsafe, raises: [].} =
  let reg = cast[ptr SubsRegistry](allocShared0(sizeof(SubsRegistry)))
  let bytes = sizeof(ptr BucketHead) * int(InitialBuckets)
  reg.buckets = cast[ptr UncheckedArray[ptr BucketHead]](allocShared0(bytes))
  reg.bucketsLen = InitialBuckets
  reg.entryCount = 0
  initLock(reg.lock)
  reg

proc subsRegistryFree*(reg: ptr SubsRegistry) {.gcsafe, raises: [].} =
  ## Tear the entire registry down. Not normally called by the codegen — the
  ## generated runtime currently leaks the registry at process exit, matching
  ## the prior `Table` behaviour. Provided for completeness / tests.
  if reg.isNil:
    return
  for i in 0 ..< reg.bucketsLen:
    var cur = reg.buckets[i]
    while not cur.isNil:
      let nxt = cur.next
      disposeBucket(cur)
      cur = nxt
  deallocShared(reg.buckets)
  deinitLock(reg.lock)
  deallocShared(reg)

proc subsRegistryAdd*(
    reg: ptr SubsRegistry,
    ctx: uint32,
    name: cstring,
    handle: uint64,
    cb: pointer,
    userData: pointer,
) {.gcsafe, raises: [].} =
  ## Idempotent on `handle`: if a node with the same handle already exists for
  ## the key, the call is a no-op. Handles are minted by an atomic counter at
  ## the codegen call site so this branch normally never fires; it exists to
  ## keep the data structure self-consistent under bizarre caller bugs.
  {.cast(gcsafe).}:
    withLock reg.lock:
      let nameLen = cstrLen(name)
      var bucket = findBucket(reg, ctx, name, nameLen)
      if bucket.isNil:
        bucket = cast[ptr BucketHead](allocShared0(sizeof(BucketHead)))
        bucket.ctx = ctx
        bucket.eventName = cstrAlloc(name, nameLen)
        bucket.eventNameLen = nameLen
        bucket.subsHead = nil
        bucket.subsCount = 0
        let idx = bucketIndex(reg, ctx, name, nameLen)
        bucket.next = reg.buckets[idx]
        reg.buckets[idx] = bucket
        inc reg.entryCount
        if reg.entryCount * ResizeDenominator > int(reg.bucketsLen) * ResizeNumerator:
          resize(reg, reg.bucketsLen * 2'u32)
      else:
        var cur = bucket.subsHead
        while not cur.isNil:
          if cur.handle == handle:
            return
          cur = cur.next
      let node = cast[ptr SubNode](allocShared0(sizeof(SubNode)))
      node.handle = handle
      node.cb = cb
      node.userData = userData
      node.next = bucket.subsHead
      bucket.subsHead = node
      inc bucket.subsCount

proc subsRegistryRemoveOne*(
    reg: ptr SubsRegistry, ctx: uint32, name: cstring, handle: uint64
): int32 {.gcsafe, raises: [], discardable.} =
  ## Returns: 0 ok, -2 key not found, -3 handle not found.
  {.cast(gcsafe).}:
    withLock reg.lock:
      let nameLen = cstrLen(name)
      let bucket = findBucket(reg, ctx, name, nameLen)
      if bucket.isNil:
        return -2'i32
      var prev: ptr SubNode = nil
      var cur = bucket.subsHead
      while not cur.isNil:
        if cur.handle == handle:
          if prev.isNil:
            bucket.subsHead = cur.next
          else:
            prev.next = cur.next
          deallocShared(cur)
          dec bucket.subsCount
          if bucket.subsCount == 0:
            unlinkBucket(reg, bucket)
            disposeBucket(bucket)
            dec reg.entryCount
          return 0'i32
        prev = cur
        cur = cur.next
      return -3'i32

proc subsRegistryRemoveAllForKey*(
    reg: ptr SubsRegistry, ctx: uint32, name: cstring
): int32 {.gcsafe, raises: [], discardable.} =
  ## Returns 0 if the key existed (and was dropped), -2 otherwise.
  {.cast(gcsafe).}:
    withLock reg.lock:
      let nameLen = cstrLen(name)
      let bucket = findBucket(reg, ctx, name, nameLen)
      if bucket.isNil:
        return -2'i32
      unlinkBucket(reg, bucket)
      disposeBucket(bucket)
      dec reg.entryCount
      return 0'i32

proc subsRegistryRemoveAllForKeyN*(
    reg: ptr SubsRegistry, ctx: uint32, name: cstring
): int32 {.gcsafe, raises: [].} =
  ## Returns the number of subscriptions removed (>= 0), or -2 if the key was
  ## not found. Teardown paths must decrement the shared per-event subs-count
  ## by the exact number removed (not reset to 0) so a sibling context/instance
  ## sharing the event name is not silenced.
  {.cast(gcsafe).}:
    withLock reg.lock:
      let nameLen = cstrLen(name)
      let bucket = findBucket(reg, ctx, name, nameLen)
      if bucket.isNil:
        return -2'i32
      let removed = int32(bucket.subsCount)
      unlinkBucket(reg, bucket)
      disposeBucket(bucket)
      dec reg.entryCount
      return removed

proc subsRegistrySnapshot*(
    reg: ptr SubsRegistry,
    ctx: uint32,
    name: cstring,
    bufOut: var ptr UncheckedArray[SubSnapshot],
    lenOut: var int,
) {.gcsafe, raises: [].} =
  ## Allocates a shared-heap array of `(cb, userData)` for the bucket. Sets
  ## `bufOut = nil`, `lenOut = 0` if there are no subscribers — callers should
  ## then skip `subsRegistrySnapshotFree`.
  bufOut = nil
  lenOut = 0
  {.cast(gcsafe).}:
    withLock reg.lock:
      let nameLen = cstrLen(name)
      let bucket = findBucket(reg, ctx, name, nameLen)
      if bucket.isNil or bucket.subsCount == 0:
        return
      let n = bucket.subsCount
      let bytes = sizeof(SubSnapshot) * n
      let buf = cast[ptr UncheckedArray[SubSnapshot]](allocShared0(bytes))
      var cur = bucket.subsHead
      var i = 0
      while not cur.isNil and i < n:
        buf[i].cb = cur.cb
        buf[i].userData = cur.userData
        cur = cur.next
        inc i
      bufOut = buf
      lenOut = i

proc subsRegistrySnapshotFree*(buf: ptr UncheckedArray[SubSnapshot]) {.inline.} =
  if not buf.isNil:
    deallocShared(buf)

proc subsRegistryFreeForCtx*(
    reg: ptr SubsRegistry, ctx: uint32
) {.gcsafe, raises: [].} =
  ## Drops every bucket whose `ctx` matches. Called from `_shutdown(ctx)`
  ## after the processing thread has been joined, so no concurrent delivery
  ## can race with this teardown.
  {.cast(gcsafe).}:
    withLock reg.lock:
      for i in 0 ..< reg.bucketsLen:
        var prev: ptr BucketHead = nil
        var cur = reg.buckets[i]
        while not cur.isNil:
          let nxt = cur.next
          if cur.ctx == ctx:
            if prev.isNil:
              reg.buckets[i] = nxt
            else:
              prev.next = nxt
            disposeBucket(cur)
            dec reg.entryCount
          else:
            prev = cur
          cur = nxt

type SubsFreedCb* = proc(name: cstring, count: int32) {.gcsafe, raises: [].}
  ## Invoked once per disposed bucket by `subsRegistryFreeForClass` with the
  ## bucket's event name and live subscription count, so the caller can
  ## decrement the matching per-event subs-count atomic.

proc subsRegistryFreeForClass*(
    reg: ptr SubsRegistry, classCtx: uint16, onFreed: SubsFreedCb
) {.gcsafe, raises: [].} =
  ## Drops every bucket whose ctx low16 == `classCtx` — the lib ctx itself
  ## (instanceCtx 0) plus every sub-instance sharing its classCtx. For each
  ## disposed bucket with live subs, invokes `onFreed(eventName, subsCount)`
  ## so the caller can decrement the shared per-event subs-count. Called from
  ## `_shutdown(libCtx)` after both threads are joined, so no concurrent
  ## delivery can race this teardown.
  {.cast(gcsafe).}:
    withLock reg.lock:
      for i in 0 ..< reg.bucketsLen:
        var prev: ptr BucketHead = nil
        var cur = reg.buckets[i]
        while not cur.isNil:
          let nxt = cur.next
          if (cur.ctx and 0x0000FFFF'u32) == uint32(classCtx):
            if not onFreed.isNil and cur.subsCount > 0:
              onFreed(cur.eventName, int32(cur.subsCount))
            if prev.isNil:
              reg.buckets[i] = nxt
            else:
              prev.next = nxt
            disposeBucket(cur)
            dec reg.entryCount
          else:
            prev = cur
          cur = nxt

{.pop.}

## Per-context event registry + bounded SPSC queue. FFI thread enqueues, event
## thread drains; payloads use c_malloc so they survive cross-thread heap reuse.

{.pragma: callback, cdecl, raises: [], gcsafe.}

import system/ansi_c
import std/[atomics, locks, sequtils, options, tables]
import chronicles
import ./ffi_types, ./cbor_serial, ./alloc

type EventEnvelope*[T] = object ## CBOR wire shape: { eventType: tstr, payload: <T> }.
  eventType*: string
  payload*: T

type
  FFIEventListener* = object
    id*: uint64
    callback*: FFICallBack
    userData*: pointer

  FFIEventRegistry* = object
    lock*: Lock
    nextId*: uint64 # 0 is reserved as "invalid"; ids start at 1.
    byEvent*: Table[string, seq[FFIEventListener]]

proc initEventRegistry*(reg: var FFIEventRegistry) =
  ## Run once on the owning thread before sharing (re-initLock is UB).
  reg.lock.initLock()
  reg.nextId = 0'u64
  reg.byEvent = initTable[string, seq[FFIEventListener]]()

proc deinitEventRegistry*(reg: var FFIEventRegistry) =
  ## Mirror of `initEventRegistry`; resets GC fields so slot reuse sees no dtor.
  reg.lock.deinitLock()
  reg.byEvent = default(Table[string, seq[FFIEventListener]])
  reg.nextId = 0'u64

proc clearListeners*(reg: var FFIEventRegistry) {.raises: [].} =
  ## Removes all listeners. The pool calls this when it recycles a context. The
  ## lock stays in place, because the event thread uses it across recycles.
  withLock reg.lock:
    reg.byEvent.clear()
    reg.nextId = 0'u64

proc addEventListener*(
    reg: var FFIEventRegistry,
    eventName: string,
    callback: FFICallBack,
    userData: pointer,
): uint64 {.raises: [].} =
  ## Returns the listener id (>0), or 0 if `callback` is nil.
  if callback.isNil():
    return 0

  var assigned: uint64 = 0

  withLock reg.lock:
    reg.nextId.inc()
    assigned = reg.nextId
    let listener =
      FFIEventListener(id: assigned, callback: callback, userData: userData)
    reg.byEvent.mgetOrPut(eventName, @[]).add(listener)
  assigned

proc removeEventListener*(reg: var FFIEventRegistry, id: uint64): bool {.raises: [].} =
  ## Safe from inside a dispatch; the in-flight snapshot still delivers once.
  if id == 0'u64:
    return false

  var removed = false

  withLock reg.lock:
    var
      pruneKey = ""
      prune = false
    for key, listeners in reg.byEvent.mpairs:
      let before = listeners.len
      listeners.keepItIf(it.id != id)
      if listeners.len < before:
        removed = true
        if listeners.len == 0:
          pruneKey = key
          prune = true
        break
    if prune:
      reg.byEvent.del(pruneKey)
  removed

proc removeAllEventListeners*(reg: var FFIEventRegistry) {.raises: [].} =
  ## Does not reset the id counter.
  withLock reg.lock:
    reg.byEvent.clear()

proc snapshotListeners*(
    reg: var FFIEventRegistry, eventName: string
): seq[FFIEventListener] {.raises: [].} =
  ## Lock held only across the copy so re-entrant add/remove can't deadlock.
  var listeners: seq[FFIEventListener] = @[]
  withLock reg.lock:
    for l in reg.byEvent.getOrDefault(eventName):
      listeners.add(l)
  listeners

const EventQueueCapacity* {.intdefine.} = 1024
  ## Sustained backlog here means a listener is wedged. Override `-d:EventQueueCapacity=N`.

const MaxEventPayloadBytes* {.intdefine.} = 512
  ## Per-slot payload slab; larger payloads take a one-off c_malloc freed on
  ## commit. Override `-d:MaxEventPayloadBytes=N`.

const MaxEventNameBytes* {.intdefine.} = 64
  ## Per-slot name slab (incl. NUL); longer names take the heap fallback.
  ## Override `-d:MaxEventNameBytes=N`.

const emptyListenerPayload*: cstring = ""
  ## Non-nil zero-length stand-in for empty payloads/names (nil would be UB for
  ## consumers doing memcpy even at len 0).

type
  QueuedEvent* = object
    # `name`/`data` point into reused per-slot buffers, or a one-off c_malloc marked by `*HeapOwned` when oversize; both c_malloc'd so they outlive the FFI thread's heap.
    name*: cstring
    nameHeapOwned*: bool
    data*: ptr UncheckedArray[byte]
    dataLen*: int
    dataHeapOwned*: bool

  EventQueue* = object # SPSC ring; plain lock since ops are short and uncontended.
    lock*: Lock
    head*: int
    tail*: int
    count*: int
    buf*: array[EventQueueCapacity, QueuedEvent]
    slab*: array[EventQueueCapacity, ptr UncheckedArray[byte]]
    nameSlab*: array[EventQueueCapacity, ptr UncheckedArray[byte]]

proc allocSlot(nbytes: int): ptr UncheckedArray[byte] {.raises: [].} =
  if nbytes <= 0:
    return nil
  cast[ptr UncheckedArray[byte]](c_malloc(csize_t(nbytes)))

proc initEventQueue*(q: var EventQueue) {.raises: [].} =
  q.lock.initLock()
  q.head = 0
  q.tail = 0
  q.count = 0
  for i in 0 ..< EventQueueCapacity:
    q.buf[i] = QueuedEvent()
    q.slab[i] = allocSlot(MaxEventPayloadBytes)
    q.nameSlab[i] = allocSlot(MaxEventNameBytes)

proc releaseEvent*(qe: QueuedEvent) {.raises: [], gcsafe.} =
  ## Frees only heap-fallback buffers; reused slot buffers persist.
  if qe.nameHeapOwned and not qe.name.isNil():
    c_free(cast[pointer](qe.name))
  if qe.dataHeapOwned and not qe.data.isNil():
    c_free(qe.data)

proc deinitEventQueue*(q: var EventQueue) {.raises: [].} =
  ## Both producer and consumer must have stopped.
  for i in 0 ..< EventQueueCapacity:
    releaseEvent(q.buf[i])
    q.buf[i] = QueuedEvent()
    if not q.slab[i].isNil():
      c_free(q.slab[i])
      q.slab[i] = nil
    if not q.nameSlab[i].isNil():
      c_free(q.nameSlab[i])
      q.nameSlab[i] = nil
  q.head = 0
  q.tail = 0
  q.count = 0
  q.lock.deinitLock()

proc copyIntoSlot(
    slot: ptr UncheckedArray[byte], slotCap, nbytes: int, src: pointer
): tuple[buf: ptr UncheckedArray[byte], heap: bool, ok: bool] {.raises: [].} =
  ## Copies into `slot` when it fits, else a one-off c_malloc; `ok=false` only on
  ## alloc failure.
  if nbytes <= 0:
    return (nil, false, true)
  if nbytes <= slotCap and not slot.isNil():
    copyMem(slot, src, nbytes)
    return (slot, false, true)
  let heapBuf = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(nbytes)))
  if heapBuf.isNil():
    return (nil, false, false)
  copyMem(heapBuf, src, nbytes)
  (heapBuf, true, true)

proc tryEnqueueEvent*(
    q: var EventQueue, name: cstring, src: pointer, dataLen: int
): bool {.raises: [], gcsafe.} =
  ## Copies `name` (NUL included) and payload into the tail slot's reused buffers
  ## or a heap fallback; false when the ring is full or a fallback alloc fails.
  withLock q.lock:
    if q.count >= EventQueueCapacity:
      return false
    let slot = q.tail
    # Include the NUL so the stored copy stays a valid cstring.
    let nameBytes =
      if name.isNil():
        0
      else:
        name.len + 1
    let nameRes =
      copyIntoSlot(q.nameSlab[slot], MaxEventNameBytes, nameBytes, cast[pointer](name))
    if not nameRes.ok:
      return false
    let dataRes = copyIntoSlot(q.slab[slot], MaxEventPayloadBytes, dataLen, src)
    if not dataRes.ok:
      if nameRes.heap:
        c_free(nameRes.buf)
      return false
    let nameCStr =
      if nameRes.buf.isNil():
        emptyListenerPayload
      else:
        cast[cstring](nameRes.buf)
    q.buf[slot] = QueuedEvent(
      name: nameCStr,
      nameHeapOwned: nameRes.heap,
      data: dataRes.buf,
      dataLen: dataLen,
      dataHeapOwned: dataRes.heap,
    )
    q.tail = (q.tail + 1) mod EventQueueCapacity
    q.count.inc()
  true

proc peekEvent*(q: var EventQueue): Option[QueuedEvent] {.raises: [], gcsafe.} =
  ## Returns the head without advancing (slot stays pinned so the producer can't
  ## reuse it mid-read); pair each non-none peek with a `commitDequeue`.
  withLock q.lock:
    if q.count == 0:
      return none(QueuedEvent)
    return some(q.buf[q.head])

proc commitDequeue*(q: var EventQueue) {.raises: [], gcsafe.} =
  ## Retires the dispatched head slot: frees any heap fallback and frees the slot.
  withLock q.lock:
    if q.count == 0:
      return
    releaseEvent(q.buf[q.head])
    q.buf[q.head] = QueuedEvent()
    q.head = (q.head + 1) mod EventQueueCapacity
    q.count.dec()

proc eventQueueLen*(q: var EventQueue): int {.raises: [], gcsafe.} =
  withLock q.lock:
    return q.count

proc notifyListeners*(
    listeners: seq[FFIEventListener], retCode: cint, data: pointer, dataLen: int
) =
  ## Empty payloads use `emptyListenerPayload` so consumers never see a nil ptr.
  let n = max(dataLen, 0)
  let dataPtr =
    if n > 0 and not data.isNil():
      cast[ptr cchar](data)
    else:
      cast[ptr cchar](emptyListenerPayload)
  for listener in listeners:
    listener.callback(retCode, dataPtr, cast[csize_t](n), listener.userData)

proc notifyListenersErr*(listeners: seq[FFIEventListener], msg: string) =
  let p =
    if msg.len > 0:
      cast[pointer](unsafeAddr msg[0])
    else:
      cast[pointer](emptyListenerPayload)
  notifyListeners(listeners, RET_ERR, p, msg.len)

var ffiCurrentEventRegistry* {.threadvar.}: ptr FFIEventRegistry

var ffiCurrentEventQueue* {.threadvar.}: ptr EventQueue
  # Installed by the FFI thread so dispatch templates need no `ctx`.

var ffiCurrentEventQueueStuck* {.threadvar.}: ptr Atomic[bool]
  # Sticky overflow flag; FFI request entry point reads it to reject.

var ffiCurrentNotifyEventEnqueued* {.threadvar.}: proc() {.gcsafe, raises: [].}
  # Wake hook so this module needn't depend on chronos; nil-safe.

template enqueueOrMarkStuck(eventName: string, src: pointer, dataLen: int) =
  ## Enqueues into the reused slot buffers; on queue-full sets the sticky stuck
  ## flag and wakes the event thread (firing onNotResponding here could deadlock).
  block enqueueBlock:
    let q = ffiCurrentEventQueue
    if q.isNil():
      chronicles.error "event queue not set on this thread", event = eventName
      break enqueueBlock
    if not q[].tryEnqueueEvent(cstring(eventName), src, dataLen):
      chronicles.error "event queue full; library marked stuck",
        event = eventName, capacity = EventQueueCapacity
      if not ffiCurrentEventQueueStuck.isNil():
        ffiCurrentEventQueueStuck[].store(true)
      if not ffiCurrentNotifyEventEnqueued.isNil():
        ffiCurrentNotifyEventEnqueued()
      break enqueueBlock
    if not ffiCurrentNotifyEventEnqueued.isNil():
      ffiCurrentNotifyEventEnqueued()

template dispatchFFIEvent*(eventName: string, body: untyped) =
  ## `body` yields string/seq[byte]. FFI thread only: enqueues; event thread fans out.
  block:
    let evtName: string = eventName
    let bodyVal = body
    let dataLen = bodyVal.len
    let src: pointer =
      if dataLen > 0:
        unsafeAddr bodyVal[0]
      else:
        nil
    enqueueOrMarkStuck(evtName, src, dataLen)

template dispatchFFIEventCbor*(eventName: string, eventPayload: typed) =
  ## Typed CBOR variant; param is `eventPayload` to avoid clobbering
  ## `EventEnvelope.payload` substitution.
  block:
    let evtName: string = eventName
    let encoded = cborEncode(
      EventEnvelope[typeof(eventPayload)](eventType: evtName, payload: eventPayload)
    )
    let src: pointer =
      if encoded.len > 0:
        unsafeAddr encoded[0]
      else:
        nil
    enqueueOrMarkStuck(evtName, src, encoded.len)

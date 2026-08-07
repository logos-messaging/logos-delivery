## api_cbor_event_courier — fire-and-forget ring for CBOR FFI event delivery.
## ============================================================================
## Part D-3 of the CBOR refactoring (doc/CBOR_Round2_PartD_EventCourier.md).
##
## A CBOR-mode event emitted by a provider on the processing thread needs to
## fan out to all foreign-callback subscribers without blocking the provider.
## The shape is the mirror image of `api_cbor_courier`:
##
##   producer (processing thread)
##     1. CBOR-encode the event payload **once** into a shared-heap buffer,
##     2. enqueue an `EventMsg` carrying `(eventName, ctx, buf, bufLen)`
##        — ownership of `buf` transfers to the consumer,
##     3. wake the delivery thread via its broker dispatch signal.
##
##   consumer (delivery thread, via `registerBrokerPoller`)
##     1. dequeue messages from the ring,
##     2. snapshot the foreign-subscriber list for `(ctx, eventName)`,
##     3. invoke each foreign callback synchronously,
##     4. free the buffer.
##
## Differences from `api_cbor_courier`:
##   - **No response slots, no `inFlight` counter** — events are
##     fire-and-forget. Producers do not block, do not wait for a reply.
##   - Ring is sized for **burst capacity** (default 256), not for
##     concurrent in-flight count. A full ring drops the event with a
##     diagnostic (logged by the caller) — appropriate for the
##     fire-and-forget contract.
##   - `eventName` is carried inline as a fixed-size NUL-terminated
##     ASCII buffer (same convention as `CborCallMsg.apiName`) so the
##     message stays POD — zero GC involvement on the producer side.
##
## This module is plain runtime code (NOT codegen) used by the generated
## library runtime in `api_library.nim`.

{.push raises: [].}

import std/[locks, monotimes]

const CborEventNameMax* = 256
  ## Inline fixed-size buffer for the ASCII event name carried in a
  ## courier message. Same value as `CborApiNameMax` — every event name
  ## the CBOR-mode subscribe surface accepts already fits within this
  ## bound (the wrapper validates name length).

type
  CborEventMsg* = object
    ## Pure-POD message handed from the processing thread (producer) to
    ## the delivery thread (consumer). No Nim `string` / `seq` / `ref`
    ## crosses the channel — the producer encoded the payload into a
    ## shared-heap buffer and transfers ownership of it via `buf`.
    eventName*: array[CborEventNameMax, char] ## NUL-terminated ASCII
    ctx*: uint32 ## BrokerContext.uint32; identifies the per-ctx sub list
    buf*: pointer
      ## `allocShared0`; ownership transferred to the consumer.
      ## The consumer frees this exactly once after the fan-out completes.
    bufLen*: int32

  CborEventRing* = object
    ## Single-lock POD-element ring, allocated wholly in shared heap.
    ## Same shape (and same rationale) as `CborCallRing` —
    ## `system.Channel[T]` is avoided to keep the storage out of the
    ## producer thread's per-thread Nim allocator (would leak/UAF when
    ## the producer thread exits before the consumer fully drains).
    buf: ptr UncheckedArray[CborEventMsg]
    cap: int
    origCap: int ## set once at construction; growth ceiling is `4 * origCap`
    head: int ## next index the consumer reads
    tail: int ## next index a producer writes
    count: int ## guarded by `lock`
    lock: Lock

  CborEventDropAccount* = object
    ## Throttle state for the "events dropped on a full ring" warn log.
    ## Touched ONLY by the producer (the single processing thread that runs
    ## the generated emit handler) — both when a drop is recorded and when the
    ## courier is constructed. That single-thread invariant (the same one the
    ## emit path already relies on) is why no lock guards these fields.
    totalDropped*: int64 ## cumulative dropped since courier creation
    sinceLastLog*: int64 ## dropped since the last emitted log line
    nextCountThreshold*: int64 ## count that triggers the next count-based line
    lastLogMonoMs*: int64 ## monotonic ms of the last emitted line (0 = never)
    everLogged*: bool ## has any line been emitted yet (first-drop guard)

  CborEventCourier* = object
    ## One per library context. Lives in shared heap; created in
    ## `_createContext`, freed in `_shutdown` **after both threads have
    ## joined**. The teardown sequence drains any messages still in the
    ## ring (freeing their `buf`s) before deallocating the ring storage.
    ring*: CborEventRing
    dropAccount*: CborEventDropAccount ## producer-thread-only; see above

# ---------------------------------------------------------------------------
# Drop diagnostics — throttled accounting for events dropped on a full ring.
#
# The decision of WHETHER to log lives here (pure, single-threaded, testable);
# the actual `warn` is emitted by the generated caller in `api_library.nim`,
# which owns the chronicles topic and the event name. The cadence is:
#   * the FIRST drop ever always logs, then
#   * a geometric count backoff (1, 10, 100, 1000 … drops since the last line),
#   * plus a periodic floor so a steady stall keeps reporting on a timer.
# ---------------------------------------------------------------------------

const
  CborEventDropLogPeriodMs* = 5000'i64
    ## Once a drop episode is underway, emit at most one line per this period…
  CborEventDropFirstThreshold* = 10'i64
    ## …or sooner, once this many drops accrue since the last line…
  CborEventDropThresholdGrow* = 10'i64
    ## …with the count threshold multiplied by this each time it fires.
  CborEventDropMaxThreshold* = 1_000_000'i64
    ## Ceiling so the geometric backoff can't outgrow int64-sane spacing.

proc initCborEventDropAccount*(): CborEventDropAccount =
  ## A fresh account. `allocShared0` zeroes the courier, so the only field that
  ## must start non-zero is the first count threshold.
  CborEventDropAccount(nextCountThreshold: CborEventDropFirstThreshold)

proc monoNowMs*(): int64 {.gcsafe.} =
  ## Monotonic clock in milliseconds; used only to space out drop logs, so the
  ## epoch is irrelevant — only differences matter. `ticks` is nanoseconds.
  getMonoTime().ticks div 1_000_000

proc recordDrop*(
    acct: var CborEventDropAccount,
    nowMonoMs: int64,
    totalOut: var int64,
    sinceOut: var int64,
): bool =
  ## Record one dropped event and decide whether the caller should emit a warn
  ## line now. Returns true on: the first drop ever, every time the growing
  ## count threshold is crossed, or once `CborEventDropLogPeriodMs` has elapsed
  ## since the last line. On a true result `totalOut`/`sinceOut` carry the
  ## numbers to print and the throttle state is advanced.
  inc acct.totalDropped
  inc acct.sinceLastLog
  let firstEver = not acct.everLogged
  let countHit = acct.sinceLastLog >= acct.nextCountThreshold
  let timeHit =
    acct.everLogged and (nowMonoMs - acct.lastLogMonoMs) >= CborEventDropLogPeriodMs
  if not (firstEver or countHit or timeHit):
    return false
  totalOut = acct.totalDropped
  sinceOut = acct.sinceLastLog
  acct.everLogged = true
  acct.lastLogMonoMs = nowMonoMs
  acct.sinceLastLog = 0
  if countHit:
    acct.nextCountThreshold = min(
      acct.nextCountThreshold * CborEventDropThresholdGrow, CborEventDropMaxThreshold
    )
  true

func ringCap*(c: ptr CborEventCourier): int =
  ## Current ring capacity — exposed for the drop-diagnostic log (the ring's
  ## fields are otherwise private). Read-only; not a thread-safe snapshot, but
  ## `cap` only ever grows and the value is for human-readable context.
  c.ring.cap

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc newCborEventCourier*(ringCap: int): ptr CborEventCourier =
  ## Allocate an event courier sized for `ringCap` outstanding events.
  ## Producers that find the ring full drop the event (events are
  ## fire-and-forget). Pick `ringCap` generously — there's no slot pool
  ## gating it the way `CborCourier`'s slot count gates its ring.
  let c = cast[ptr CborEventCourier](allocShared0(sizeof(CborEventCourier)))
  c.ring.buf =
    cast[ptr UncheckedArray[CborEventMsg]](allocShared0(ringCap * sizeof(CborEventMsg)))
  c.ring.cap = ringCap
  c.ring.origCap = ringCap
  c.ring.head = 0
  c.ring.tail = 0
  c.ring.count = 0
  initLock(c.ring.lock)
  c.dropAccount = initCborEventDropAccount()
  c

proc drainAndFree*(c: ptr CborEventCourier) =
  ## Free any messages still in the ring (deallocating their `buf`),
  ## then free the ring storage and the courier itself. MUST be called
  ## only after both the producer and consumer threads have joined.
  if c.isNil:
    return
  # Drain remaining messages — buffers must be freed exactly once.
  acquire(c.ring.lock)
  while c.ring.count > 0:
    let m = c.ring.buf[c.ring.head]
    if not m.buf.isNil:
      deallocShared(m.buf)
    c.ring.head = (c.ring.head + 1) mod c.ring.cap
    dec c.ring.count
  release(c.ring.lock)
  deinitLock(c.ring.lock)
  if not c.ring.buf.isNil:
    deallocShared(c.ring.buf)
  deallocShared(c)

# ---------------------------------------------------------------------------
# Ring — single-lock MPSC over a fixed-size POD slot array.
# ---------------------------------------------------------------------------

proc tryEnqueue*(r: ptr CborEventRing, msg: CborEventMsg): bool =
  ## Multi-producer (though in practice the producer is the single
  ## processing thread). Returns false on full — the caller is
  ## responsible for freeing `msg.buf` in that case (the buffer never
  ## entered the ring, so the ring never took ownership).
  acquire(r.lock)
  if r.count >= r.cap:
    # Full: grow by doubling, up to a hard ceiling of `4 * origCap`. At the
    # ceiling retain the fire-and-forget drop contract.
    let newCap = min(r.cap * 2, r.origCap * 4)
    if newCap == r.cap:
      release(r.lock)
      return false
    let newBuf = cast[ptr UncheckedArray[CborEventMsg]](allocShared0(
      newCap * sizeof(CborEventMsg)
    ))
    if newBuf.isNil:
      # OOM: keep the existing buffer untouched and fall back to the drop
      # contract (same as hitting the ceiling) rather than dereferencing nil.
      release(r.lock)
      return false
    for i in 0 ..< r.count:
      newBuf[i] = r.buf[(r.head + i) mod r.cap]
    deallocShared(r.buf)
    r.buf = newBuf
    r.head = 0
    r.tail = r.count
    r.cap = newCap
  r.buf[r.tail] = msg
  r.tail = (r.tail + 1) mod r.cap
  inc r.count
  release(r.lock)
  true

proc tryDequeue*(r: ptr CborEventRing, dst: var CborEventMsg): bool =
  ## Single consumer (the delivery thread's event-courier poller).
  ## Returns false on empty. Ownership of `dst.buf` transfers to the
  ## caller — they must `deallocShared` it after the fan-out.
  acquire(r.lock)
  if r.count == 0:
    release(r.lock)
    return false
  dst = r.buf[r.head]
  r.head = (r.head + 1) mod r.cap
  dec r.count
  release(r.lock)
  true

{.pop.}

## Event-thread body and FFI-thread liveness monitoring. Included from
## `ffi_context.nim`. Drains queued events into listeners and emits
## NotResponding/Responding on FFI-heartbeat stall/recovery.

type
  NotRespondingEvent* = object
  RespondingEvent* = object

const
  NotRespondingEventName* = "not_responding"
  RespondingEventName* = "responding"

proc dispatchToListeners[T](
    ctx: ptr FFIContext[T], eventName: string, data: pointer, dataLen: int
) =
  ## Holds reg.lock across snapshot + invocation so concurrent add/remove blocks
  ## until dispatch returns.
  withLock ctx[].eventRegistry.lock:
    let listeners = ctx[].eventRegistry.byEvent.getOrDefault(eventName)
    if listeners.len == 0:
      chronicles.debug "no listener registered", event = eventName
      return
    foreignThreadGc:
      try:
        notifyListeners(listeners, RET_OK, data, dataLen)
      except Exception, CatchableError:
        notifyListenersErr(
          listeners,
          "Exception dispatching " & eventName & ": " & getCurrentExceptionMsg(),
        )

proc emitLivenessEvent[T, P](ctx: ptr FFIContext[T], name: string, payload: P) =
  ## Dispatches directly to listeners, bypassing the (possibly wedged) queue.
  let event =
    try:
      EventEnvelope[P](eventType: name, payload: payload).cborEncode()
    except CatchableError as e:
      chronicles.error "liveness event encode failed", name = name, err = e.msg
      return
  let dataPtr: pointer =
    if event.len > 0:
      cast[pointer](unsafeAddr event[0])
    else:
      cast[pointer](emptyListenerPayload)
  ctx.dispatchToListeners(name, dataPtr, event.len)

proc onNotResponding*(ctx: ptr FFIContext) =
  emitLivenessEvent(ctx, NotRespondingEventName, NotRespondingEvent())

proc onResponding*(ctx: ptr FFIContext) =
  ## Fired once when the heartbeat resumes after a NotRespondingEvent.
  emitLivenessEvent(ctx, RespondingEventName, RespondingEvent())

proc dispatchQueuedEvent[T](ctx: ptr FFIContext[T], qe: QueuedEvent) =
  ## Reads the borrowed slab payload; `commitDequeue` frees any heap fallback.
  ctx.dispatchToListeners($qe.name, qe.data, qe.dataLen)

proc drainOneEvent[T](ctx: ptr FFIContext[T]): bool =
  ## Peek → dispatch → commit; slot stays pinned across dispatch, `defer` commits
  ## even if a listener raises. False when the queue is empty.
  let opt = ctx.eventQueue.peekEvent()
  if opt.isNone():
    return false
  defer:
    ctx.eventQueue.commitDequeue()
  ctx.dispatchQueuedEvent(opt.get())
  true

proc drainEventQueue[T](ctx: ptr FFIContext[T]) =
  while ctx.drainOneEvent():
    discard

type HeartbeatMonitor = object
  startedAt: Moment
  lastChange: Moment
  lastValue: int64
  notifiedStale: bool

proc init(T: type HeartbeatMonitor, ctx: ptr FFIContext): T =
  let now = Moment.now()
  T(
    startedAt: now,
    lastChange: now,
    lastValue: ctx.ffiHeartbeat.load(),
    notifiedStale: false,
  )

proc check[T](hb: var HeartbeatMonitor, ctx: ptr FFIContext[T]) =
  ## Fires onNotResponding/onResponding on stall/recovery; each latches once per episode.
  if Moment.now() - hb.startedAt <= FFIHeartbeatStartDelay:
    return
  let cur = ctx.ffiHeartbeat.load()
  if cur != hb.lastValue:
    if hb.notifiedStale:
      onResponding(ctx)
    hb.lastValue = cur
    hb.lastChange = Moment.now()
    hb.notifiedStale = false
  elif not hb.notifiedStale and Moment.now() - hb.lastChange > FFIHeartbeatStaleThreshold:
    onNotResponding(ctx)
    hb.notifiedStale = true

proc eventRun[T](ctx: ptr FFIContext[T]) {.async.} =
  var hb = HeartbeatMonitor.init(ctx)
  var notifiedStuck = false # latched forever — eventQueueStuck is sticky terminal.

  # Keep draining after `running` flips false until the FFI thread exits, so events from an async {.ffiDtor.} teardown are still dispatched.
  while ctx.running.load() or not ctx.ffiThreadExited.load():
    discard await ctx.eventQueueSignal.wait().withTimeout(EventThreadTickInterval)

    ctx.drainEventQueue()

    # Liveness only while running; skip during the teardown drain.
    if ctx.running.load():
      # Fire after drain so reg.lock is free (FFI thread would deadlock here).
      if not notifiedStuck and ctx.eventQueueStuck.load():
        onNotResponding(ctx)
        notifiedStuck = true
      hb.check(ctx)

  # Catch anything enqueued between the last drain and the FFI thread's exit.
  ctx.drainEventQueue()

proc eventThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## Drains the event queue and runs the FFI-thread heartbeat check.
  defer:
    let fireRes = ctx.eventThreadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire eventThreadExitSignal", err = fireRes.error

  try:
    waitFor eventRun(ctx)
  except CatchableError as e:
    error "event thread exited with exception", error = e.msg

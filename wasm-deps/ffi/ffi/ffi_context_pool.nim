import std/[atomics, sysatomics]
import results
import ./ffi_context

const MaxFFIContexts* = 32

type
  StaticCtxState = enum
    ## Lifecycle of the pool's `{.ffiStatic.}` context; see `staticFFIContext`.
    StaticCtxNone
    StaticCtxCreating
    StaticCtxDestroying
    StaticCtxReady

  FFIContextPool*[T] = object
    ## Fixed pool of FFI contexts, plus the one `{.ffiStatic.}` context. Each
    ## slot's worker + event threads and signal fds are built once (on first
    ## use) and reused across create/recycle cycles — recycle keeps them alive,
    ## so repeated create/destroy does not churn fds. Bounds ThreadSignalPtr fds
    ## at MaxFFIContexts * (signals per ctx).
    contexts: array[MaxFFIContexts, FFIContext[T]]
    initialized: array[MaxFFIContexts, Atomic[bool]]
    staticCtx: Atomic[pointer]
    staticState: Atomic[StaticCtxState]

proc releaseSlot[T](pool: var FFIContextPool[T], ctx: ptr FFIContext[T]) =
  ## Full-teardown release: the slot must be rebuilt before it serves again.
  for i in 0 ..< MaxFFIContexts:
    if pool.contexts[i].addr == ctx:
      pool.initialized[i].store(false)
      break
  ctx.releaseClaim()

proc createFFIContext*[T](
    pool: var FFIContextPool[T]
): Result[ptr FFIContext[T], string] =
  ## Acquires a context from the fixed pool. A slot's worker is built once on
  ## first use and reused (markAsActive) on every later acquisition.
  for i in 0 ..< MaxFFIContexts:
    let ctx = pool.contexts[i].addr
    if not ctx.tryClaim():
      continue
    if pool.initialized[i].load():
      # Reused slot: a prior recycle drained and released it; worker still alive.
      ctx.markAsActive()
      return ok(ctx)
    initContextResources(ctx).isOkOr:
      ctx.releaseClaim()
      return err("createFFIContext: initContextResources failed: " & $error)
    pool.initialized[i].store(true)
    return ok(ctx)
  err("FFI context pool exhausted (max " & $MaxFFIContexts & " contexts)")

proc isStaticCtx[T](pool: var FFIContextPool[T], ctx: ptr FFIContext[T]): bool =
  ## True while `ctx` is the pool's static context, including mid-teardown.
  # `staticCtx` is cleared only once the slot is released, so matching on the
  # pointer covers `Destroying` too.
  pool.staticCtx.load() == cast[pointer](ctx)

proc recycleFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## Normal teardown: drains in-flight handlers, frees the lib and returns the
  ## slot to the pool WITHOUT stopping its threads, so a later createFFIContext
  ## reuses them. Synchronous (waits for the FFI thread to finish draining).
  # Recycling it would release the slot while `staticState` still points at it.
  if pool.isStaticCtx(ctx):
    return err("recycleFFIContext(pool): the {.ffiStatic.} context outlives every ctx")
  ctx.requestRecycle()

proc destroyFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## Full teardown: stops/joins the threads and frees resources, marking the slot
  ## uninitialised so a later createFFIContext rebuilds it; normal cleanup uses
  ## recycleFFIContext. On thread-exit timeout the slot is leaked; closing
  ## live-thread resources is unsafe.
  # Destroying it would release the slot while `staticState` still points at it.
  if pool.isStaticCtx(ctx):
    return err("destroyFFIContext(pool): the {.ffiStatic.} context outlives every ctx")
  ctx.stopAndJoinThreads().isOkOr:
    return err("destroyFFIContext(pool): " & $error)
  let deinitRes = ctx.deinitContextResources()
  pool.releaseSlot(ctx)
  deinitRes.isOkOr:
    return err("destroyFFIContext(pool): " & $error)
  ok()

proc staticFFIContext*[T](
    pool: var FFIContextPool[T]
): Result[ptr FFIContext[T], string] =
  ## The pool's `{.ffiStatic.}` context, created on first use: a static proc has
  ## no ctx of its own, but its handler still needs an FFI thread.
  # Holds its slot until `destroyStaticFFIContext`, so `pool` must outlive its
  # threads: only call this on the global `declareLibrary` emits. `myLib` stays
  # the zero value. A failed create resets to `StaticCtxNone` so waiters retry.
  while true:
    case pool.staticState.load()
    of StaticCtxReady:
      return ok(cast[ptr FFIContext[T]](pool.staticCtx.load()))
    of StaticCtxCreating, StaticCtxDestroying:
      cpuRelax()
    of StaticCtxNone:
      var expected = StaticCtxNone
      if not pool.staticState.compareExchange(expected, StaticCtxCreating):
        continue
      let ctx = pool.createFFIContext().valueOr:
        pool.staticState.store(StaticCtxNone)
        return err("staticFFIContext: " & error)
      pool.staticCtx.store(cast[pointer](ctx))
      pool.staticState.store(StaticCtxReady)
      return ok(ctx)

proc destroyStaticFFIContext*[T](pool: var FFIContextPool[T]): Result[void, string] =
  ## Teardown counterpart to `staticFFIContext`: stops the static context's
  ## threads and frees its slot. A no-op when there is no static context.
  # Claiming `Ready -> Destroying` serialises concurrent teardowns; it does not
  # make teardown safe against a static call already in flight.
  var expected = StaticCtxReady
  if not pool.staticState.compareExchange(expected, StaticCtxDestroying):
    return ok()
  let ctx = cast[ptr FFIContext[T]](pool.staticCtx.load())
  ctx.stopAndJoinThreads().isOkOr:
    # Threads are still live: leak the slot rather than free resources under them.
    pool.staticState.store(StaticCtxReady)
    return err("destroyStaticFFIContext: " & $error)
  let deinitRes = ctx.deinitContextResources()
  pool.releaseSlot(ctx)
  pool.staticCtx.store(nil)
  pool.staticState.store(StaticCtxNone)
  deinitRes.isOkOr:
    return err("destroyStaticFFIContext: " & $error)
  ok()

proc isValidCtx*[T](pool: var FFIContextPool[T], ctx: pointer): bool =
  ## Rejects nil / dangling pointers at the API boundary.
  if ctx.isNil():
    return false
  for i in 0 ..< MaxFFIContexts:
    if cast[pointer](pool.contexts[i].addr) == ctx:
      return pool.contexts[i].addr.isInUse()
  false

{.push raises: [].}

import std/[strutils, concurrency/atomics], chronos

type BrokerContext* = distinct uint32

func `==`*(a, b: BrokerContext): bool =
  uint32(a) == uint32(b)

func `!=`*(a, b: BrokerContext): bool =
  uint32(a) != uint32(b)

func `$`*(bc: BrokerContext): string =
  toHex(uint32(bc), 8)

# ---------------------------------------------------------------------------
# Context split — a BrokerContext packs two uint16 halves:
#   bits [15:0]  classCtx     — which broker-object/interface scope ("global"
#                               context). 0 = reserved (nil/invalid), 1 = the
#                               default base scope, 2..0xFFFE = allocated,
#                               0xFFFF = reserved guard.
#   bits [31:16] instanceCtx  — which instance of that scope. 0 = flat /
#                               class-level (no specific instance), 1..0xFFFF =
#                               OOP-owned instances.
# Bucket lookup remains keyed by the full uint32; the split is semantic.
# ---------------------------------------------------------------------------

func classCtx*(bc: BrokerContext): uint16 =
  uint16(uint32(bc) and 0xFFFF'u32)

func instanceCtx*(bc: BrokerContext): uint16 =
  uint16((uint32(bc) shr 16) and 0xFFFF'u32)

func makeBrokerContext*(classCtx, instanceCtx: uint16): BrokerContext =
  BrokerContext((uint32(instanceCtx) shl 16) or uint32(classCtx))

const DefaultBrokerContext* = makeBrokerContext(1'u16, 0'u16)
  ## 0x0000_0001 —
  ## the base "global" flat scope (classCtx 1, instance 0). Deliberately not
  ## 0x0 so an unset/nil context is distinguishable from the default.

# ---------------------------------------------------------------------------
# Thread-global broker context
# ---------------------------------------------------------------------------
#
# Each thread has its own BrokerContext value (threadvar).
# Defaults to DefaultBrokerContext until explicitly set via
# setThreadBrokerContext or initThreadBrokerContext.
#
# NOTE: Module-level threadvar assignments only execute on the main thread.
# Secondary threads get zero-initialized threadvars, so we use a flag to
# lazily initialize on first access.

var globalBrokerContextLock {.threadvar.}: AsyncLock
globalBrokerContextLock = newAsyncLock()
var globalBrokerContextValue {.threadvar.}: BrokerContext
globalBrokerContextValue = DefaultBrokerContext
var globalBrokerContextInitialized {.threadvar.}: bool
globalBrokerContextInitialized = true # main thread is initialized

proc threadGlobalBrokerContext*(): BrokerContext =
  ## Returns the currently active broker context for this thread.
  ##
  ## Defaults to `DefaultBrokerContext` until explicitly set via
  ## `setThreadBrokerContext` or `initThreadBrokerContext`.
  ## Lock-free threadvar read — safe to call from anywhere.
  if not globalBrokerContextInitialized:
    globalBrokerContextValue = DefaultBrokerContext
    globalBrokerContextInitialized = true
  globalBrokerContextValue

# Backward-compatible alias
template globalBrokerContext*(): BrokerContext =
  threadGlobalBrokerContext()

var gClassCtxCounter: Atomic[uint32]

proc newClassCtx*(): uint16 =
  ## Allocate a fresh, process-unique classCtx (the low-16 "global" scope id).
  ## Shared by flat `NewBrokerContext` and the OOP interface-class registration
  ## so every classCtx is unique. Starts at 2 (0 = nil, 1 = default scope).
  let id = gClassCtxCounter.fetchAdd(1, moRelaxed) + 2'u32
  doAssert id < 0xFFFF'u32, "BrokerContext classCtx space exhausted (max 65534)"
  uint16(id)

proc NewBrokerContext*(): BrokerContext =
  ## A flat "global" context: a fresh classCtx with instanceCtx 0.
  makeBrokerContext(newClassCtx(), 0'u16)

var gInstanceCtxCounter: Atomic[uint32]

proc newInstanceCtx*(parentCtx: BrokerContext): BrokerContext =
  ## Allocate a sub-instance context that SHARES `parentCtx`'s classCtx (so it
  ## routes to the same library context — same processing/delivery thread and
  ## courier) but carries a fresh, process-unique instanceCtx (high16).
  ##
  ## Used by create-instance FFI requests (reduced-A): a sub-interface instance
  ## lives on the main library's processing thread, so it must share the library
  ## classCtx. `<lib>_call` masks the instanceCtx off to find the courier, then
  ## dispatches against the full sub ctx so the provider keyed by it is hit.
  ## The counter is process-monotonic, so two sub-instances under the same
  ## library never collide on instanceCtx.
  let id = gInstanceCtxCounter.fetchAdd(1, moRelaxed) + 1'u32
  doAssert id < 0x1_0000'u32, "BrokerContext instanceCtx space exhausted (max 65535)"
  makeBrokerContext(classCtx(parentCtx), uint16(id))

# ---------------------------------------------------------------------------
# Sync thread-context binding (usable from {.thread.} init, before event loop)
# ---------------------------------------------------------------------------

proc setThreadBrokerContext*(ctx: BrokerContext) =
  ## Installs an existing BrokerContext as this thread's global broker context.
  ##
  ## Use when the context was created elsewhere (e.g. on the main thread)
  ## and this thread should adopt it. Readable via `threadGlobalBrokerContext()`.
  ##
  ## This is sync and thread-safe (writes only to this thread's threadvar).
  globalBrokerContextValue = ctx
  globalBrokerContextInitialized = true

proc initThreadBrokerContext*(): BrokerContext =
  ## Generates a new BrokerContext and installs it as this thread's
  ## global broker context. Returns the new context so it can be
  ## propagated to other threads for cross-thread broker access.
  ##
  ## Convenience for: `let ctx = NewBrokerContext(); setThreadBrokerContext(ctx)`
  let ctx = NewBrokerContext()
  setThreadBrokerContext(ctx)
  return ctx

# ---------------------------------------------------------------------------
# Async scoped context (backward compat)
# ---------------------------------------------------------------------------

template lockGlobalBrokerContext*(brokerCtx: BrokerContext, body: untyped): untyped =
  ## Runs `body` while holding the global broker context lock with the provided
  ## `brokerCtx` installed as the globally accessible context.
  ##
  ## This template is intended for use from within `chronos` async procs.
  block:
    # Lazy init: threadvar is nil on secondary threads (module-level init
    # only runs on the main thread).
    if globalBrokerContextLock.isNil():
      globalBrokerContextLock = newAsyncLock()
    await noCancel(globalBrokerContextLock.acquire())
    let previousBrokerCtx = globalBrokerContextValue
    globalBrokerContextValue = brokerCtx
    globalBrokerContextInitialized = true
    try:
      body
    finally:
      globalBrokerContextValue = previousBrokerCtx
      try:
        globalBrokerContextLock.release()
      except AsyncLockError:
        doAssert false, "globalBrokerContextLock.release(): lock not held"

template lockNewGlobalBrokerContext*(body: untyped): untyped =
  ## Runs `body` while holding the global broker context lock with a freshly
  ## generated broker context installed as the global accessor.
  ##
  ## The previous global broker context (if any) is restored on exit.
  lockGlobalBrokerContext(NewBrokerContext()):
    body

{.pop.}

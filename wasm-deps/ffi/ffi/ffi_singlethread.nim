## Threads-off stand-ins for the two primitives nim-ffi's context is built on.
##
## `chronos/threadsync` is a hard `{.fatal.}` under `--threads:off`, and
## `system.Thread` / `createThread` / `joinThread` do not exist there either --
## so the FFIContext object cannot even be *declared*, let alone used.
##
## Rather than gate all ~20 use sites (and re-gate them on every nim-ffi bump),
## this module supplies API-compatible no-ops. The upstream lifecycle code then
## compiles unchanged: it "creates" threads that do not exist and "fires"
## signals nobody waits on. That is sound only because the single-threaded
## transport never enqueues -- `sendRequestToFFIThread` runs the handler inline
## on the caller's chronos loop -- so no worker is needed to drain anything.
##
## Keep this in step with chronos' ThreadSignalPtr surface when bumping nim-ffi;
## a missing proc shows up as a plain "undeclared field" at compile time.

{.push raises: [].}

import chronos, results

type
  ThreadSignalPtr* = ptr object
    ## No-op stand-in for chronos' cross-thread signal. Pointer-shaped, not an
    ## object: the lifecycle code assigns `nil` to these fields on teardown and
    ## nil-checks them before use, so a value type does not typecheck.

  Thread*[T] = object ## No-op stand-in for system.Thread.
    started: bool

var dummySignal: int
  ## Address handed out by `new` so signals read as non-nil (nil means
  ## "not initialised" upstream). Never dereferenced.

proc new*(T: typedesc[ThreadSignalPtr]): Result[ThreadSignalPtr, string] =
  ok(cast[ThreadSignalPtr](addr dummySignal))

proc close*(signal: ThreadSignalPtr): Result[void, string] =
  ok()

proc fireSync*(
    signal: ThreadSignalPtr, timeout = InfiniteDuration
): Result[bool, string] =
  ## Nothing waits on these threads-off, so a "fire" is a successful no-op.
  ok(true)

proc wait*(
    signal: ThreadSignalPtr
): Future[void] {.async: (raises: [CancelledError]).} =
  ## Never completes on its own. The only callers are the worker loops, which
  ## are never started threads-off, so this is unreachable rather than a hang.
  await sleepAsync(InfiniteDuration)

proc waitSync*(
    signal: ThreadSignalPtr, timeout = InfiniteDuration
): Result[bool, string] =
  ## Reports "signalled" immediately. Callers use this to block until a worker
  ## acknowledges something; with no worker there is nothing to wait for, and
  ## returning false would stall shutdown on a signal that can never arrive.
  ok(true)


proc createThread*[T](
    thread: var Thread[T], body: proc(arg: T) {.thread, nimcall.}, arg: T
) =
  ## Deliberately does not run `body`: the worker loops block on signals that
  ## never fire. Requests are dispatched inline instead.
  thread.started = true

proc joinThread*[T](thread: Thread[T]) =
  discard

proc running*[T](thread: Thread[T]): bool =
  false

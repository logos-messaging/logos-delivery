{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[options, atomics, os, net, locks, json, tables]
import chronicles, chronos, results
import ./ffi_config
when not singleThreaded:
  # ThreadSignalPtr requires threads enabled; the SPSC channel only carries
  # requests across the worker-thread boundary. Neither exists inline.
  import chronos/threadsync, taskpools/channels_spsc_single
import ./ffi_types, ./ffi_thread_request, ./internal/ffi_macro, ./logging

type FFIContext*[T] = object
  myLib*: ptr T
    # main library object (e.g., Waku, LibP2P, SDS,  the one to be exposed as a library)
  when not singleThreaded:
    ffiThread: Thread[(ptr FFIContext[T])]
      # represents the main FFI thread in charge of attending API consumer actions
    watchdogThread: Thread[(ptr FFIContext[T])]
      # monitors the FFI thread and notifies the FFI API consumer if it hangs
    reqChannel: ChannelSPSCSingle[ptr FFIThreadRequest]
    reqSignal: ThreadSignalPtr # to notify the FFI Thread that a new request is sent
    reqReceivedSignal: ThreadSignalPtr
      # to signal main thread, interfacing with the FFI thread, that FFI thread received the request
  else:
    myLibStorage: T
      # Threaded mode roots the library object on the FFI worker thread's stack
      # (`ffiReqHandler`). With no worker thread we keep that backing store in
      # the context instead, GC-rooted via the holder in createFFIContext.
  lock: Lock
  userData*: pointer
  eventCallback*: pointer
  eventUserdata*: pointer
  running: Atomic[bool] # To control when the threads are running
  registeredRequests: ptr Table[cstring, FFIRequestProc]
    # Pointer to with the registered requests at compile time

const git_version* {.strdefine.} = "n/a"

template callEventCallback*(ctx: ptr FFIContext, eventName: string, body: untyped) =
  if isNil(ctx[].eventCallback):
    chronicles.error eventName & " - eventCallback is nil"
    return

  foreignThreadGc:
    try:
      let event = body
      cast[FFICallBack](ctx[].eventCallback)(
        RET_OK, unsafeAddr event[0], cast[csize_t](len(event)), ctx[].eventUserData
      )
    except Exception, CatchableError:
      let msg =
        "Exception " & eventName & " when calling 'eventCallBack': " &
        getCurrentExceptionMsg()
      cast[FFICallBack](ctx[].eventCallback)(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), ctx[].eventUserData
      )

when not singleThreaded:
  proc sendRequestToFFIThread*(
      ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest, timeout = InfiniteDuration
  ): Result[void, string] =
    ctx.lock.acquire()
    # This lock is only necessary while we use a SP Channel and while the signalling
    # between threads assumes that there aren't concurrent requests.
    # Rearchitecting the signaling + migrating to a MP Channel will allow us to receive
    # requests concurrently and spare us the need of locks
    defer:
      ctx.lock.release()

    ## Sending the request
    let sentOk = ctx.reqChannel.trySend(ffiRequest)
    if not sentOk:
      return err("Couldn't send a request to the ffi thread")

    let fireSyncRes = ctx.reqSignal.fireSync()
    if fireSyncRes.isErr():
      return err("failed fireSync: " & $fireSyncRes.error)

    if fireSyncRes.get() == false:
      return err("Couldn't fireSync in time")

    ## wait until the FFI working thread properly received the request
    let res = ctx.reqReceivedSignal.waitSync(timeout)
    if res.isErr():
      return err("Couldn't receive reqReceivedSignal signal")

    ## Notice that in case of "ok", the deallocShared(req) is performed by the FFI Thread in the
    ## process proc.
    return ok()

type Foo = object
registerReqFFI(WatchdogReq, foo: ptr Foo):
  proc(): Future[Result[string, string]] {.async.} =
    return ok("FFI thread is not blocked")

type JsonNotRespondingEvent = object
  eventType: string

proc init(T: type JsonNotRespondingEvent): T =
  return JsonNotRespondingEvent(eventType: "not_responding")

proc `$`(event: JsonNotRespondingEvent): string =
  $(%*event)

proc onNotResponding*(ctx: ptr FFIContext) =
  callEventCallback(ctx, "onNotResponding"):
    $JsonNotRespondingEvent.init()

when not singleThreaded:
  proc watchdogThreadBody(ctx: ptr FFIContext) {.thread.} =
    ## Watchdog thread that monitors the FFI thread and notifies the library user if it hangs.
    ## This thread never blocks.

    let watchdogRun = proc(ctx: ptr FFIContext) {.async.} =
      const WatchdogStartDelay = 10.seconds
      const WatchdogTimeinterval = 1.seconds
      const WatchdogTimeout = 20.seconds

      # Give time for the node to be created and up before sending watchdog requests
      await sleepAsync(WatchdogStartDelay)
      while true:
        await sleepAsync(WatchdogTimeinterval)

        if ctx.running.load == false:
          debug "Watchdog thread exiting because FFIContext is not running"
          break

        let callback = proc(
            callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
        ) {.cdecl, gcsafe, raises: [].} =
          discard ## Don't do anything. Just respecting the callback signature.
        const nilUserData = nil

        trace "Sending watchdog request to FFI thread"

        sendRequestToFFIThread(ctx, WatchdogReq.ffiNewReq(callback, nilUserData), WatchdogTimeout).isOkOr:
          error "Failed to send watchdog request to FFI thread", error = $error
          onNotResponding(ctx)

    waitFor watchdogRun(ctx)

proc processRequest[T](
    request: ptr FFIThreadRequest, ctx: ptr FFIContext[T]
) {.async.} =
  ## Invoked within the FFI thread to process a request coming from the FFI API consumer thread.

  let reqId = $request[].reqId
    ## The reqId determines which proc will handle the request.
    ## The registeredRequests represents a table defined at compile time.
    ## Then, registeredRequests == Table[reqId, proc-handling-the-request-asynchronously]

  let retFut =
    if not ctx[].registeredRequests[].contains(reqId):
      ## That shouldn't happen because only registered requests should be sent to the FFI thread.
      nilProcess(request[].reqId)
    else:
      ctx[].registeredRequests[][reqId](request[].reqContent, ctx)
  handleRes(await retFut, request)

when not singleThreaded:
  proc ffiThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
    ## FFI thread body that attends library user API requests

    logging.setupLog(logging.LogLevel.DEBUG, logging.LogFormat.TEXT)

    let ffiRun = proc(ctx: ptr FFIContext[T]) {.async.} =
      var ffiReqHandler: T
        ## Holds the main library object, i.e., in charge of handling the ffi requests.
        ## e.g., Waku, LibP2P, SDS, etc.

      while true:
        await ctx.reqSignal.wait()

        if ctx.running.load == false:
          break

        ## Wait for a request from the ffi consumer thread
        var request: ptr FFIThreadRequest
        let recvOk = ctx.reqChannel.tryRecv(request)
        if not recvOk:
          chronicles.error "ffi thread could not receive a request"
          continue

        ctx.myLib = addr ffiReqHandler

        ## Handle the request
        asyncSpawn processRequest(request, ctx)

        let fireRes = ctx.reqReceivedSignal.fireSync()
        if fireRes.isErr():
          error "could not fireSync back to requester thread", error = fireRes.error

    waitFor ffiRun(ctx)

when singleThreaded:
  type SingleThreadedHolder[T] = ref object of RootObj
    ## GC-traced cell so the library object stored in `ctx.myLibStorage` (a `ref`
    ## for e.g. Waku) stays scanned. Kept alive in `gSingleThreadedRoots`.
    ## `of RootObj` so holders can be stored uniformly as `RootRef`.
    ctx: FFIContext[T]

  var gSingleThreadedRoots {.threadvar.}: seq[RootRef]

  proc sendRequestToFFIThread*(
      ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest, timeout = InfiniteDuration
  ): Result[void, string] =
    ## Single-threaded transport. `processRequest` fires the callback and frees
    ## the request via `handleRes`.
    when defined(emscripten):
      # Browser: handlers await the network (WebSocket). Blocking with `waitFor`
      # would starve the JS event loop and deadlock. Fire-and-forget instead; the
      # host drives chronos via `ffi_poll()` and the callback fires on completion.
      asyncSpawn processRequest(ffiRequest, ctx)
      poll() # kick the handler up to its first await
    else:
      try:
        waitFor processRequest(ffiRequest, ctx)
      except CatchableError as e:
        return err("processRequest failed: " & e.msg)
    return ok()

  proc ffiPoll*() {.exportc: "ffi_poll", cdecl.} =
    ## Advance chronos one step. The browser host calls this from its event loop
    ## (setTimeout / requestAnimationFrame) so async handlers progress without
    ## blocking the JS thread; callbacks fire as work completes.
    poll()

  proc createFFIContext*[T](): Result[ptr FFIContext[T], string] =
    ## No worker/watchdog threads. The context lives inside a GC-rooted holder so
    ## `myLibStorage` (the library `ref`) is scanned; `myLib` points at it.
    let holder = SingleThreadedHolder[T]()
    gSingleThreadedRoots.add(holder)
    let ctx = addr holder.ctx
    ctx.lock.initLock()
    ctx.registeredRequests = addr ffi_types.registeredRequests
    ctx.running.store(true)
    ctx.myLib = addr ctx.myLibStorage
    return ok(ctx)

  proc destroyFFIContext*[T](ctx: ptr FFIContext[T]): Result[void, string] =
    ctx.running.store(false)
    ctx.lock.deinitLock()
    # Drop the GC root so the holder (and its library object) can be collected.
    for i in 0 ..< gSingleThreadedRoots.len:
      let h = cast[SingleThreadedHolder[T]](gSingleThreadedRoots[i])
      if cast[pointer](addr h.ctx) == cast[pointer](ctx):
        gSingleThreadedRoots.del(i)
        break
    return ok()
else:
  proc createFFIContext*[T](): Result[ptr FFIContext[T], string] =
    ## This proc is called from the main thread and it creates
    ## the FFI working thread.
    var ctx = createShared(FFIContext[T], 1)
    ctx.reqSignal = ThreadSignalPtr.new().valueOr:
      return err("couldn't create reqSignal ThreadSignalPtr")
    ctx.reqReceivedSignal = ThreadSignalPtr.new().valueOr:
      return err("couldn't create reqReceivedSignal ThreadSignalPtr")
    ctx.lock.initLock()
    ctx.registeredRequests = addr ffi_types.registeredRequests

    ctx.running.store(true)

    try:
      createThread(ctx.ffiThread, ffiThreadBody[T], ctx)
    except ValueError, ResourceExhaustedError:
      freeShared(ctx)
      return err("failed to create the FFI thread: " & getCurrentExceptionMsg())

    try:
      createThread(ctx.watchdogThread, watchdogThreadBody, ctx)
    except ValueError, ResourceExhaustedError:
      freeShared(ctx)
      return err("failed to create the watchdog thread: " & getCurrentExceptionMsg())

    return ok(ctx)

  proc destroyFFIContext*[T](ctx: ptr FFIContext[T]): Result[void, string] =
    ctx.running.store(false)

    let signaledOnTime = ctx.reqSignal.fireSync().valueOr:
      return err("error in destroyFFIContext: " & $error)
    if not signaledOnTime:
      return err("failed to signal reqSignal on time in destroyFFIContext")

    joinThread(ctx.ffiThread)
    joinThread(ctx.watchdogThread)
    ctx.lock.deinitLock()
    ?ctx.reqSignal.close()
    ?ctx.reqReceivedSignal.close()
    freeShared(ctx)

    return ok()

template checkParams*(ctx: ptr FFIContext, callback: FFICallBack, userData: pointer) =
  if not isNil(ctx):
    ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

## API Library Registration
## ------------------------
## Provides the `registerBrokerLibrary` macro that generates:
## 1. Library context lifecycle management (createContext/shutdown C exports)
## 2. Compile-time validation of mandatory InitializeRequest/ShutdownRequest types
## 3. C header file generation from accumulated broker declarations
## 4. Memory management helpers (free_string)
## 5. Delivery thread creation (hosts event listeners, calls C callbacks)
## 6. Aggregate event listener provider (dispatches by typeId)
## 7. Aggregate cleanup (removes all listeners on shutdown)
##
## Usage:
## ```nim
## registerBrokerLibrary:
##   name: "mylib"
##   initializeRequest: InitializeRequest
##   shutdownRequest: ShutdownRequest
##   refType: MyLibObject  # optional
## ```
##
## The `registerBrokerLibrary` macro MUST appear after all `EventBroker(API)`
## and `RequestBroker(API)` declarations in the source file.

{.push raises: [].}

import std/[atomics, locks, macros, os, strutils, tables]
import chronos, chronicles
import results
import ./broker_context, ./internal/api_common
import ./internal/helper/broker_utils
import ./internal/api_codegen_cbor_h
import ./internal/api_codegen_cbor_hpp
import ./internal/api_codegen_cbor_py
import ./internal/api_codegen_cbor_rust
import ./internal/api_codegen_cbor_go
import ./internal/api_codegen_cbor_cddl
import ./internal/api_codegen_cmake
import ./internal/api_cbor_descriptor
import ./internal/api_cbor_subs_registry
import ./internal/api_cbor_tuple
import ./internal/api_cbor_courier
import ./internal/api_cbor_event_courier
import ./internal/mt_broker_common
import ./internal/broker_debug

export api_cbor_descriptor, api_cbor_subs_registry, api_cbor_tuple, api_cbor_courier
export api_cbor_event_courier
export mt_broker_common

export results, chronos, chronicles, broker_context, api_common

# Optional override for where the generated FFI artifacts (headers, wrappers,
# cmake, cddl) are written. Set with `-d:BrokerFfiApiOutDir:<dir>`. Empty (the
# default) makes `detectOutputDir` fall back to the project path. Declared here
# as a `{.strdefine.}` so the `when defined(...)` use below resolves to a value.
const BrokerFfiApiOutDir* {.strdefine.} = ""

# ---------------------------------------------------------------------------
# Macro helpers
# ---------------------------------------------------------------------------

proc parseLibraryConfig(
    body: NimNode
): tuple[
  name: string,
  version: string,
  versionExpr: NimNode,
  initializeRequest: NimNode,
  shutdownRequest: NimNode,
  refType: NimNode,
  mainClass: string,
  asyncTimeoutMs: int,
  asyncQueueDepth: int,
] {.compileTime.} =
  var name = ""
  var version = "0.1.0"
  # Default dispatch-scoped timeout (ms) for `<lib>_callAsync`. Surfaced to
  # wrappers + the C header as the policy default; the raw ABI stays mechanism
  # (0 = infinite). 30 s unless overridden by `asyncTimeoutMs:`.
  var asyncTimeoutMs = 30000
  # Ceiling on concurrent in-flight `<lib>_callAsync`s per context (the async
  # ring does not grow; full => -6 EAGAIN). Independent of the sync `_call` slot
  # pool. Exposed to clients via the generated `<LIB>_ASYNC_QUEUE_DEPTH` macro so
  # they can size a bounded send window. 64 unless overridden.
  var asyncQueueDepth = 64
  # AST emitted into the generated `<lib>_version()` proc: a string literal, or
  # a const identifier (e.g. a `{.strdefine.}` `git_version`) the caller defines.
  var versionExpr: NimNode = newLit("0.1.0")
  var initializeReq: NimNode = nil
  var shutdownReq: NimNode = nil
  var refTy: NimNode = nil
  var mainClass = ""

  for stmt in body:
    if stmt.kind == nnkCall and stmt.len == 2:
      let key = $stmt[0]
      let value = stmt[1]
      case key.toLowerAscii()
      of "name":
        if value.kind == nnkStmtList and value.len == 1:
          name = value[0].strVal
        elif value.kind == nnkStrLit:
          name = value.strVal
        else:
          error("name must be a string literal", value)
      of "version":
        var v = value
        if v.kind == nnkStmtList and v.len == 1:
          v = v[0]
        case v.kind
        of nnkStrLit:
          version = v.strVal
          versionExpr = v
        of nnkIdent, nnkSym:
          # A const reference (e.g. a `{.strdefine.}` `git_version`). The value
          # isn't knowable here (untyped macro, caller scope), so we don't bake a
          # literal — the generated `<lib>_version()` proc references the const
          # directly and it resolves when the generated code compiles in the
          # caller's module. `version` stays "" so the header comment omits it.
          version = ""
          versionExpr = v
        else:
          error("version must be a string literal or a string const identifier", v)
      of "initializerequest":
        if value.kind == nnkStmtList and value.len == 1:
          initializeReq = value[0]
        else:
          initializeReq = value
      of "shutdownrequest", "destroyrequest":
        if value.kind == nnkStmtList and value.len == 1:
          shutdownReq = value[0]
        else:
          shutdownReq = value
      of "reftype":
        if value.kind == nnkStmtList and value.len == 1:
          refTy = value[0]
        else:
          refTy = value
      of "asynctimeoutms":
        var v = value
        if v.kind == nnkStmtList and v.len == 1:
          v = v[0]
        if v.kind == nnkIntLit:
          if v.intVal < 0:
            error("asyncTimeoutMs must be >= 0 (0 = infinite)", v)
          asyncTimeoutMs = int(v.intVal)
        else:
          error(
            "asyncTimeoutMs must be an integer literal (milliseconds, 0 = infinite)", v
          )
      of "asyncqueuedepth":
        var v = value
        if v.kind == nnkStmtList and v.len == 1:
          v = v[0]
        if v.kind == nnkIntLit:
          if v.intVal <= 0:
            error("asyncQueueDepth must be > 0", v)
          asyncQueueDepth = int(v.intVal)
        else:
          error("asyncQueueDepth must be a positive integer literal", v)
      of "mainclass":
        # reduced-A (A1): designates the main `BrokerInterface(API)` facade for
        # a multi-interface library. Other (API) interfaces are auto-discovered
        # from the compile-time registry and emitted as their own sub-wrappers.
        var v = value
        if v.kind == nnkStmtList and v.len == 1:
          v = v[0]
        case v.kind
        of nnkIdent, nnkSym:
          mainClass = $v
        of nnkStrLit:
          mainClass = v.strVal
        else:
          error("mainClass must be an interface type name", v)
      else:
        error("Unknown registerBrokerLibrary key: " & key, stmt)
    else:
      error("registerBrokerLibrary expects key: value pairs", stmt)

  if name.len == 0:
    error("registerBrokerLibrary requires a 'name' field", body)
  if initializeReq.isNil():
    error("registerBrokerLibrary requires a 'initializeRequest' field", body)
  if shutdownReq.isNil():
    error(
      "registerBrokerLibrary requires a 'shutdownRequest' field (the legacy 'destroyRequest' alias is still accepted)",
      body,
    )
  if mainClass.len > 0 and not isApiInterface(mainClass):
    error(
      "registerBrokerLibrary: mainClass '" & mainClass &
        "' is not a registered BrokerInterface(API). Declare it with " &
        "`BrokerInterface(API, " & mainClass & "): ...` before registerBrokerLibrary.",
      body,
    )

  (
    name: name,
    version: version,
    versionExpr: versionExpr,
    initializeRequest: initializeReq,
    shutdownRequest: shutdownReq,
    refType: refTy,
    mainClass: mainClass,
    asyncTimeoutMs: asyncTimeoutMs,
    asyncQueueDepth: asyncQueueDepth,
  )

proc parseTypeExpr(
    exprText: string, context: NimNode
): NimNode {.compileTime, raises: [].} =
  try:
    parseExpr(exprText)
  except ValueError as exc:
    error(
      "Failed to parse generated type expression '" & exprText & "': " & exc.msg,
      context,
    )

# ---------------------------------------------------------------------------
# Macro
# ---------------------------------------------------------------------------

proc registerBrokerLibraryCborImpl(
  body: NimNode,
  config:
    tuple[
      name: string,
      version: string,
      versionExpr: NimNode,
      initializeRequest: NimNode,
      shutdownRequest: NimNode,
      refType: NimNode,
      mainClass: string,
      asyncTimeoutMs: int,
      asyncQueueDepth: int,
    ],
): NimNode

proc registerBrokerLibraryImpl(body: NimNode): NimNode =
  let config = parseLibraryConfig(body)
  registerBrokerLibraryCborImpl(body, config)

# ---------------------------------------------------------------------------
# CBOR-mode library codegen.
#
# Emits the small fixed C ABI surface (initialize / createContext / shutdown
# / allocBuffer / freeBuffer / call) plus a per-library dispatch case
# statement that routes apiName strings to the adapter procs registered by
# `RequestBroker(API)` expansions. Buffer ownership: every void* crossing
# the ABI is allocated by Nim and freed by Nim. Threading: a dedicated
# processing thread runs `setupProviders(ctx)` and the chronos event loop
# that drives the request providers; foreign threads invoke `<lib>_call`
# and use `waitFor` to drive a momentary chronos loop on the calling
# thread, which dispatches across the MT broker channel to the processing
# thread. Events are not yet wired (Phase 3).
# ---------------------------------------------------------------------------

proc registerBrokerLibraryCborImpl(
    body: NimNode,
    config:
      tuple[
        name: string,
        version: string,
        versionExpr: NimNode,
        initializeRequest: NimNode,
        shutdownRequest: NimNode,
        refType: NimNode,
        mainClass: string,
        asyncTimeoutMs: int,
        asyncQueueDepth: int,
      ],
): NimNode =
  let libName = config.name
  gApiLibraryName = libName

  let initializeReqIdent = config.initializeRequest
  let shutdownReqIdent = config.shutdownRequest

  # Identifiers
  let initFuncName = libName & "_initialize"
  let initFuncNameLit = newLit(initFuncName)
  let initFuncIdent = ident(initFuncName)
  let createContextFuncName = libName & "_createContext"
  let createContextFuncNameLit = newLit(createContextFuncName)
  let createContextFuncIdent = ident(createContextFuncName)
  let shutdownFuncName = libName & "_shutdown"
  let shutdownFuncNameLit = newLit(shutdownFuncName)
  let shutdownFuncIdent = ident(shutdownFuncName)
  let callFuncName = libName & "_call"
  let callFuncNameLit = newLit(callFuncName)
  let callFuncIdent = ident(callFuncName)
  # Async fire-and-forget call (side by side with the sync `_call`): enqueues
  # onto the courier async ring and returns immediately; the response is fanned
  # back through the event delivery thread to a foreign callback.
  let callAsyncFuncName = libName & "_callAsync"
  let callAsyncFuncNameLit = newLit(callAsyncFuncName)
  let callAsyncFuncIdent = ident(callAsyncFuncName)
  let responseCallbackTypeIdent = ident(libName & "CborResponseCallback")
  let allocBufFuncName = libName & "_allocBuffer"
  let allocBufFuncNameLit = newLit(allocBufFuncName)
  let allocBufFuncIdent = ident(allocBufFuncName)
  let freeBufFuncName = libName & "_freeBuffer"
  let freeBufFuncNameLit = newLit(freeBufFuncName)
  let freeBufFuncIdent = ident(freeBufFuncName)

  let nimMainIdent = ident(libName & "NimMain")
  let nimInitFlagIdent = ident("g" & libName & "NimInit")
  let gcRegFlagIdent = ident("g" & libName & "GcReg")
  let ctxEntryIdent = ident(libName & "CborCtxEntry")
  let procThreadArgIdent = ident(libName & "CborThreadArg")
  let procThreadProcIdent = ident(libName & "CborProcessingThread")
  let delivThreadProcIdent = ident(libName & "CborDeliveryThread")
  let ctxsIdent = ident("g" & libName & "CborCtxs")
  let ctxsLockIdent = ident("g" & libName & "CborCtxsLock")
  let ctxsInitIdent = ident("g" & libName & "CborCtxsInit")
  let dispatchProcIdent = ident(libName & "CborDispatch")
  let libNameLit = newLit(libName)

  # Event subscription identifiers (used by the per-event installers and the
  # subscribe / unsubscribe C exports).
  let eventCallbackTypeIdent = ident(libName & "CborEventCallback")
  # Phase 10: subscription state lives in a hand-rolled shared-heap registry
  # (`api_cbor_subs_registry`). The previous codegen kept a GC'd
  # `Table[(uint32, string), seq[Subscription]]` plus `Lock` here; that broke
  # `--mm:refc` cross-thread delivery because subscribe/unsubscribe run on
  # foreign caller threads while the listener fires on the processing thread.
  let subsRegIdent = ident("g" & libName & "CborSubsReg")
  let subsHandleIdent = ident("g" & libName & "CborNextSubHandle")
  let subscribeFuncName = libName & "_subscribe"
  let subscribeFuncNameLit = newLit(subscribeFuncName)
  let subscribeFuncIdent = ident(subscribeFuncName)
  let unsubscribeFuncName = libName & "_unsubscribe"
  let unsubscribeFuncNameLit = newLit(unsubscribeFuncName)
  let unsubscribeFuncIdent = ident(unsubscribeFuncName)
  # reduced-A (A4): per-instance teardown export + processing-thread worker.
  let releaseInstanceFuncName = libName & "_releaseInstance"
  let releaseInstanceFuncNameLit = newLit(releaseInstanceFuncName)
  let releaseInstanceFuncIdent = ident(releaseInstanceFuncName)
  let releaseCtxProcName = libName & "CborReleaseCtx"
  let releaseCtxProcIdent = ident(releaseCtxProcName)
  let releaseApiNameLit = newLit("__release_instance")
  let knownEventPredIdent = ident(libName & "CborIsKnownEvent")
  let installAllListenersIdent = ident(libName & "CborInstallAllListeners")
  # Part D-3: per-event helper that maps an event name to its global
  # `Atomic[int]` foreign-subscriber count. Subscribe / unsubscribe
  # use it to bump / decrement the counter so the emit-side fast-path
  # can short-circuit (no CBOR encode, no courier enqueue) when zero
  # foreign subscribers exist for an event.
  let getEventSubsCountIdent = ident(libName & "CborEventSubsCountAtomicPtr")
  # Part D-3: name → static cstring resolver. The eventCourierPoll
  # extracts the event name from the in-ring message (`m.eventName`,
  # a stack-local array after `tryDequeue`). Passing that pointer to
  # foreign callbacks would dangle the moment the poll proc returns
  # — callbacks legitimately store the eventName cstring (see the
  # `gSlots[i].name = eventName` pattern in the typemappingtestlib
  # test). This lookup returns a STATIC string-literal cstring, which
  # is permanently valid, so the callback can store it freely.
  let resolveEventNameCstrIdent = ident(libName & "CborResolveEventNameCstring")

  # Discovery / introspection identifiers (Phase 6).
  let listApisFuncName = libName & "_listApis"
  let listApisFuncNameLit = newLit(listApisFuncName)
  let listApisFuncIdent = ident(listApisFuncName)
  let getSchemaFuncName = libName & "_getSchema"
  let getSchemaFuncNameLit = newLit(getSchemaFuncName)
  let getSchemaFuncIdent = ident(getSchemaFuncName)
  let descriptorIdent = ident("g" & libName & "CborDescriptor")
  let apiListIdent = ident("g" & libName & "CborApiList")
  let descriptorBuildIdent = ident(libName & "CborBuildDescriptor")
  let apiListBuildIdent = ident(libName & "CborBuildApiList")

  # Hard cap on a single buffer to detect runaway encodes.
  let bufSizeCap = newLit(64 * 1024 * 1024)

  # Configured async in-flight window (per context), baked into `_createContext`
  # courier sizing.
  let asyncQueueDepthLit = newLit(config.asyncQueueDepth)

  result = newStmtList()

  # Compile-time validation of the mandatory request types.
  result.add(
    quote do:
      when not compiles(typeof(`initializeReqIdent`)):
        {.
          error:
            "registerBrokerLibrary: initializeRequest type '" &
            astToStr(`initializeReqIdent`) &
            "' is not defined. Ensure a RequestBroker(API) declaring this type " &
            "appears before registerBrokerLibrary."
        .}
      when not compiles(typeof(`shutdownReqIdent`)):
        {.
          error:
            "registerBrokerLibrary: shutdownRequest type '" &
            astToStr(`shutdownReqIdent`) &
            "' is not defined. Ensure a RequestBroker(API) declaring this type " &
            "appears before registerBrokerLibrary."
        .}
  )

  # Foreign-thread GC bootstrap (once per compilation unit).
  result.add(emitEnsureForeignThreadGc())

  # NimMain import on POSIX (Windows DllMain auto-runs it).
  when not defined(windows):
    let nimMainImportName = newLit(libName & "NimMain")
    result.add(
      quote do:
        proc `nimMainIdent`() {.importc: `nimMainImportName`, cdecl.}
    )

  # ------------------------------------------------------------------
  # Build the dispatch case statement from accumulated request entries.
  # Snapshot and clear the accumulator so a second registerBrokerLibrary in
  # the same compilation unit (a future multi-library scenario) starts fresh.
  # ------------------------------------------------------------------
  # Snapshot the registered request adapters and event entries. We
  # deliberately do NOT clear the global accumulators here — Nim's
  # compile-time VM aliases `let` copies of seqs back to the source, so
  # resetting before reading would leave us with an empty list. A future
  # multi-library-per-compilation scenario would need a different pattern
  # (e.g., snapshot a length and slice from there next time).
  let entries = gApiCborRequestEntries
  let eventEntries = gApiCborEventEntries
  let signalEntries = gApiCborSignalEntries

  # The dispatch proc is async and returns just `seq[byte]`. To signal
  # "unknown apiName" without raising or capturing a `var bool`, the
  # convention is: empty seq + the calling `<lib>_call` checks against the
  # known-name set (a separate non-async predicate proc).
  let knownNamePredIdent = ident(libName & "CborIsKnownApiName")

  # SignalBroker(API): a signal rides `<lib>_call` on a slot-free path — no
  # response slot, no round trip. Its dispatch proc returns `Future[void]`
  # (no envelope); `isSignalName` routes `<lib>_call` to the slot-free branch
  # and `signalHasHandler` is the lock-free caller-thread fast-fail.
  let signalDispatchProcIdent = ident(libName & "CborSignalDispatch")
  let isSignalNamePredIdent = ident(libName & "CborIsSignalName")
  let signalHasHandlerPredIdent = ident(libName & "CborSignalHasHandler")

  var caseStmt = nnkCaseStmt.newTree(ident("apiName"))
  for entry in entries:
    let nameLit = newLit(entry.apiName)
    let adapterCall = newCall(ident(entry.adapterProc), ident("ctx"), ident("reqBuf"))
    let branchBody = newStmtList(
      nnkReturnStmt.newTree(nnkCommand.newTree(ident("await"), adapterCall))
    )
    caseStmt.add(nnkOfBranch.newTree(nameLit, branchBody))
  caseStmt.add(
    nnkElse.newTree(
      newStmtList(nnkReturnStmt.newTree(prefix(nnkBracket.newTree(), "@")))
    )
  )

  let dispatchProc = nnkProcDef.newTree(
    postfix(dispatchProcIdent, "*"),
    newEmptyNode(),
    newEmptyNode(),
    nnkFormalParams.newTree(
      nnkBracketExpr.newTree(
        ident("Future"), nnkBracketExpr.newTree(ident("seq"), ident("byte"))
      ),
      newIdentDefs(ident("apiName"), ident("string")),
      newIdentDefs(ident("ctx"), ident("BrokerContext")),
      newIdentDefs(ident("reqBuf"), nnkBracketExpr.newTree(ident("seq"), ident("byte"))),
    ),
    nnkPragma.newTree(
      newColonExpr(
        ident("async"),
        nnkTupleConstr.newTree(newColonExpr(ident("raises"), nnkBracket.newTree())),
      ),
      ident("gcsafe"),
    ),
    newEmptyNode(),
    newStmtList(caseStmt),
  )
  result.add(dispatchProc)

  # ------------------------------------------------------------------
  # reduced-A (A4): per-context teardown. `<lib>_releaseInstance(ctx)` and
  # `<lib>_shutdown` route a reserved-apiName message to the processing thread
  # which runs this proc: it clears the request providers and drops the event
  # listeners keyed by `ctx`. Running here (the processing thread) is required
  # because the MT broker buckets are keyed by the processing thread's id —
  # clearing from a foreign thread would touch the wrong bucket. After this the
  # Nim sub-instance is no longer pinned by its provider closures and the GC
  # reclaims it (no FFI-side ownership). Idempotent: clearing an absent ctx is a
  # no-op. `when compiles` guards keep it valid whether a broker is request/
  # event / single-thread / mt / API.
  block:
    var seenReq: seq[string] = @[]
    var src = "proc " & releaseCtxProcName & "(ctx: BrokerContext) {.gcsafe.} =\n"
    var body = ""
    for entry in entries:
      if entry.responseTypeName.len == 0 or entry.responseTypeName in seenReq:
        continue
      seenReq.add(entry.responseTypeName)
      body.add(
        "  when compiles(" & entry.responseTypeName & ".clearProvider(ctx)):\n" & "    " &
          entry.responseTypeName & ".clearProvider(ctx)\n"
      )
    for e in eventEntries:
      body.add(
        "  when compiles(" & e.typeName & ".dropAllListeners(ctx)):\n" &
          "    when typeof(" & e.typeName & ".dropAllListeners(ctx)) is void:\n" &
          "      " & e.typeName & ".dropAllListeners(ctx)\n" & "    else:\n" &
          "      discard " & e.typeName & ".dropAllListeners(ctx)\n"
      )
    var seenSig: seq[string] = @[]
    for e in signalEntries:
      if e.typeName in seenSig:
        continue
      seenSig.add(e.typeName)
      # dropSignalHandler is async Future[void]; discard is safe — the MT drop
      # body is suspension-free, so it clears eagerly.
      body.add(
        "  when compiles(" & e.typeName & ".dropSignalHandler(ctx)):\n" & "    discard " &
          e.typeName & ".dropSignalHandler(ctx)\n"
      )
    if body.len == 0:
      body = "  discard ctx\n"
    src.add(body)
    try:
      result.add(parseStmt(src))
    except ValueError as exc:
      error("reduced-A release-teardown codegen failed: " & exc.msg)

  # Companion predicate: foreign caller dispatch needs to distinguish
  # "unknown name" from "known name with empty response". Predicate is a
  # plain non-async proc so `<lib>_call` can call it directly.
  var nameSet = newStmtList()
  var nameCase = nnkCaseStmt.newTree(ident("apiName"))
  for entry in entries:
    nameCase.add(
      nnkOfBranch.newTree(
        newLit(entry.apiName), newStmtList(nnkReturnStmt.newTree(ident("true")))
      )
    )
  nameCase.add(nnkElse.newTree(newStmtList(nnkReturnStmt.newTree(ident("false")))))
  nameSet.add(nameCase)
  let knownProc = nnkProcDef.newTree(
    postfix(knownNamePredIdent, "*"),
    newEmptyNode(),
    newEmptyNode(),
    nnkFormalParams.newTree(
      ident("bool"), newIdentDefs(ident("apiName"), ident("string"))
    ),
    nnkPragma.newTree(ident("gcsafe")),
    newEmptyNode(),
    nameSet,
  )
  result.add(knownProc)

  # ------------------------------------------------------------------
  # SignalBroker(API) codegen: a Future[void] dispatch proc + two plain
  # predicates. `<lib>_call` uses `isSignalName` to take the slot-free branch,
  # `signalHasHandler` (lock-free) to fast-fail with ProviderErr, and the
  # processing thread runs `signalDispatch` (which awaits the one-way adapter
  # that decodes the payload and calls `signal()` — no response is produced).
  # ------------------------------------------------------------------
  block:
    var sigCase = nnkCaseStmt.newTree(ident("apiName"))
    for e in signalEntries:
      let adapterCall = newCall(ident(e.adapterProc), ident("ctx"), ident("reqBuf"))
      sigCase.add(
        nnkOfBranch.newTree(
          newLit(e.apiName),
          newStmtList(nnkCommand.newTree(ident("await"), adapterCall)),
        )
      )
    sigCase.add(nnkElse.newTree(newStmtList(nnkDiscardStmt.newTree(newEmptyNode()))))
    let sigDispatchProc = nnkProcDef.newTree(
      postfix(signalDispatchProcIdent, "*"),
      newEmptyNode(),
      newEmptyNode(),
      nnkFormalParams.newTree(
        nnkBracketExpr.newTree(ident("Future"), ident("void")),
        newIdentDefs(ident("apiName"), ident("string")),
        newIdentDefs(ident("ctx"), ident("BrokerContext")),
        newIdentDefs(
          ident("reqBuf"), nnkBracketExpr.newTree(ident("seq"), ident("byte"))
        ),
      ),
      nnkPragma.newTree(
        newColonExpr(
          ident("async"),
          nnkTupleConstr.newTree(newColonExpr(ident("raises"), nnkBracket.newTree())),
        ),
        ident("gcsafe"),
      ),
      newEmptyNode(),
      newStmtList(sigCase),
    )
    result.add(sigDispatchProc)

    # isSignalName predicate.
    var isSigCase = nnkCaseStmt.newTree(ident("apiName"))
    for e in signalEntries:
      isSigCase.add(
        nnkOfBranch.newTree(
          newLit(e.apiName), newStmtList(nnkReturnStmt.newTree(ident("true")))
        )
      )
    isSigCase.add(nnkElse.newTree(newStmtList(nnkReturnStmt.newTree(ident("false")))))
    result.add(
      nnkProcDef.newTree(
        postfix(isSignalNamePredIdent, "*"),
        newEmptyNode(),
        newEmptyNode(),
        nnkFormalParams.newTree(
          ident("bool"), newIdentDefs(ident("apiName"), ident("string"))
        ),
        nnkPragma.newTree(ident("gcsafe")),
        newEmptyNode(),
        newStmtList(isSigCase),
      )
    )

    # signalHasHandler predicate — lock-free, caller-thread fast-fail. Each
    # branch reads the per-type present counter via `<Type>.signalHandlerPresent`.
    var hasCase = nnkCaseStmt.newTree(ident("apiName"))
    for e in signalEntries:
      let presentCall =
        newCall(newDotExpr(ident(e.typeName), ident("signalHandlerPresent")))
      hasCase.add(
        nnkOfBranch.newTree(
          newLit(e.apiName), newStmtList(nnkReturnStmt.newTree(presentCall))
        )
      )
    hasCase.add(nnkElse.newTree(newStmtList(nnkReturnStmt.newTree(ident("false")))))
    result.add(
      nnkProcDef.newTree(
        postfix(signalHasHandlerPredIdent, "*"),
        newEmptyNode(),
        newEmptyNode(),
        nnkFormalParams.newTree(
          ident("bool"), newIdentDefs(ident("apiName"), ident("string"))
        ),
        nnkPragma.newTree(ident("gcsafe")),
        newEmptyNode(),
        newStmtList(hasCase),
      )
    )

  # ------------------------------------------------------------------
  # Event known-name predicate (companion to request side).
  # ------------------------------------------------------------------
  block:
    var eventCase = nnkCaseStmt.newTree(ident("eventName"))
    for e in eventEntries:
      eventCase.add(
        nnkOfBranch.newTree(
          newLit(e.apiName), newStmtList(nnkReturnStmt.newTree(ident("true")))
        )
      )
    eventCase.add(nnkElse.newTree(newStmtList(nnkReturnStmt.newTree(ident("false")))))
    let eventKnownProc = nnkProcDef.newTree(
      postfix(knownEventPredIdent, "*"),
      newEmptyNode(),
      newEmptyNode(),
      nnkFormalParams.newTree(
        ident("bool"), newIdentDefs(ident("eventName"), ident("string"))
      ),
      nnkPragma.newTree(ident("gcsafe")),
      newEmptyNode(),
      newStmtList(eventCase),
    )
    result.add(eventKnownProc)

  # ------------------------------------------------------------------
  # Per-library types and globals.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      type
        `procThreadArgIdent` = object
          ctx: BrokerContext
          shutdownFlag: Atomic[int]
          processingReady: Atomic[int]
          deliveryReady: Atomic[int]
          processingErrorMessage: cstring
          deliveryErrorMessage: cstring
          # Part C — buffer courier. `courier` is allocated in
          # `_createContext` and freed in `_shutdown`. `courierSignal` is
          # the processing thread's broker dispatch signal, published by
          # the processing thread once its chronos loop is up so a foreign
          # `<lib>_call` can wake it after enqueuing a request.
          courier: ptr CborCourier
          courierSignal: ptr BrokerSignalShared
          # Part D-3 — event courier. Producer is the processing thread
          # (per-event handler runs there now, encode-once-on-emit-thread);
          # consumer is the delivery thread, which polls the ring and
          # fans out foreign callbacks. `deliverySignal` is the delivery
          # thread's broker dispatch signal so the processing thread can
          # wake it after enqueuing an event.
          eventCourier: ptr CborEventCourier
          deliverySignal: ptr BrokerSignalShared
          # Async request response courier. Producer is the processing thread
          # (after the provider runs for a `_callAsync` request); consumer is
          # the delivery thread, which polls the ring and invokes the foreign
          # response callback. Reuses `deliverySignal` to wake the delivery
          # thread, exactly like `eventCourier`.
          respCourier: ptr CborRespCourier

        `ctxEntryIdent` = object
          ctx: BrokerContext
          procThread: Thread[ptr `procThreadArgIdent`]
          delivThread: Thread[ptr `procThreadArgIdent`]
          arg: ptr `procThreadArgIdent`
          active: bool

        `eventCallbackTypeIdent`* = proc(
          ctx: uint32,
          eventName: cstring,
          payloadBuf: pointer,
          payloadLen: int32,
          userData: pointer,
        ) {.cdecl, gcsafe, raises: [].}

        `responseCallbackTypeIdent`* = proc(
          userData: pointer,
          reqId: uint64,
          status: int32,
          respBuf: pointer,
          respLen: int32,
        ) {.cdecl, gcsafe, raises: [].}

      var `ctxsIdent`: seq[ptr `ctxEntryIdent`]
      var `ctxsLockIdent`: Lock
      var `ctxsInitIdent`: Atomic[int]

      # Subscription registry: shared-heap hash table from
      # `api_cbor_subs_registry`. Lazily allocated in `_initialize`.
      var `subsRegIdent`: ptr SubsRegistry
      var `subsHandleIdent`: Atomic[uint64]

      var `nimInitFlagIdent`: Atomic[int]
      var `gcRegFlagIdent` {.threadvar.}: bool
  )

  # ------------------------------------------------------------------
  # `<lib>_version` — static semver baked from `registerBrokerLibrary`.
  # ------------------------------------------------------------------
  let cborVersionFuncName = libName & "_version"
  let cborVersionFuncNameLit = newLit(cborVersionFuncName)
  let cborVersionFuncIdent = ident(cborVersionFuncName)
  let cborVersionConstIdent = ident("g" & libName & "VersionStr")
  # `versionExpr` is either a string literal or a const identifier the caller
  # defines (e.g. a `{.strdefine.}` `git_version`). Binding it to a `string`
  # const and converting in the proc works for both — a const ident can't be a
  # compile-time `cstring` initialiser, but a global string const's `.cstring`
  # is stable for the program lifetime.
  let cborVersionExpr = config.versionExpr
  result.add(
    quote do:
      const `cborVersionConstIdent`: string = `cborVersionExpr`
      proc `cborVersionFuncIdent`*(): cstring {.
          exportc: `cborVersionFuncNameLit`, cdecl, dynlib
      .} =
        `cborVersionConstIdent`.cstring

  )

  # ------------------------------------------------------------------
  # `<lib>_initialize` — Nim runtime + GC setup. Idempotent.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `initFuncIdent`*() {.exportc: `initFuncNameLit`, cdecl, dynlib.} =
        # Step 1: one-time Nim runtime init.
        while true:
          case `nimInitFlagIdent`.load(moAcquire)
          of 2:
            break
          of -1:
            return
          of 1:
            sleep(1)
          else:
            var expected = 0
            if `nimInitFlagIdent`.compareExchange(expected, 1, moAcquire, moRelaxed):
              when compileOption("app", "lib") and not defined(windows):
                let initRes = catch:
                  `nimMainIdent`()
                if initRes.isErr():
                  error "Failed to initialize Nim runtime",
                    library = `libNameLit`, detail = initRes.error.msg
                  `nimInitFlagIdent`.store(-1, moRelease)
                  return
              `nimInitFlagIdent`.store(2, moRelease)
              break

        # Step 2: per-thread foreign GC registration.
        when compileOption("app", "lib"):
          if not `gcRegFlagIdent`:
            when declared(setupForeignThreadGc):
              setupForeignThreadGc()
            `gcRegFlagIdent` = true
          when declared(nimGC_setStackBottom):
            var locals {.volatile, noinit.}: pointer
            locals = addr(locals)
            nimGC_setStackBottom(locals)

        # Step 3: lazy-init the global ctx registry and the subs map/lock.
        var ctxsExpected = 0
        if `ctxsInitIdent`.compareExchange(ctxsExpected, 1, moAcquire, moRelaxed):
          initLock(`ctxsLockIdent`)
          `subsRegIdent` = subsRegistryNew()
          `ctxsInitIdent`.store(2, moRelease)
        else:
          while `ctxsInitIdent`.load(moAcquire) != 2:
            sleep(1)

  )

  # ------------------------------------------------------------------
  # `<lib>_allocBuffer` / `<lib>_freeBuffer`.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `allocBufFuncIdent`*(
          size: int32
      ): pointer {.exportc: `allocBufFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if size <= 0 or size.int > `bufSizeCap`:
          return nil
        allocShared0(size.int)

      proc `freeBufFuncIdent`*(
          buf: pointer
      ) {.exportc: `freeBufFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if not buf.isNil:
          deallocShared(buf)

  )

  # ------------------------------------------------------------------
  # Part D-3 — per-event-type globals.
  #
  # Each event type gets:
  #   * `g<Lib>Cbor<Event>SubsCount: Atomic[int]` — the lock-free
  #     emit-side fast-path discriminator. Bumped by `_subscribe` after
  #     the registry insertion succeeds, decremented by `_unsubscribe`.
  #     Read with `moAcquire` in the per-event handler; if zero, the
  #     handler returns immediately with NO CBOR encode and NO courier
  #     enqueue (the 90 % production case is "no foreign subscriber",
  #     and that case must pay nothing — see PartD plan §1, §5).
  # ------------------------------------------------------------------
  var perEventGlobals = newStmtList()
  for e in eventEntries:
    let subsCountIdent = ident("g" & libName & "Cbor" & e.typeName & "SubsCount")
    perEventGlobals.add(
      quote do:
        var `subsCountIdent`: Atomic[int]
    )
  result.add(perEventGlobals)

  # ------------------------------------------------------------------
  # Part D-3 — name→atomic lookup. The subscribe / unsubscribe entry
  # points receive a `cstring` event name and need to find the right
  # per-event counter to bump / decrement. A generated case statement
  # does the dispatch in O(1) string-equality with no Table allocation.
  # Returns `nil` for unknown names — the subscribe path filters those
  # via `knownEventPredIdent` BEFORE calling, so a nil here is a
  # programming error (the case covers every registered event).
  # ------------------------------------------------------------------
  block:
    var lookupBranches = newStmtList()
    let nameVar = ident("name")
    var caseStmt = nnkCaseStmt.newTree(nameVar)
    for e in eventEntries:
      let subsCountIdent = ident("g" & libName & "Cbor" & e.typeName & "SubsCount")
      caseStmt.add(
        nnkOfBranch.newTree(
          newLit(e.apiName),
          newStmtList(nnkReturnStmt.newTree(nnkAddr.newTree(subsCountIdent))),
        )
      )
    caseStmt.add(nnkElse.newTree(newStmtList(nnkReturnStmt.newTree(newNilLit()))))
    lookupBranches.add(caseStmt)
    let lookupProc = nnkProcDef.newTree(
      postfix(getEventSubsCountIdent, "*"),
      newEmptyNode(),
      newEmptyNode(),
      nnkFormalParams.newTree(
        nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("Atomic"), ident("int"))),
        newIdentDefs(nameVar, ident("string")),
      ),
      nnkPragma.newTree(
        ident("gcsafe"), nnkExprColonExpr.newTree(ident("raises"), nnkBracket.newTree())
      ),
      newEmptyNode(),
      lookupBranches,
    )
    result.add(lookupProc)

  # Part D-3: companion name → static cstring resolver. Takes a cstring
  # (the on-stack one from the courier message) and returns the
  # equivalent **string-literal-backed** cstring — permanently valid,
  # safe for the callback to store across the courier-poll boundary.
  # `else` returns the input pointer as a degraded fallback (the
  # subscribe path already filters unknown events via
  # `knownEventPredIdent`, so this branch should be unreachable in
  # practice).
  block:
    var resolverBranches = newStmtList()
    let nameVar = ident("name")
    var caseStmt = nnkCaseStmt.newTree(newCall(ident("$"), nameVar))
    for e in eventEntries:
      caseStmt.add(
        nnkOfBranch.newTree(
          newLit(e.apiName),
          newStmtList(
            nnkReturnStmt.newTree(newDotExpr(newLit(e.apiName), ident("cstring")))
          ),
        )
      )
    caseStmt.add(nnkElse.newTree(newStmtList(nnkReturnStmt.newTree(nameVar))))
    resolverBranches.add(caseStmt)
    let resolverProc = nnkProcDef.newTree(
      postfix(resolveEventNameCstrIdent, "*"),
      newEmptyNode(),
      newEmptyNode(),
      nnkFormalParams.newTree(ident("cstring"), newIdentDefs(nameVar, ident("cstring"))),
      nnkPragma.newTree(
        ident("gcsafe"), nnkExprColonExpr.newTree(ident("raises"), nnkBracket.newTree())
      ),
      newEmptyNode(),
      resolverBranches,
    )
    result.add(resolverProc)

  # ------------------------------------------------------------------
  # Per-event listener installers — Part D-3 rewrite.
  #
  # Each installer registers an MT-broker listener whose body is the
  # FFI-lane emit-side dispatch:
  #
  #   1. `load(moAcquire)` the per-event subs-count atomic.
  #      If zero → return immediately. No encode, no allocation, no
  #      courier touch. This is the 90 % production hot path.
  #   2. CBOR-encode the event payload **once** into a shared-heap
  #      buffer (emit-thread cost, paid only when subscribers exist).
  #   3. Enqueue an `EventMsg` (eventName + ctx + buf + bufLen) into
  #      the per-context event courier ring; ownership of the buffer
  #      transfers to the consumer (delivery thread). Fire the
  #      delivery thread's broker dispatch signal.
  #   4. Foreign-callback fanout happens on the delivery thread, NOT
  #      here. Slow / reentrant foreign callbacks therefore can't
  #      block the provider that emitted the event (Part D §1a).
  #
  # The installer also:
  #   * registers a `dropAllListeners` companion cleanup hook (PartD
  #     §8a) so when user Nim code calls `<EventType>.dropAllListeners`,
  #     the foreign-subscriber registry is cleared in lock-step.
  #
  # Same-thread fast path: `installAllListenersIdent` is called on the
  # PROCESSING thread (see processing-thread proc), so emit (processing
  # thread) → MT broker same-thread direct asyncSpawn → handler runs
  # on processing thread → does atomic check + encode + courier
  # enqueue (no MT-slab marshal). The delivery thread then receives
  # the opaque buffer via the courier ring.
  # ------------------------------------------------------------------
  var installerNames: seq[string] = @[]
  for e in eventEntries:
    let eventTypeIdent = ident(e.typeName)
    let installerIdent = ident(libName & "Cbor" & e.typeName & "Installer")
    let eventNameLit = newLit(e.apiName)
    let subsCountIdent = ident("g" & libName & "Cbor" & e.typeName & "SubsCount")
    let dropAllHookProcTypeIdent = ident(e.typeName & "MtDropAllHook")
    let setDropAllHookIdent = ident("setDropAll" & e.typeName & "Hook")
    installerNames.add($installerIdent)
    result.add(
      quote do:
        proc `installerIdent`*(ctx: BrokerContext): Result[void, string] =
          # The arg is `arg: ptr <procThreadArgIdent>` — captured by the
          # closure via the caller (`installAllListeners(ctx, arg)`).
          # But since installers run inside the processing-thread proc
          # where `arg` is in scope, we access it through a global
          # bootstrap: the umbrella installer below threads the arg in.
          proc handler(
              evt: `eventTypeIdent`
          ): Future[void] {.async: (raises: []), gcsafe.} =
            # Part D-3 fast path: lock-free atomic discriminator.
            if `subsCountIdent`.load(moAcquire) == 0:
              return
            # CBOR-encode the payload once into a shared-heap buffer.
            # Ownership of `payloadBuf` transfers to the courier on
            # successful enqueue; freed by the delivery-thread poller
            # after the foreign-callback fanout completes.
            var payloadBuf: pointer = nil
            var payloadLen: int = 0
            let encRes = cborEncodeShared(evt, payloadBuf, payloadLen)
            if encRes.isErr:
              return
            # Build the courier message. `eventName` is inlined as
            # NUL-terminated ASCII so the message is pure POD (no GC).
            var msg: CborEventMsg
            let nameLit: cstring = `eventNameLit`.cstring
            var ni = 0
            while ni < CborEventNameMax - 1 and nameLit[ni] != '\0':
              msg.eventName[ni] = nameLit[ni]
              inc ni
            msg.eventName[ni] = '\0'
            msg.ctx = uint32(ctx)
            msg.buf = payloadBuf
            msg.bufLen = int32(payloadLen)
            # Locate the per-context event courier via the ctx table.
            # (Kept simple by walking the small ctx list under the lock;
            # in steady state there's one or a handful of ctxs.) The
            # ctx list is a global `seq` (GC'd container) but we only
            # read pointer fields out of it under the lock — the
            # cast(gcsafe) annotation is required because the
            # generated async handler is gcsafe by signature.
            # reduced-A: route by classCtx (low16) so a SUB-INSTANCE emit
            # (sub ctx shares the library classCtx, distinct instanceCtx) finds
            # the owning library's event courier. `msg.ctx` carries the FULL
            # ctx, so the delivery thread still snapshots subscribers by the
            # exact emitting ctx — per-instance event routing stays exact.
            let libCtxKey = uint32(ctx) and 0x0000FFFF'u32
            var courier: ptr CborEventCourier = nil
            var sig: ptr BrokerSignalShared = nil
            {.cast(gcsafe).}:
              withLock `ctxsLockIdent`:
                for i in 0 ..< `ctxsIdent`.len:
                  let e = `ctxsIdent`[i]
                  if (uint32(e.ctx) and 0x0000FFFF'u32) == libCtxKey and e.active:
                    courier = e.arg.eventCourier
                    sig = e.arg.deliverySignal
                    break
            if courier.isNil:
              # Ctx torn down between subscribe and emit — drop cleanly.
              if not payloadBuf.isNil:
                deallocShared(payloadBuf)
              return
            if not tryEnqueue(addr courier.ring, msg):
              # Ring full — drop the event (fire-and-forget contract).
              # The buffer never entered the ring so we own it.
              if not payloadBuf.isNil:
                deallocShared(payloadBuf)
              # Throttled warn: the first drop, then a geometric count backoff
              # plus a periodic floor (see `recordDrop`). `dropAccount` is only
              # ever touched on this processing thread, so no lock is needed.
              var totalDropped, droppedSinceLog: int64
              if recordDrop(
                courier.dropAccount, monoNowMs(), totalDropped, droppedSinceLog
              ):
                {.cast(gcsafe).}:
                  warn "FFI event courier ring full — delivery thread stalled or blocked; dropping outbound events",
                    event = `eventNameLit`,
                    ringCap = courier.ringCap(),
                    totalDropped = totalDropped,
                    droppedSinceLastLog = droppedSinceLog
              return
            if not sig.isNil:
              fireBrokerSignal(sig)

          let listenRes = `eventTypeIdent`.listen(ctx, handler)
          if listenRes.isErr:
            return Result[void, string].err(listenRes.error)

          # Part D-3 §8a: register the dropAllListeners cleanup hook
          # so that if user Nim code calls `<EventType>.dropAllListeners(ctx)`,
          # the foreign-subscriber registry for this `(ctx, eventName)`
          # is cleared and the atomic counter is reset. Without this
          # hook, foreign subs would orphan (the listener that reads
          # them is gone, but `_subscribe` would still bump the count
          # → wasted encodes; the SubNodes would only release at
          # `_shutdown`'s `subsRegistryFreeForCtx`).
          proc dropAllHook(brokerCtx: BrokerContext) {.gcsafe, raises: [].} =
            # Decrement the shared per-event subs-count by the exact number of
            # subs removed for THIS ctx — never reset to 0, which would silence
            # sibling contexts/instances sharing the event name.
            let removed = subsRegistryRemoveAllForKeyN(
              `subsRegIdent`, uint32(brokerCtx), `eventNameLit`.cstring
            )
            if removed > 0:
              discard `subsCountIdent`.fetchSub(removed, moRelease)

          `eventTypeIdent`.`setDropAllHookIdent`(dropAllHook)
          return Result[void, string].ok()

    )

  # ------------------------------------------------------------------
  # Umbrella installer: called from the processing thread after
  # setupProviders so listeners are live before any foreign caller can
  # subscribe.
  # ------------------------------------------------------------------
  var installerCalls = newStmtList()
  for installerName in installerNames:
    let installerIdent = ident(installerName)
    installerCalls.add(
      newTree(nnkPrefix, ident("?"), newCall(installerIdent, ident("ctx")))
    )
  installerCalls.add(
    nnkReturnStmt.newTree(
      newCall(
        newDotExpr(
          nnkBracketExpr.newTree(ident("Result"), ident("void"), ident("string")),
          ident("ok"),
        )
      )
    )
  )
  let installAllProc = nnkProcDef.newTree(
    postfix(installAllListenersIdent, "*"),
    newEmptyNode(),
    newEmptyNode(),
    nnkFormalParams.newTree(
      nnkBracketExpr.newTree(ident("Result"), ident("void"), ident("string")),
      newIdentDefs(ident("ctx"), ident("BrokerContext")),
    ),
    newEmptyNode(),
    newEmptyNode(),
    installerCalls,
  )
  result.add(installAllProc)

  # ------------------------------------------------------------------
  # `<lib>_subscribe` / `<lib>_unsubscribe`.
  #
  # Subscribe handle convention: 0 == failure (unknown event, allocation
  # error, nil callback for non-probe paths). 1 is reserved as the
  # "supported" sentinel returned for probe calls (cb == nil). Real
  # subscriptions start at 2 to avoid colliding with these reserved
  # values.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `subscribeFuncIdent`*(
          ctx: uint32,
          eventNameC: cstring,
          cb: `eventCallbackTypeIdent`,
          userData: pointer,
      ): uint64 {.exportc: `subscribeFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if eventNameC.isNil:
          return 0'u64
        let name = $eventNameC
        if not `knownEventPredIdent`(name):
          return 0'u64
        if cb.isNil:
          # Probe mode: caller wants to know whether the eventName is
          # supported by this library version. 1 is a sentinel never
          # returned for real subscriptions.
          return 1'u64
        # Real subscription handle: skip 0 (failure) and 1 (probe).
        let h = `subsHandleIdent`.fetchAdd(1, moRelaxed) + 2'u64
        # `eventNameC` is owned by the foreign caller; the registry copies it
        # into shared heap on insertion, so we don't need to keep `name`
        # alive past this call.
        subsRegistryAdd(`subsRegIdent`, ctx, eventNameC, h, cast[pointer](cb), userData)
        # Part D-3: bump the per-event subs-count atomic AFTER the
        # registry insertion. moRelease pairs with the emit-side's
        # moAcquire load — if the load sees > 0, the registry already
        # contains this subscription (the snapshot the delivery thread
        # takes will see it on the next emit, modulo single-window
        # race that's documented as expected).
        let counter = `getEventSubsCountIdent`(name)
        if not counter.isNil:
          discard counter[].fetchAdd(1, moRelease)
        return h

      proc `unsubscribeFuncIdent`*(
          ctx: uint32, eventNameC: cstring, handle: uint64
      ): int32 {.exportc: `unsubscribeFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if eventNameC.isNil:
          return -1'i32
        let name = $eventNameC
        if handle == 0'u64:
          # Drop every subscription for this (ctx, name). Decrement the
          # shared per-event counter by the exact number removed — never
          # reset to 0, which would silence other ctxs/instances sharing
          # the event name (the counter is a process-global aggregate gate).
          let removed = subsRegistryRemoveAllForKeyN(`subsRegIdent`, ctx, eventNameC)
          if removed >= 0:
            if removed > 0:
              let counter = `getEventSubsCountIdent`(name)
              if not counter.isNil:
                discard counter[].fetchSub(removed, moRelease)
            return 0'i32
          return removed
        let res = subsRegistryRemoveOne(`subsRegIdent`, ctx, eventNameC, handle)
        if res == 0:
          # Part D-3: decrement after a successful removal.
          let counter = `getEventSubsCountIdent`(name)
          if not counter.isNil:
            discard counter[].fetchSub(1, moRelease)
        return res

  )

  # ------------------------------------------------------------------
  # Delivery thread proc (one per ctx). Part D, phase D-3: pure event
  # courier consumer. Polls `arg.eventCourier.ring` for opaque CBOR
  # buffers produced by the processing thread, snapshots the
  # foreign-subscriber list for `(ctx, eventName)`, fans out the
  # synchronous foreign callbacks, then frees the buffer.
  #
  # This thread does NOT install MT EventBroker listeners (those moved
  # back to the processing thread in D-3 to recover the same-thread
  # fast path — the FFI lane forks at the per-event handler instead of
  # at the MT broker dispatch layer). The thread still owns a chronos
  # event loop (via `ensureBrokerDispatchStarted`) so the
  # `eventCourierPoll` proc registered below runs whenever the
  # delivery signal fires.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `delivThreadProcIdent`(arg: ptr `procThreadArgIdent`) {.thread.} =
        setThreadBrokerContext(arg.ctx)

        # Publish this thread's broker dispatch signal so the processing
        # thread (the producer) can wake us after enqueuing an event.
        arg.deliverySignal = getOrInitBrokerSignal()

        # Event-courier poller — drains the ring, fans out, frees.
        # `subsRegistrySnapshot` allocates the snapshot on shared heap;
        # we free it via `subsRegistrySnapshotFree` after the fanout.
        proc eventCourierPoll(): int {.gcsafe, raises: [].} =
          var didWork = 0
          while true:
            var m: CborEventMsg
            if not tryDequeue(addr arg.eventCourier.ring, m):
              break
            didWork = 1
            # The eventName was inlined NUL-terminated into the courier
            # message; that storage is the poll proc's stack frame after
            # `tryDequeue` and dies the moment this proc returns. Foreign
            # callbacks legitimately store the eventName cstring across
            # calls (the typemappingtestlib test does), so we resolve to
            # a STATIC string-literal cstring via the per-library
            # generated resolver before invoking the callback.
            let stackNameC = cast[cstring](addr m.eventName[0])
            let nameC = `resolveEventNameCstrIdent`(stackNameC)
            var snap: ptr UncheckedArray[SubSnapshot] = nil
            var snapLen: int = 0
            subsRegistrySnapshot(`subsRegIdent`, m.ctx, nameC, snap, snapLen)
            if snapLen > 0 and not m.buf.isNil:
              for i in 0 ..< snapLen:
                let cbPtr = snap[i].cb
                if cbPtr.isNil:
                  continue
                let cbTyped = cast[`eventCallbackTypeIdent`](cbPtr)
                cbTyped(m.ctx, nameC, m.buf, m.bufLen, snap[i].userData)
            if snapLen > 0:
              subsRegistrySnapshotFree(snap)
            if not m.buf.isNil:
              deallocShared(m.buf)
          didWork

        # Async-response poller — drains the response courier and invokes the
        # foreign response callback for each `<lib>_callAsync`. Runs on this
        # (delivery) thread, off the processing thread, exactly like event
        # fanout. `m.buf` is library-owned and freed after the callback returns;
        # the per-call `asyncDepth` reservation is released here.
        proc respCourierPoll(): int {.gcsafe, raises: [].} =
          var didWork = 0
          while true:
            var m: CborRespMsg
            if not tryDequeueResp(arg.respCourier, m):
              break
            didWork = 1
            let cbPtr = m.cb
            if not cbPtr.isNil:
              let cbTyped = cast[`responseCallbackTypeIdent`](cbPtr)
              cbTyped(m.userData, m.reqId, m.status, m.buf, m.bufLen)
            if not m.buf.isNil:
              deallocShared(m.buf)
            asyncDepthDec(arg.courier)
          didWork

        registerBrokerPoller(eventCourierPoll)
        registerBrokerPoller(respCourierPoll)
        ensureBrokerDispatchStarted()

        arg.deliveryReady.store(1, moRelease)

        proc awaitShutdown(flag: ptr Atomic[int]) {.async: (raises: []).} =
          while flag[].load(moAcquire) != 1:
            let s = catch:
              await sleepAsync(milliseconds(5))
            if s.isErr():
              discard

        waitFor awaitShutdown(addr arg.shutdownFlag)
        # Drain + tear down the dispatch loop before this thread exits.
        # Any in-flight foreign callback runs synchronously inside
        # eventCourierPoll and returns before the loop exits. Buffers
        # still queued in the courier ring at this point are freed by
        # `drainAndFree(arg.eventCourier)` in `_shutdown`.
        # teardownBrokerThread = stopBrokerDispatchHere + drainPendingRingFrees
        # + closeThreadDispatcherSelector, latched so the automatic
        # onThreadDestruction hook does not run it a second time.
        teardownBrokerThread()

  )

  # ------------------------------------------------------------------
  # Processing thread proc (one per ctx). Runs setupProviders then loops
  # on a chronos event loop until shutdownFlag is set.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `procThreadProcIdent`(arg: ptr `procThreadArgIdent`) {.thread.} =
        setThreadBrokerContext(arg.ctx)

        when compiles(setupProviders(arg.ctx).isErr()):
          let setupCatchRes = catch:
            setupProviders(arg.ctx)
          if setupCatchRes.isErr():
            arg.processingErrorMessage =
              allocCStringCopy("setupProviders raised: " & setupCatchRes.error.msg)
            arg.processingReady.store(-1, moRelease)
            return
          let setupRes = setupCatchRes.get()
          if setupRes.isErr():
            arg.processingErrorMessage = allocCStringCopy(setupRes.error())
            arg.processingReady.store(-1, moRelease)
            return
        elif compiles(setupProviders(arg.ctx)):
          let setupCatchRes = catch:
            setupProviders(arg.ctx)
          if setupCatchRes.isErr():
            arg.processingErrorMessage =
              allocCStringCopy("setupProviders raised: " & setupCatchRes.error.msg)
            arg.processingReady.store(-1, moRelease)
            return

        # Part D phase D-3: event listener installation runs on the
        # PROCESSING thread (back from the D-2 delivery-thread arm) so
        # that emit (processing thread) → MT broker takes the
        # same-thread direct asyncSpawn fast path → per-event handler
        # runs here on the processing thread → atomic-check + CBOR
        # encode + courier enqueue → delivery thread receives the
        # opaque buffer through `arg.eventCourier.ring` and fans out
        # foreign callbacks. Net: no MT-slab marshal in the FFI lane,
        # foreign callbacks still run off the processing thread.
        let installCatchRes = catch:
          `installAllListenersIdent`(arg.ctx)
        if installCatchRes.isErr():
          arg.processingErrorMessage = allocCStringCopy(
            "event listener install raised: " & installCatchRes.error.msg
          )
          arg.processingReady.store(-1, moRelease)
          return
        let installRes = installCatchRes.get()
        if installRes.isErr():
          arg.processingErrorMessage =
            allocCStringCopy("event listener install failed: " & installRes.error())
          arg.processingReady.store(-1, moRelease)
          return

        # ----------------------------------------------------------------
        # Part C — buffer courier. The processing thread owns CBOR decode,
        # the provider call, and CBOR encode. A foreign `<lib>_call` hands
        # us a raw request buffer over `arg.courier.chan` and blocks on a
        # response slot; we wake on the shared broker dispatch signal.
        # ----------------------------------------------------------------
        # Shared by both courier handlers below: turn a resolved dispatch
        # outcome into the (status, respBuf, respLen) triple the delivery paths
        # hand back. `known == false` → -4 unknown apiName; `dispErr` → -10
        # provider error; otherwise the CBOR bytes are copied into a fresh
        # shared buffer (nil/0 for an empty payload). Timeout (-12, async-only)
        # is decided by the async handler and never flows through here.
        proc encodeApiResp(
            apiName: string, known: bool, dispErr: bool, respBytes: seq[byte]
        ): tuple[status: int32, respBuf: pointer, respLen: int32] {.gcsafe, raises: [].} =
          if not known:
            let em = "unknown apiName: " & apiName
            let b = allocShared0(em.len)
            if em.len > 0:
              copyMem(b, unsafeAddr em[0], em.len)
            return (ApiStatusUnknownApi, b, int32(em.len))
          if dispErr:
            return (ApiStatusProviderErr, nil, 0'i32)
          if respBytes.len > 0:
            let b = allocShared0(respBytes.len)
            copyMem(b, unsafeAddr respBytes[0], respBytes.len)
            return (ApiStatusOk, b, int32(respBytes.len))
          return (ApiStatusOk, nil, 0'i32)

        proc handleCourierMsg(m: CborCallMsg) {.async: (raises: []), gcsafe.} =
          # Copy the request bytes off the shared buffer, then free it —
          # ownership of `m.reqBuf` transferred to us via the channel.
          var nimReq = newSeq[byte](m.reqLen.int)
          if m.reqLen > 0 and not m.reqBuf.isNil:
            copyMem(addr nimReq[0], m.reqBuf, m.reqLen.int)
          if not m.reqBuf.isNil:
            deallocShared(m.reqBuf)
          let apiName = $cast[cstring](addr m.apiName[0])
          if apiName == `releaseApiNameLit`:
            # reduced-A: per-context teardown control op (from
            # `<lib>_releaseInstance`). Clears providers + listeners for the
            # addressed ctx on this (processing) thread, then completes the slot.
            `releaseCtxProcIdent`(BrokerContext(m.targetCtx))
            completeSlot(arg.courier, m.slotIdx.int, nil, 0'i32, 0'i32)
            return
          if m.slotIdx < 0'i32:
            # Slot-free signal (`<lib>_call` enqueued it with slotIdx = -1). Run
            # the one-way adapter — it decodes the payload and calls `signal()`
            # (same-thread fast path). No response slot to complete. Release the
            # shutdown gate here, mirroring the async path (the foreign caller
            # already returned Ok at enqueue time).
            let sigCtx =
              if m.targetCtx != 0'u32:
                BrokerContext(m.targetCtx)
              else:
                arg.ctx
            await `signalDispatchProcIdent`(apiName, sigCtx, nimReq)
            discard arg.courier.inFlight.fetchSub(1, moAcquireRelease)
            return
          let known = `knownNamePredIdent`(apiName)
          var dispErr = false
          var respBytes: seq[byte]
          if known:
            # reduced-A: dispatch against the FULL ctx the caller addressed
            # (sub-instance ctx for create-instance subs; == arg.ctx otherwise),
            # so the broker provider keyed by the sub ctx is reached. Falls back
            # to arg.ctx for legacy messages where targetCtx was never set (0).
            let dispCtx =
              if m.targetCtx != 0'u32:
                BrokerContext(m.targetCtx)
              else:
                arg.ctx
            let dispRes = catch:
              await `dispatchProcIdent`(apiName, dispCtx, nimReq)
            if dispRes.isErr():
              dispErr = true
            else:
              respBytes = dispRes.get()
          let (status, respBuf, respLen) =
            encodeApiResp(apiName, known, dispErr, respBytes)
          completeSlot(arg.courier, m.slotIdx.int, respBuf, respLen, status)

        # Async sibling of `handleCourierMsg`. Same dispatch, but instead of
        # waking a blocked foreign caller via the slot/Cond, it hands the
        # response to the delivery thread (response courier) which invokes the
        # foreign response callback. No slot is involved. The `inFlight`
        # shutdown gate is released here (processing thread done with the
        # request); the `asyncDepth` backpressure reservation is released later
        # on the delivery thread, after the callback fires.
        proc handleAsyncCourierMsg(
            m: CborAsyncCallMsg
        ) {.async: (raises: []), gcsafe.} =
          var nimReq = newSeq[byte](m.reqLen.int)
          if m.reqLen > 0 and not m.reqBuf.isNil:
            copyMem(addr nimReq[0], m.reqBuf, m.reqLen.int)
          if not m.reqBuf.isNil:
            deallocShared(m.reqBuf)
          let apiName = $cast[cstring](addr m.apiName[0])
          let known = `knownNamePredIdent`(apiName)
          var dispErr = false
          var respBytes: seq[byte]
          var timedOut = false
          if known:
            let dispCtx =
              if m.targetCtx != 0'u32:
                BrokerContext(m.targetCtx)
              else:
                arg.ctx
            let dispFut = `dispatchProcIdent`(apiName, dispCtx, nimReq)
            # Dispatch-scoped timeout. `timeoutMs == 0` means infinite — fall
            # through and await directly. Otherwise RACE the dispatch against a
            # chronos timer. We use `race` (not `withTimeout`) deliberately:
            # `withTimeout` cancels the dispatch on expiry, and the broker /
            # provider machinery swallows that cancellation into a normal
            # completion — masking the timeout. `race` leaves the loser running
            # and we decide by `dispFut.finished()`. Because this is a single
            # coroutine with a mutually-exclusive outcome, exactly ONE response
            # is enqueued below; a late provider completion resolves a future
            # nobody reads and is discarded — the callback never double-fires.
            if m.timeoutMs != 0'u32:
              let timerFut = sleepAsync(milliseconds(m.timeoutMs.int64))
              let raceRes = catch:
                await race(dispFut, timerFut)
              timedOut = (not raceRes.isErr()) and (not dispFut.finished())
              if not timerFut.finished():
                timerFut.cancelSoon()
            if timedOut:
              # Budget exceeded: best-effort-cancel the provider. We do NOT read
              # dispFut — its (late) result is dropped. Status is set to -12 below.
              dispFut.cancelSoon()
            else:
              # Completed in time, or infinite timeout: `await dispFut` returns
              # its already-available (or awaited) result.
              let dispRes = catch:
                await dispFut
              if dispRes.isErr():
                dispErr = true
              else:
                respBytes = dispRes.get()
          var status: int32 = 0
          var respBuf: pointer = nil
          var respLen: int32 = 0
          if timedOut:
            status = ApiStatusTimeout
          else:
            let enc = encodeApiResp(apiName, known, dispErr, respBytes)
            status = enc.status
            respBuf = enc.respBuf
            respLen = enc.respLen
          var rmsg: CborRespMsg
          rmsg.cb = m.cb
          rmsg.userData = m.userData
          rmsg.reqId = m.reqId
          rmsg.status = status
          rmsg.buf = respBuf
          rmsg.bufLen = respLen
          # Release the shutdown gate before handing off — the processing
          # thread is finished with this request either way.
          discard arg.courier.inFlight.fetchSub(1, moAcquireRelease)
          if not tryEnqueueResp(arg.respCourier, rmsg):
            # Response ring full. Cannot happen while outstanding async calls
            # are bounded to <= ring cap (see `asyncDepth`), but stay safe: free
            # the buffer, release the depth reservation (the callback will not
            # fire for this lost response), and drop.
            if not respBuf.isNil:
              deallocShared(respBuf)
            asyncDepthDec(arg.courier)
          elif not arg.deliverySignal.isNil:
            fireBrokerSignal(arg.deliverySignal)

        # Drained by the shared `brokerDispatchLoop` whenever the dispatch
        # signal fires. Each message is handled on its own spawned
        # coroutine so a slow provider does not stall the drain.
        proc courierPoll(): int {.gcsafe, raises: [].} =
          var didWork = 0
          while true:
            var m: CborCallMsg
            if not tryDequeue(addr arg.courier.ring, m):
              break
            asyncSpawn handleCourierMsg(m)
            didWork = 1
          didWork

        # Async-call poller — drains the separate async ring. Woken by the same
        # processing-thread dispatch signal that `<lib>_callAsync` fires.
        proc asyncCourierPoll(): int {.gcsafe, raises: [].} =
          var didWork = 0
          while true:
            var m: CborAsyncCallMsg
            if not tryDequeueAsync(arg.courier, m):
              break
            asyncSpawn handleAsyncCourierMsg(m)
            didWork = 1
          didWork

        # Publish this thread's dispatch signal so a foreign `<lib>_call`
        # can wake us, register the courier poller, and start the loop.
        # Done BEFORE `processingReady = 1` so the first `_call` (which can
        # only arrive after `createContext` returns) is always serviced.
        arg.courierSignal = getOrInitBrokerSignal()
        registerBrokerPoller(courierPoll)
        registerBrokerPoller(asyncCourierPoll)
        ensureBrokerDispatchStarted()

        arg.processingReady.store(1, moRelease)

        proc awaitShutdown(flag: ptr Atomic[int]) {.async: (raises: []).} =
          while flag[].load(moAcquire) != 1:
            let s = catch:
              await sleepAsync(milliseconds(5))
            if s.isErr():
              discard

        waitFor awaitShutdown(addr arg.shutdownFlag)
        # Part C: tear down the dispatch-loop coroutine cleanly before the
        # thread exits. `_shutdown` waits for `courier.inFlight` to reach 0
        # (while this thread is still handling) before it sets
        # `shutdownFlag`, so no courier message is in flight here.
        # teardownBrokerThread = stopBrokerDispatchHere + drainPendingRingFrees
        # + closeThreadDispatcherSelector, latched so the automatic
        # onThreadDestruction hook does not run it a second time.
        teardownBrokerThread()

  )

  # ------------------------------------------------------------------
  # `<lib>_createContext` — spawn delivery + processing threads, await ready.
  # `<lib>_shutdown` — signal, join both, free.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `createContextFuncIdent`*(
          errOut: ptr cstring
      ): uint32 {.exportc: `createContextFuncNameLit`, cdecl, dynlib.} =
        `initFuncIdent`()
        ensureForeignThreadGc()

        # Skip BrokerContext value 0 — `<lib>_createContext` reserves 0
        # as the failure return code visible to foreign callers.
        var bctx = NewBrokerContext()
        while uint32(bctx) == 0'u32:
          bctx = NewBrokerContext()
        # reduced-A: record this library's event-listener installer keyed by its
        # classCtx so create-instance requests can install courier listeners for
        # sub-instance ctxs (which share this classCtx).
        registerApiCtxListenerInstaller(classCtx(bctx), `installAllListenersIdent`)
        let arg =
          cast[ptr `procThreadArgIdent`](allocShared0(sizeof(`procThreadArgIdent`)))
        arg.ctx = bctx
        arg.shutdownFlag.store(0, moRelaxed)
        arg.processingReady.store(0, moRelaxed)
        arg.deliveryReady.store(0, moRelaxed)
        arg.processingErrorMessage = nil
        arg.deliveryErrorMessage = nil
        # Part C — courier: 64 response slots = initial ceiling on concurrent
        # in-flight SYNC `<lib>_call`s (grows to 4x). The async window is a
        # separate, fixed ceiling (`asyncQueueDepth`, default 64) — full => -6.
        arg.courier = newCborCourier(64, `asyncQueueDepthLit`)
        arg.courierSignal = nil
        # Part D-3 — event courier: 256-slot ring (burst capacity, not
        # concurrency bound; producer is fire-and-forget). A full ring
        # drops the event with a diagnostic. Re-tunable after D-6 bench.
        arg.eventCourier = newCborEventCourier(256)
        arg.deliverySignal = nil
        # Async-response courier: sized to the call courier's async in-flight
        # ceiling so a bounded set of outstanding `<lib>_callAsync`s can never
        # overflow the ring. Drained by the delivery thread.
        arg.respCourier = newCborRespCourier(`asyncQueueDepthLit`)

        let entry = cast[ptr `ctxEntryIdent`](allocShared0(sizeof(`ctxEntryIdent`)))
        entry.ctx = bctx
        entry.arg = arg
        entry.active = true

        # Part D — spawn delivery thread BEFORE the processing thread so
        # the delivery thread is live (and can receive cross-thread events)
        # before any provider emits.
        let delivCreateRes = catch:
          createThread(entry.delivThread, `delivThreadProcIdent`, arg)
        if delivCreateRes.isErr():
          if not errOut.isNil:
            errOut[] = allocCStringCopy(
              "Failed to spawn delivery thread: " & delivCreateRes.error.msg
            )
          freeCborCourier(arg.courier)
          drainAndFree(arg.eventCourier)
          freeCborRespCourier(arg.respCourier)
          deallocShared(arg)
          deallocShared(entry)
          return 0'u32

        # Poll for deliveryReady.
        block:
          var waitedMs = 0
          const timeoutMs = 5000
          var status = 0
          while waitedMs < timeoutMs:
            status = arg.deliveryReady.load(moAcquire).int
            if status != 0:
              break
            sleep(1)
            inc waitedMs
          if status != 1:
            arg.shutdownFlag.store(1, moRelease)
            joinThread(entry.delivThread)
            if not errOut.isNil:
              if not arg.deliveryErrorMessage.isNil:
                errOut[] = arg.deliveryErrorMessage
                arg.deliveryErrorMessage = nil
              else:
                errOut[] = allocCStringCopy("delivery thread did not become ready")
            freeCborCourier(arg.courier)
            drainAndFree(arg.eventCourier)
            freeCborRespCourier(arg.respCourier)
            deallocShared(arg)
            deallocShared(entry)
            return 0'u32

        # Spawn processing thread.
        let createRes = catch:
          createThread(entry.procThread, `procThreadProcIdent`, arg)
        if createRes.isErr():
          if not errOut.isNil:
            errOut[] = allocCStringCopy(
              "Failed to spawn processing thread: " & createRes.error.msg
            )
          arg.shutdownFlag.store(1, moRelease)
          joinThread(entry.delivThread)
          freeCborCourier(arg.courier)
          drainAndFree(arg.eventCourier)
          freeCborRespCourier(arg.respCourier)
          deallocShared(arg)
          deallocShared(entry)
          return 0'u32

        # Poll for processingReady (or failure).
        var waitedMs = 0
        const timeoutMs = 5000
        var status = 0
        while waitedMs < timeoutMs:
          status = arg.processingReady.load(moAcquire).int
          if status != 0:
            break
          sleep(1)
          inc waitedMs

        if status != 1:
          arg.shutdownFlag.store(1, moRelease)
          joinThread(entry.delivThread)
          joinThread(entry.procThread)
          if not errOut.isNil:
            if not arg.processingErrorMessage.isNil:
              errOut[] = arg.processingErrorMessage
              arg.processingErrorMessage = nil
            else:
              errOut[] = allocCStringCopy("processing thread did not become ready")
          freeCborCourier(arg.courier)
          drainAndFree(arg.eventCourier)
          freeCborRespCourier(arg.respCourier)
          deallocShared(arg)
          deallocShared(entry)
          return 0'u32

        withLock `ctxsLockIdent`:
          `ctxsIdent`.add(entry)
        return uint32(bctx)

      proc `shutdownFuncIdent`*(
          ctx: uint32
      ): int32 {.exportc: `shutdownFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        var entryToShutdown: ptr `ctxEntryIdent` = nil
        withLock `ctxsLockIdent`:
          for i in 0 ..< `ctxsIdent`.len:
            let e = `ctxsIdent`[i]
            if uint32(e.ctx) == ctx and e.active:
              e.active = false
              entryToShutdown = e
              break
        if entryToShutdown.isNil:
          return -1'i32

        # Part C — drain in-flight `_call`s BEFORE stopping the processing
        # thread. `active` is already false (set under the lock above) so
        # no new call enters; in-flight calls complete (the processing
        # thread is still handling) and decrement `inFlight`. Only once
        # inFlight reaches 0 is the channel guaranteed quiescent, so
        # signalling shutdown + freeing the courier cannot race a `_call`.
        # A bounded timeout guards against a hung provider (best-effort).
        block:
          let courier = entryToShutdown.arg.courier
          if not courier.isNil:
            var waitedMs = 0
            const drainTimeoutMs = 5000
            while courier.inFlight.load(moAcquire) > 0 and waitedMs < drainTimeoutMs:
              sleep(1)
              inc waitedMs

        entryToShutdown.arg.shutdownFlag.store(1, moRelease)
        # Part D: join delivery thread first — it must finish any
        # in-flight foreign callbacks before we tear down the processing
        # thread (which owns the providers that emitted those events).
        joinThread(entryToShutdown.delivThread)
        joinThread(entryToShutdown.procThread)
        # Free this lib's subscription state for the whole class after both
        # threads are joined — no concurrent listener can be mid-snapshot.
        # The sweep drains the lib ctx (instanceCtx 0) AND every still-alive
        # sub-instance sharing its classCtx, decrementing each per-event
        # global subs-count by the exact number removed so the shared gate
        # stays a correct running sum for sibling lib contexts.
        proc onFreed(name: cstring, count: int32) {.gcsafe, raises: [].} =
          let counter = `getEventSubsCountIdent`($name)
          if not counter.isNil and count > 0:
            discard counter[].fetchSub(count, moRelease)

        subsRegistryFreeForClass(`subsRegIdent`, classCtx(BrokerContext(ctx)), onFreed)
        if not entryToShutdown.arg.processingErrorMessage.isNil:
          freeCString(entryToShutdown.arg.processingErrorMessage)
        if not entryToShutdown.arg.deliveryErrorMessage.isNil:
          freeCString(entryToShutdown.arg.deliveryErrorMessage)
        # Async responses: any still queued in the response courier when the
        # delivery thread joined could not be delivered in time. Release the
        # foreign caller's continuation by invoking each callback with a
        # shutdown status (-11) and a nil buffer, so no `userData` is leaked.
        # Both threads are joined here, so this drain has no concurrent consumer.
        block:
          let rc = entryToShutdown.arg.respCourier
          if not rc.isNil:
            var rm: CborRespMsg
            while tryDequeueResp(rc, rm):
              if not rm.cb.isNil:
                let cbTyped = cast[`responseCallbackTypeIdent`](rm.cb)
                cbTyped(rm.userData, rm.reqId, ApiStatusShutdown, nil, 0'i32)
              if not rm.buf.isNil:
                deallocShared(rm.buf)
              # Symmetry with `respCourierPoll`, which releases one depth
              # reservation per delivered response. Harmless today (the courier
              # is freed just below), but keeps `asyncDepth` a correct running
              # sum if the courier ever outlives a single shutdown.
              asyncDepthDec(entryToShutdown.arg.courier)
        # Part C — free the courier after both threads joined.
        freeCborCourier(entryToShutdown.arg.courier)
        # Part D-3 — free the event courier (drains any messages left
        # in the ring, freeing their buffers) after both threads joined.
        drainAndFree(entryToShutdown.arg.eventCourier)
        # Free the (now-empty) response courier.
        freeCborRespCourier(entryToShutdown.arg.respCourier)
        deallocShared(entryToShutdown.arg)

        withLock `ctxsLockIdent`:
          for i in 0 ..< `ctxsIdent`.len:
            if `ctxsIdent`[i] == entryToShutdown:
              `ctxsIdent`.del(i)
              break
        deallocShared(entryToShutdown)
        return 0'i32

  )

  # ------------------------------------------------------------------
  # `<lib>_call` — string dispatch over the generated case statement.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `callFuncIdent`*(
          ctx: uint32,
          apiNameC: cstring,
          reqBuf: pointer,
          reqLen: int32,
          respBufOut: ptr pointer,
          respLenOut: ptr int32,
      ): int32 {.exportc: `callFuncNameLit`, cdecl, dynlib.} =
        # Part C — buffer courier. This runs on the foreign caller's
        # thread and does NO CBOR decode and NO chronos loop: it hands the
        # raw request buffer to the processing thread and blocks on a
        # response slot. `reqBuf` ownership transfers to the processing
        # thread on a successful `send`; every error path frees it here.
        ensureForeignThreadGc()
        if respBufOut.isNil or respLenOut.isNil:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -1'i32
        respBufOut[] = nil
        respLenOut[] = 0
        if apiNameC.isNil:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -2'i32
        if reqLen < 0 or reqLen.int > `bufSizeCap`:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -3'i32
        let nameLen = apiNameC.len
        if nameLen >= CborApiNameMax:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -2'i32

        # Resolve ctx -> courier. `inFlight` is bumped under the SAME lock
        # `_shutdown` uses to flip `active`, so once shutdown has run no
        # new call can enter; `_shutdown` then waits for inFlight -> 0.
        # reduced-A: route by classCtx (low16). A library context is registered
        # with instanceCtx 0; a sub-instance ctx shares the same classCtx but
        # carries a distinct instanceCtx, so masking it off recovers the owning
        # library context's courier. The full `ctx` is carried in the message
        # (targetCtx) so the processing thread dispatches against the sub ctx.
        let libCtxKey = ctx and 0x0000FFFF'u32
        var courier: ptr CborCourier = nil
        var courierSig: ptr BrokerSignalShared = nil
        withLock `ctxsLockIdent`:
          for i in 0 ..< `ctxsIdent`.len:
            let e = `ctxsIdent`[i]
            if uint32(e.ctx) == libCtxKey and e.active:
              courier = e.arg.courier
              courierSig = e.arg.courierSignal
              discard courier.inFlight.fetchAdd(1, moAcquireRelease)
              break
        if courier.isNil:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -5'i32

        # SignalBroker(API): slot-free one-way path. No response slot is
        # claimed and the caller does not block — both failure modes resolve
        # here on the caller's thread. `signalHasHandler` is a lock-free atomic
        # load; a false is a fast ProviderErr with no cross-thread hop. The
        # message rides the SAME courier ring with slotIdx = -1 (the processing
        # thread's `handleCourierMsg` recognises the sentinel, runs the one-way
        # adapter, and decrements `inFlight` — which stays bumped until then).
        let sigApiName = $apiNameC
        if `isSignalNamePredIdent`(sigApiName):
          if not `signalHasHandlerPredIdent`(sigApiName):
            discard courier.inFlight.fetchSub(1, moAcquireRelease)
            if not reqBuf.isNil:
              deallocShared(reqBuf)
            return ApiStatusProviderErr
          var smsg: CborCallMsg
          if nameLen > 0:
            copyMem(addr smsg.apiName[0], apiNameC, nameLen)
          smsg.reqBuf = reqBuf
          smsg.reqLen = reqLen
          smsg.slotIdx = -1'i32 # signal sentinel: no response slot
          smsg.targetCtx = ctx
          if not tryEnqueue(addr courier.ring, smsg):
            discard courier.inFlight.fetchSub(1, moAcquireRelease)
            if not reqBuf.isNil:
              deallocShared(reqBuf)
            return ApiStatusAgain
          if not courierSig.isNil:
            fireBrokerSignal(courierSig)
          return ApiStatusOk

        let slotIdx = claimSlot(courier)
        if slotIdx < 0:
          discard courier.inFlight.fetchSub(1, moAcquireRelease)
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return ApiStatusAgain

        var msg: CborCallMsg
        if nameLen > 0:
          copyMem(addr msg.apiName[0], apiNameC, nameLen)
        # `msg` is stack-zero-initialised, so apiName stays NUL-terminated.
        msg.reqBuf = reqBuf
        msg.reqLen = reqLen
        msg.slotIdx = int32(slotIdx)
        msg.targetCtx = ctx # full ctx (sub-instance routing, reduced-A)
        # Ownership of reqBuf transfers into the ring here. Enqueue is
        # backstopped by the slot claim above (ring.cap == slotCount), so
        # a false return is a programming error rather than backpressure;
        # we still handle it cleanly: undo the slot + inFlight, free
        # reqBuf, return -6.
        if not tryEnqueue(addr courier.ring, msg):
          releaseSlot(courier, slotIdx)
          discard courier.inFlight.fetchSub(1, moAcquireRelease)
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return ApiStatusAgain
        if not courierSig.isNil:
          fireBrokerSignal(courierSig)

        let res = waitSlot(courier, slotIdx)
        releaseSlot(courier, slotIdx)
        respBufOut[] = res.respBuf
        respLenOut[] = res.respLen
        discard courier.inFlight.fetchSub(1, moAcquireRelease)
        return res.status

  )

  # ------------------------------------------------------------------
  # `<lib>_callAsync` — fire-and-forget sibling of `<lib>_call`. Enqueues onto
  # the courier's SEPARATE async ring and returns immediately (no slot, no
  # Cond block). The response is fanned back later through the event delivery
  # thread to `cb(userData, reqId, status, respBuf, respLen)`. `userData` is an
  # opaque correlation handle, never interpreted, handed back verbatim. `reqId`
  # is carried for the caller's logging/cancel/idempotency only.
  #   0  -> enqueued (callback will fire later)
  #  -2  -> nil/oversized apiName            -3 -> bad reqLen
  #  -5  -> unknown/torn-down ctx            -6 -> EAGAIN (async ring full / ceiling)
  #  -7  -> nil callback
  # respBuf delivered to the callback is library-owned and freed after the
  # callback returns — the callback must NOT free it and must copy out anything
  # it needs to retain.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `callAsyncFuncIdent`*(
          ctx: uint32,
          apiNameC: cstring,
          reqBuf: pointer,
          reqLen: int32,
          reqId: uint64,
          timeoutMs: uint32,
          cb: `responseCallbackTypeIdent`,
          userData: pointer,
      ): int32 {.exportc: `callAsyncFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if apiNameC.isNil:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -2'i32
        if reqLen < 0 or reqLen.int > `bufSizeCap`:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -3'i32
        if cb.isNil:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -7'i32
        let nameLen = apiNameC.len
        if nameLen >= CborApiNameMax:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -2'i32

        # Resolve ctx -> courier, same routing + `inFlight` gate as `_call`.
        let libCtxKey = ctx and 0x0000FFFF'u32
        var courier: ptr CborCourier = nil
        var courierSig: ptr BrokerSignalShared = nil
        withLock `ctxsLockIdent`:
          for i in 0 ..< `ctxsIdent`.len:
            let e = `ctxsIdent`[i]
            if uint32(e.ctx) == libCtxKey and e.active:
              courier = e.arg.courier
              courierSig = e.arg.courierSignal
              discard courier.inFlight.fetchAdd(1, moAcquireRelease)
              break
        if courier.isNil:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -5'i32

        # Signals are one-way: a completion callback would carry no information
        # not already returned synchronously by the slot-free `<lib>_call`, and
        # a signal burst would starve the bounded async window real async
        # requests depend on. Reject here (before reserving a depth slot).
        if `isSignalNamePredIdent`($apiNameC):
          discard courier.inFlight.fetchSub(1, moAcquireRelease)
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return ApiStatusOneWay

        var msg: CborAsyncCallMsg
        if nameLen > 0:
          copyMem(addr msg.apiName[0], apiNameC, nameLen)
        # `msg` is stack-zero-initialised, so apiName stays NUL-terminated.
        msg.reqBuf = reqBuf
        msg.reqLen = reqLen
        msg.targetCtx = ctx # full ctx (sub-instance routing, reduced-A)
        msg.reqId = reqId
        msg.timeoutMs = timeoutMs # 0 = infinite; N = N ms (dispatch-scoped)
        msg.cb = cast[pointer](cb)
        msg.userData = userData
        # Ownership of reqBuf transfers into the async ring on success.
        # `tryEnqueueAsync` reserves the in-flight depth slot (bounding
        # outstanding async calls) and rolls it back itself on failure.
        if not tryEnqueueAsync(courier, msg):
          discard courier.inFlight.fetchSub(1, moAcquireRelease)
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return ApiStatusAgain
        if not courierSig.isNil:
          fireBrokerSignal(courierSig)
        return 0'i32

  )

  # ------------------------------------------------------------------
  # reduced-A (A4): `<lib>_releaseInstance(ctx)` — drop a sub-instance's
  # providers + listeners. Routes a reserved-apiName control message through
  # the same courier (by classCtx mask) so the teardown runs on the processing
  # thread, then returns. The foreign sub-wrapper calls this from its RAII path
  # (C++ dtor / Rust Drop / Go Close / Python close). Idempotent + safe on an
  # already-released or unknown ctx (returns 0). The Nim sub-instance is freed
  # by the GC once its providers are cleared — no FFI-side ownership.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `releaseInstanceFuncIdent`*(
          ctx: uint32
      ): int32 {.exportc: `releaseInstanceFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        let libCtxKey = ctx and 0x0000FFFF'u32
        var courier: ptr CborCourier = nil
        var courierSig: ptr BrokerSignalShared = nil
        withLock `ctxsLockIdent`:
          for i in 0 ..< `ctxsIdent`.len:
            let e = `ctxsIdent`[i]
            if uint32(e.ctx) == libCtxKey and e.active:
              courier = e.arg.courier
              courierSig = e.arg.courierSignal
              discard courier.inFlight.fetchAdd(1, moAcquireRelease)
              break
        if courier.isNil:
          return 0'i32 # unknown/closed ctx: nothing to release.
        let slotIdx = claimSlot(courier)
        if slotIdx < 0:
          discard courier.inFlight.fetchSub(1, moAcquireRelease)
          return ApiStatusAgain
        var msg: CborCallMsg
        const relName = `releaseApiNameLit`
        copyMem(addr msg.apiName[0], cstring(relName), relName.len)
        msg.reqBuf = nil
        msg.reqLen = 0
        msg.slotIdx = int32(slotIdx)
        msg.targetCtx = ctx
        if not tryEnqueue(addr courier.ring, msg):
          releaseSlot(courier, slotIdx)
          discard courier.inFlight.fetchSub(1, moAcquireRelease)
          return ApiStatusAgain
        if not courierSig.isNil:
          fireBrokerSignal(courierSig)
        let res = waitSlot(courier, slotIdx)
        releaseSlot(courier, slotIdx)
        discard courier.inFlight.fetchSub(1, moAcquireRelease)
        return res.status

  )

  # ------------------------------------------------------------------
  # Generated artifacts: write the C header + CDDL schema next to the
  # build output so foreign-language wrappers can pick them up via `-I`.
  # ------------------------------------------------------------------
  let outDir =
    detectOutputDir(when defined(BrokerFfiApiOutDir): BrokerFfiApiOutDir else: "")
  var requestNames: seq[string] = @[]
  for e in entries:
    requestNames.add(e.apiName)
  var eventNames: seq[string] = @[]
  for e in eventEntries:
    eventNames.add(e.apiName)
  var signalNames: seq[string] = @[]
  for s in signalEntries:
    signalNames.add(s.apiName)
  generateCborCHeaderFile(
    outDir, libName, config.version, requestNames, eventNames, config.asyncTimeoutMs,
    config.asyncQueueDepth, signalNames,
  )
  generateCborCppHeaderFile(
    outDir, libName, entries, eventEntries, config.mainClass, config.asyncTimeoutMs,
    config.asyncQueueDepth, signalEntries,
  )
  when defined(BrokerFfiApiGenPy):
    generateCborPyFile(
      outDir, libName, entries, eventEntries, config.mainClass, config.asyncTimeoutMs,
      config.asyncQueueDepth, signalEntries,
    )
  when defined(BrokerFfiApiGenRust):
    generateCborRustFile(
      outDir, libName, entries, eventEntries, config.mainClass, config.asyncTimeoutMs,
      config.asyncQueueDepth, signalEntries,
    )
  when defined(BrokerFfiApiGenGo):
    generateCborGoFile(
      outDir, libName, entries, eventEntries, config.mainClass, config.asyncTimeoutMs,
      config.asyncQueueDepth, signalEntries,
    )

  generateCMakePackageFiles(
    outDir, libName, config.version, cborMode = true, hasCpp = true
  )

  # Emit the CDDL schema and capture its text for the runtime descriptor.
  let cddlText = generateCborCddlFile(
    outDir, libName, entries, eventEntries, gApiTypeRegistry, signalEntries
  )

  # ------------------------------------------------------------------
  # Discovery API (Phase 6): runtime descriptor + `<lib>_listApis` /
  # `<lib>_getSchema` C exports. The descriptor is built lazily on the
  # first call; subsequent calls re-use the cached value.
  # ------------------------------------------------------------------
  let descriptorOnceIdent = ident("g" & libName & "CborDescriptorOnce")
  let apiListOnceIdent = ident("g" & libName & "CborApiListOnce")

  # Build the descriptor population body as a Nim source string. Doing it
  # this way keeps every string / int literal in straight Nim code rather
  # than having to splice deeply nested AST through `quote do:`.
  var buildSrc = "proc " & libName & "CborBuildDescriptor(): LibraryDescriptor =\n"
  buildSrc.add("  result.libName = " & escape(libName) & "\n")
  buildSrc.add("  result.cddl = " & escape(cddlText) & "\n")
  buildSrc.add("  result.requests = @[\n")
  for r in entries:
    buildSrc.add("    ApiRequestInfo(apiName: " & escape(r.apiName) & ",\n")
    let argsTypeRepr =
      if r.argFields.len > 0:
        upperCamel(r.apiName) & "Args"
      else:
        ""
    buildSrc.add("      argsType: " & escape(argsTypeRepr) & ",\n")
    buildSrc.add("      argFields: @[\n")
    for (fname, ftype) in r.argFields:
      buildSrc.add(
        "        ApiFieldInfo(name: " & escape(fname) & ", nimType: " & escape(ftype) &
          "),\n"
      )
    buildSrc.add("      ],\n")
    buildSrc.add("      responseType: " & escape(r.responseTypeName) & "),\n")
  buildSrc.add("  ]\n")
  buildSrc.add("  result.events = @[\n")
  for e in eventEntries:
    buildSrc.add(
      "    ApiEventInfo(apiName: " & escape(e.apiName) & ", payloadType: " &
        escape(e.typeName) & "),\n"
    )
  buildSrc.add("  ]\n")
  buildSrc.add("  result.signals = @[\n")
  for s in signalEntries:
    buildSrc.add(
      "    ApiSignalInfo(apiName: " & escape(s.apiName) & ", payloadType: " &
        escape(s.typeName) & "),\n"
    )
  buildSrc.add("  ]\n")
  buildSrc.add("  result.types = @[\n")
  for t in gApiTypeRegistry:
    if t.name.endsWith("CborArgs"):
      continue
    let kindStr =
      case t.kind
      of atkObject: "object"
      of atkEnum: "enum"
      of atkAlias: "alias"
      of atkDistinct: "distinct"
    buildSrc.add(
      "    ApiTypeInfo(name: " & escape(t.name) & ", kind: " & escape(kindStr) & ",\n"
    )
    buildSrc.add("      fields: @[\n")
    for f in t.fields:
      buildSrc.add(
        "        ApiFieldInfo(name: " & escape(f.name) & ", nimType: " &
          escape(f.nimType) & "),\n"
      )
    buildSrc.add("      ],\n")
    buildSrc.add("      enumValues: @[\n")
    for v in t.enumValues:
      buildSrc.add(
        "        ApiEnumValueInfo(name: " & escape(v.name) & ", ordinal: " & $v.ordinal &
          "),\n"
      )
    buildSrc.add("      ],\n")
    buildSrc.add("      underlyingType: " & escape(t.underlyingType) & "),\n")
  buildSrc.add("  ]\n")

  # Build the lightweight ApiList in the same fashion.
  buildSrc.add("\nproc " & libName & "CborBuildApiList(): ApiList =\n")
  buildSrc.add("  result.libName = " & escape(libName) & "\n")
  buildSrc.add("  result.requests = @[\n")
  for r in entries:
    buildSrc.add("    " & escape(r.apiName) & ",\n")
  buildSrc.add("  ]\n")
  buildSrc.add("  result.events = @[\n")
  for e in eventEntries:
    buildSrc.add("    " & escape(e.apiName) & ",\n")
  buildSrc.add("  ]\n")
  buildSrc.add("  result.signals = @[\n")
  for s in signalEntries:
    buildSrc.add("    " & escape(s.apiName) & ",\n")
  buildSrc.add("  ]\n")

  try:
    result.add(parseStmt(buildSrc))
  except ValueError as e:
    error("CBOR FFI: failed to parse generated descriptor builder: " & e.msg)

  let ensureDescriptorIdent = ident(libName & "CborEnsureDescriptor")
  let ensureApiListIdent = ident(libName & "CborEnsureApiList")

  # Cached singletons + lazy initialisers.
  result.add(
    quote do:
      var `descriptorOnceIdent`: bool
      var `descriptorIdent`: LibraryDescriptor
      var `apiListOnceIdent`: bool
      var `apiListIdent`: ApiList

      proc `ensureDescriptorIdent`() {.gcsafe.} =
        {.cast(gcsafe).}:
          if not `descriptorOnceIdent`:
            `descriptorIdent` = `descriptorBuildIdent`()
            `descriptorOnceIdent` = true

      proc `ensureApiListIdent`() {.gcsafe.} =
        {.cast(gcsafe).}:
          if not `apiListOnceIdent`:
            `apiListIdent` = `apiListBuildIdent`()
            `apiListOnceIdent` = true

  )

  # `<lib>_listApis` — returns a JSON-encoded `ApiList` string.
  result.add(
    quote do:
      proc `listApisFuncIdent`*(
          respBufOut: ptr pointer, respLenOut: ptr int32
      ): int32 {.exportc: `listApisFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if respBufOut.isNil or respLenOut.isNil:
          return -1'i32
        respBufOut[] = nil
        respLenOut[] = 0
        `ensureApiListIdent`()
        var jsonStr: string
        try:
          jsonStr = toJsonString(`apiListIdent`)
        except CatchableError:
          return ApiStatusProviderErr
        if jsonStr.len > 0:
          let buf = allocShared0(jsonStr.len)
          copyMem(buf, addr jsonStr[0], jsonStr.len)
          respBufOut[] = buf
          respLenOut[] = int32(jsonStr.len)
        return 0'i32

  )

  # `<lib>_getSchema` — returns a JSON-encoded `LibraryDescriptor` string.
  result.add(
    quote do:
      proc `getSchemaFuncIdent`*(
          respBufOut: ptr pointer, respLenOut: ptr int32
      ): int32 {.exportc: `getSchemaFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if respBufOut.isNil or respLenOut.isNil:
          return -1'i32
        respBufOut[] = nil
        respLenOut[] = 0
        `ensureDescriptorIdent`()
        var jsonStr: string
        try:
          jsonStr = toJsonString(`descriptorIdent`)
        except CatchableError:
          return ApiStatusProviderErr
        if jsonStr.len > 0:
          let buf = allocShared0(jsonStr.len)
          copyMem(buf, addr jsonStr[0], jsonStr.len)
          respBufOut[] = buf
          respLenOut[] = int32(jsonStr.len)
        return 0'i32

  )

  when defined(brokerDebug):
    writeBrokerDebug(
      "BrokerLibrary",
      libName,
      result,
      header =
        $entries.len & " request adapters, " & $eventEntries.len & " event entries",
    )
    when defined(brokerDebugStdout):
      echo "[brokers/cbor] registerBrokerLibraryCborImpl emitted runtime for '" & libName &
        "' with " & $entries.len & " request adapters and " & $eventEntries.len &
        " event entries"
      echo result.repr

{.pop.}

macro registerBrokerLibrary*(body: untyped): untyped =
  ## Generates the full shared-library surface for a broker FFI library.
  ## A no-op unless `-d:BrokerFfiApi` is set, so client code never needs
  ## a `when defined(...)` guard around it.
  when defined(BrokerFfiApi):
    registerBrokerLibraryImpl(body)
  else:
    newStmtList()

## API Common
## ----------
## Shared utilities for FFI API broker code generation.
##
## After the native FFI codegen surface was retired (see
## `doc/CBOR_Refactoring.md`), this module is a thin coordination layer
## that:
## - Re-exports the type schema registry and FFI mode flag
## - Owns the legacy FFI struct registry bridge
## - Owns compile-time accumulators that are shared across broker macros
##   (event counters, handler entries, cleanup proc names)
## - Provides runtime memory helpers for the FFI boundary
##
## This module is only used when compiling with `-d:BrokerFfiApi`.

{.push raises: [].}

import std/macros

import ./api_schema
import ./api_outdir
import ./helper/broker_utils

export api_schema
export api_outdir

# ---------------------------------------------------------------------------
# Library name accumulator
# ---------------------------------------------------------------------------

var gApiLibraryName* {.compileTime.}: string = ""

# ---------------------------------------------------------------------------
# Compile-time accumulators for delivery thread event system
# ---------------------------------------------------------------------------

var gApiEventTypeCounter* {.compileTime.}: int = 0
  ## Auto-incrementing type ID for EventBroker(API) types.
  ## NOTE: Must be incremented directly (not via a helper proc) because the
  ## Nim VM does not persist side effects from called compileTime procs.

var gApiSharedBrokerGenerated* {.compileTime.}: bool = false
  ## Flag: has the shared RegisterEventListenerResult RequestBroker been emitted?

var gApiEventHandlerEntries* {.compileTime.}: seq[(int, string)] =
  @[] ## Accumulates (typeId, handlerProcName) pairs for the aggregate provider.

var gApiEventCleanupProcNames* {.compileTime.}: seq[string] =
  @[] ## Accumulates cleanup proc names for delivery thread teardown.

var gApiRequestCleanupProcNames* {.compileTime.}: seq[string] =
  @[] ## Accumulates cleanup proc names for request provider teardown.

var gApiEventProcessLoopShutdownProcNames* {.compileTime.}: seq[string] =
  @[] ## Accumulates async processLoop shutdown proc names for delivery thread teardown.

var gApiForeignGcHelperEmitted* {.compileTime.}: bool = false
  ## Flag: has the ensureForeignThreadGc() helper been emitted?
  ## Each broker codegen module checks this before emitting the helper
  ## to avoid duplicate definitions.

# ---------------------------------------------------------------------------
# CBOR-mode dispatch table accumulator
# ---------------------------------------------------------------------------

type CborRequestEntry* = object
  apiName*: string ## Wire name foreign callers pass to `<lib>_call`.
  adapterProc*: string ## Identifier of the generated adapter proc.
  responseTypeName*: string
    ## Nim type name for the response payload
    ## (e.g. "GetStatus"). Foreign-language wrapper codegen consumes this
    ## to emit typed return signatures. Empty if not yet populated by an
    ## older caller path.
  argFields*: seq[(string, string)]
    ## (paramName, nimType) pairs from
    ## the request signature, in declaration order. Empty for zero-arg
    ## requests. Wrapper codegen turns this into the typed method
    ## signature and the args struct mirroring the synthetic Nim
    ## `<Type>CborArgs` object.
  returnsInterface*: string
    ## reduced-A: name of the BrokerInterface(API) this request *creates and
    ## returns an instance of* (e.g. "IWidget"), or "" for a normal request.
    ## When set, the wire `ok` value is a bare uint32 (the sub-instance's
    ## BrokerContext); wrapper codegen emits a method returning the typed
    ## sub-wrapper class built from that ctx instead of a decoded payload.

var gApiCborRequestEntries* {.compileTime.}: seq[CborRequestEntry] = @[]
  ## Accumulated by `RequestBroker(API)` expansions.
  ## `registerBrokerLibrary` drains this list to emit the per-library
  ## `Table[string, CborApiAdapter]` and the `<lib>_call` dispatch.

type CborEventEntry* = object
  apiName*: string ## Wire eventName foreign callers pass to `<lib>_subscribe`.
  typeName*: string ## Nim type identifier for the event payload.

var gApiCborEventEntries* {.compileTime.}: seq[CborEventEntry] = @[]
  ## Accumulated by `EventBroker(API)` expansions.
  ## `registerBrokerLibrary` reads this list to generate per-event
  ## listener installers and the `<lib>CborIsKnownEvent` predicate. As
  ## with `gApiCborRequestEntries`, this list is read but not reset —
  ## Nim's compile-time VM aliases `let` copies of seqs back to the
  ## source.

proc registerCborEventEntry*(apiName, typeName: string) {.compileTime.} =
  ## Register an event for the next library's CBOR-mode subscribe surface.
  for entry in gApiCborEventEntries:
    if entry.apiName == apiName:
      let ownerNew = interfaceOwningEventType(typeName)
      let ownerOld = interfaceOwningEventType(entry.typeName)
      let ifaceHint =
        if ownerNew.len > 0 or ownerOld.len > 0:
          " ('" & typeName & "' in interface " &
            (if ownerNew.len > 0: ownerNew else: "<library>") & " vs '" & entry.typeName &
            "' in interface " & (if ownerOld.len > 0: ownerOld else: "<library>") & ")"
        else:
          ""
      error(
        "CBOR FFI: duplicate event apiName '" & apiName & "' (already registered by '" &
          entry.typeName & "')" & ifaceHint & ". " &
          "Each EventBroker(API) must have a unique event type name."
      )
  gApiCborEventEntries.add(CborEventEntry(apiName: apiName, typeName: typeName))

proc registerCborRequestEntry*(
    apiName, adapterProc: string,
    responseTypeName: string = "",
    argFields: seq[(string, string)] = @[],
    returnsInterface: string = "",
) {.compileTime.} =
  ## Register a CBOR request adapter for the next library that calls
  ## `registerBrokerLibrary`. Detects duplicate apiNames at compile time
  ## so two requests can't shadow each other on the wire.
  for entry in gApiCborRequestEntries:
    if entry.apiName == apiName:
      # reduced-A: name the owning interfaces when the collision spans two
      # BrokerInterface(API) declarations (apiNames are globally unique across
      # the whole library, not per interface).
      let ownerNew = interfaceOwningRequestType(responseTypeName)
      let ownerOld = interfaceOwningRequestType(entry.responseTypeName)
      let ifaceHint =
        if ownerNew.len > 0 or ownerOld.len > 0:
          " ('" & responseTypeName & "' in interface " &
            (if ownerNew.len > 0: ownerNew else: "<library>") & " vs '" &
            entry.responseTypeName & "' in interface " &
            (if ownerOld.len > 0: ownerOld else: "<library>") & ")"
        else:
          ""
      error(
        "CBOR FFI: duplicate request apiName '" & apiName & "' (already registered by '" &
          entry.adapterProc & "')" & ifaceHint & ". " &
          "Each RequestBroker(API) must have a unique response type name."
      )
  gApiCborRequestEntries.add(
    CborRequestEntry(
      apiName: apiName,
      adapterProc: adapterProc,
      responseTypeName: responseTypeName,
      argFields: argFields,
      returnsInterface: returnsInterface,
    )
  )

# ---------------------------------------------------------------------------
# Legacy FFI struct registry bridge
# ---------------------------------------------------------------------------

var gApiFfiStructs* {.compileTime.}: seq[(string, seq[(string, string)])] = @[]
  ## Legacy registry. Kept for backward compatibility with existing ApiType usage.
  ## New code should use `gApiTypeRegistry` from `api_schema` instead.

proc registerApiFfiStruct*(
    typeName: string, fields: seq[(string, string)]
) {.compileTime.} =
  ## Register a type in both the legacy and new registries.
  gApiFfiStructs.add((typeName, fields))
  registerFromFieldTuples(typeName, fields)

proc lookupFfiStruct*(typeName: string): seq[(string, string)] {.compileTime.} =
  ## Look up type fields. Checks the new type registry first, then falls back
  ## to the legacy registry for backward compatibility.
  if isTypeRegistered(typeName):
    return lookupTypeFields(typeName)
  for (name, fields) in gApiFfiStructs:
    if name == typeName:
      return fields
  error(
    "Type '" & typeName & "' not registered. " &
      "Define it as a plain Nim type before the broker macro, " &
      "or declare it with `ApiType:` for explicit registration."
  )

{.pop.}

# ---------------------------------------------------------------------------
# Runtime memory helpers
# ---------------------------------------------------------------------------

proc allocCStringCopy*(s: string): cstring =
  ## Allocates a copy of a Nim string as a shared C string.
  ## The caller frees it via the generated FFI free helpers, which may run on
  ## a different thread than the allocation site under --mm:refc.
  if s.len == 0:
    return nil
  let buf = cast[cstring](allocShared(s.len + 1))
  copyMem(buf, unsafeAddr s[0], s.len)
  cast[ptr char](cast[int](buf) + s.len)[] = '\0'
  buf

proc freeCString*(s: cstring) =
  ## Frees a C string previously allocated by allocCStringCopy.
  if not s.isNil:
    deallocShared(s)

# ---------------------------------------------------------------------------
# Shared-memory string helpers for cross-thread event data
# ---------------------------------------------------------------------------

proc allocSharedCString*(s: string): cstring =
  ## Allocate a C string copy in shared memory (safe for cross-thread use).
  allocCStringCopy(s)

proc freeSharedCString*(s: cstring) =
  ## Free a C string allocated by `allocSharedCString`.
  freeCString(s)

# ---------------------------------------------------------------------------
# Foreign thread GC helper — emitted once per compilation unit
# ---------------------------------------------------------------------------

proc emitEnsureForeignThreadGc*(): NimNode {.compileTime.} =
  ## Returns the AST for the per-thread foreign thread GC registration helper.
  ## Call this from each broker codegen module; it emits the helper only once
  ## per compilation unit (guarded by `gApiForeignGcHelperEmitted`).
  if gApiForeignGcHelperEmitted:
    return newStmtList()

  gApiForeignGcHelperEmitted = true

  let tvGcReg = genSym(nskVar, "gForeignGcRegistered")
  let ensureIdent = ident("ensureForeignThreadGc")

  result = quote:
    var `tvGcReg` {.threadvar.}: bool

    proc `ensureIdent`() {.inline.} =
      when compileOption("app", "lib"):
        if not `tvGcReg`:
          when declared(setupForeignThreadGc):
            # setupForeignThreadGc already registers the thread with the GC
            # and sets the stack bottom on modern Nim (>= 1.6).  Manually
            # calling nimGC_setStackBottom on top of it can corrupt GC state.
            setupForeignThreadGc()
          else:
            # Fallback for very old Nim versions that lack setupForeignThreadGc.
            when declared(nimGC_setStackBottom):
              var locals {.volatile, noinit.}: pointer
              locals = addr(locals)
              nimGC_setStackBottom(locals)
          `tvGcReg` = true

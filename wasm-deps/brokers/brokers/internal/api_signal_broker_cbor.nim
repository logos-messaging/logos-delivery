## API SignalBroker — CBOR mode codegen
## --------------------------------------
## Generates the CBOR-mode surface for `SignalBroker(API)` declarations.
##
## For each declaration this module emits:
##
## 1. The underlying multi-thread SignalBroker (via `generateMtSignalBroker`).
##    The signal handler is installed on the processing thread, so `signal()`
##    takes the same-thread fast path (direct `asyncSpawn`, no MT ring). The
##    only cross-thread queue on the FFI path is the library's courier
##    `CborCallRing`, populated by `<lib>_call` on the foreign caller's thread.
##
## 2. A one-way signal adapter with the signature
##
##      proc <Type>SignalCborAdapter*(ctx: BrokerContext, reqBuf: seq[byte]):
##          Future[void] {.async: (raises: []), gcsafe.}
##
##    It decodes the payload (or ignores the buffer for a `void` pulse) and
##    calls `signal(...)`. There is NO response envelope — a signal is one-way.
##    A CBOR decode failure is **logged (chronicles warn), not returned**:
##    generated wrappers encode the payload themselves, so a decode failure is
##    a wrapper bug; only hand-written C callers can hit it (the `.h` header
##    says so).
##
## 3. A compile-time entry in `gApiCborSignalEntries` (a DISTINCT accumulator
##    from `gApiCborRequestEntries`) so `registerBrokerLibrary` can wire the
##    slot-free `<lib>_call` signal path and the per-language wrapper methods.
##
## The wire `apiName` is the snake_case form of the signal's Nim type
## identifier — e.g. `IngestSample` becomes `ingest_sample`.

{.push raises: [].}

import std/[macros, strutils]
import
  ./helper/broker_utils, ./mt_signal_broker, ./mt_config, ./api_common, ./api_schema
import
  ./api_request_broker_cbor # for registerCborObjectType / registerCborPrimitiveType
import ./api_cbor_codec
import ./api_type_resolver
import ./broker_debug

export mt_signal_broker, mt_config, api_common, api_cbor_codec, api_type_resolver

# The dispatch shape `registerBrokerLibrary` materialises signals into. A signal
# produces no response, so — unlike `CborApiAdapter` — it returns `Future[void]`.
type CborSignalApiAdapter* = proc(ctx: BrokerContext, reqBuf: seq[byte]): Future[void] {.
  async: (raises: []), gcsafe
.}

proc emitSignalAdapter(
    typeIdent, adapterIdent: NimNode, apiNameLit: NimNode, isVoid: bool
): NimNode {.compileTime.} =
  ## One-way adapter: decode the payload and dispatch via `signal()`. No
  ## response envelope. Decode failure is logged, not returned.
  if isVoid:
    quote:
      proc `adapterIdent`*(
          ctx: BrokerContext, reqBuf: seq[byte]
      ): Future[void] {.async: (raises: []), gcsafe.} =
        discard reqBuf
        let r = `typeIdent`.signal(ctx)
        if r.isErr:
          warn "SignalBroker(API): signal not accepted",
            signal = `apiNameLit`, error = r.error

  else:
    quote:
      proc `adapterIdent`*(
          ctx: BrokerContext, reqBuf: seq[byte]
      ): Future[void] {.async: (raises: []), gcsafe.} =
        let decRes = cborDecode(reqBuf, `typeIdent`)
        if decRes.isErr:
          warn "SignalBroker(API): payload decode failed",
            signal = `apiNameLit`, error = decRes.error
          return
        let r = `typeIdent`.signal(ctx, decRes.value)
        if r.isErr:
          warn "SignalBroker(API): signal not accepted",
            signal = `apiNameLit`, error = r.error

proc generateApiCborSignalBrokerImpl(body: NimNode, cfg: MtSigCfg): NimNode =
  result = newStmtList()

  # 1. Emit the underlying MT signal broker (same-thread onSignal/signal API
  #    for the processing thread; MT-aware cross-thread transport under the
  #    hood, though the FFI lane always installs on the processing thread).
  result.add(generateMtSignalBroker(copyNimTree(body), cfg))

  # 2. Parse the payload type + register the schema entry so wrapper codegen
  #    can emit a typed struct for the payload.
  let parsed = parseSingleTypeDef(
    body, "SignalBroker", allowRefToNonObject = true, collectFieldInfo = true
  )
  let typeIdent = parsed.typeIdent
  let typeName = sanitizeIdentName(typeIdent)
  let apiName = toSnakeCase(typeName)
  if parsed.hasInlineFields:
    registerCborObjectType(typeName, parsed.fieldNames, parsed.fieldTypes)
  elif parsed.isVoid:
    # `void` → a zero-field object: a payload-less pulse signal.
    registerCborObjectType(typeName, @[], @[])
  else:
    registerCborPrimitiveType(typeName, parsed)

  # 3. Emit the one-way adapter and register the signal entry.
  let adapterIdent = ident(typeName & "SignalCborAdapter")
  result.add(emitSignalAdapter(typeIdent, adapterIdent, newLit(apiName), parsed.isVoid))
  registerCborSignalEntry(apiName, $adapterIdent, typeName)

  when defined(brokerDebug):
    writeBrokerDebug(
      "SignalBrokerApi", typeName, result, header = "signalName='" & apiName & "'"
    )
    when defined(brokerDebugStdout):
      echo "[brokers/cbor] SignalBroker(API) for '" & typeName & "' (signalName='" &
        apiName & "')"
      echo result.repr

{.pop.}

macro generateApiCborSignalBrokerDeferred*(args: varargs[untyped]): untyped =
  ## Typed-phase deferred entry point; populates the registry first.
  ## Args layout: [body, kw0, kw1, ...] — kwargs re-parsed into an MtSigCfg.
  if args.len == 0:
    error("generateApiCborSignalBrokerDeferred requires a body", args)
  let body = args[0]
  var kwargs: seq[NimNode]
  for i in 1 ..< args.len:
    kwargs.add(args[i])
  let cfg = parseMtSigKwargs(kwargs)
  generateApiCborSignalBrokerImpl(body, cfg)

{.push raises: [].}

proc generateApiCborSignalBroker*(body: NimNode, kwargs: seq[NimNode]): NimNode =
  result = newStmtList()

  let externalIdents = discoverExternalTypes(body)
  if externalIdents.len > 0:
    result.add(emitAutoRegistrations(externalIdents))

  let deferred =
    newCall(ident("generateApiCborSignalBrokerDeferred"), copyNimTree(body))
  for kw in kwargs:
    deferred.add(copyNimTree(kw))
  result.add(deferred)

{.pop.}

## API EventBroker — CBOR mode codegen
## ------------------------------------
## Generates the CBOR-mode surface for `EventBroker(API)` declarations.
##
## For each declaration this module emits:
##
## 1. The underlying multi-thread EventBroker (via `generateMtEventBroker`).
##    Internal cross-thread emit dispatch stays as typed `Channel[T]`
##    traffic; CBOR encoding only happens at the moment we hand the event
##    to a foreign C callback.
##
## 2. A compile-time entry in `gApiCborEventEntries` so the upcoming
##    `registerBrokerLibrary` CBOR backend can wire the event into the
##    library's subscribe surface and emit a per-event listener installer.
##
## Listener installation is intentionally NOT generated here — installers
## need access to the library's subscription map / lock / callback-type,
## which only exist at `registerBrokerLibrary` expansion time. We just
## record the event's wire name and Nim type identifier; the library macro
## materialises the installer with the right captures.
##
## Wire `eventName` is the snake_case form of the event's Nim type
## identifier — e.g. `DeviceUpdated` becomes `device_updated`.

{.push raises: [].}

import std/[macros, strutils]
import ./helper/broker_utils, ./mt_event_broker, ./mt_config, ./api_common, ./api_schema
import ./api_request_broker_cbor # for registerCborObjectType
import ./api_type_resolver
import ./broker_debug

# `api_type_resolver` re-export: see note in `api_request_broker_cbor.nim`
# — `autoRegisterApiType` is emitted into user code by broker macros and
# must resolve at the user-library expansion site post-Part-A retirement
# of the native `api_event_broker` re-export chain.
export mt_event_broker, mt_config, api_common, api_type_resolver

proc generateApiCborEventBrokerImpl(body: NimNode, cfg: MtEvtCfg): NimNode =
  result = newStmtList()

  # 1. Emit the underlying MT event broker (single-thread emit/listen API
  #    visible to user code, MT-aware cross-thread dispatch under the hood).
  #    The capacity config flows in from the outer EventBroker(API, ...)
  #    kwargs — same knobs as EventBroker(mt).
  result.add(generateMtEventBroker(copyNimTree(body), cfg))

  # 2. Parse the event type identifier and register the entry. Capture
  #    field info so wrapper codegen can emit typed structs for the
  #    payload.
  let parsed = parseSingleTypeDef(
    body, "EventBroker", allowRefToNonObject = true, collectFieldInfo = true
  )
  let typeIdent = parsed.typeIdent
  let typeName = sanitizeIdentName(typeIdent)
  let apiName = toSnakeCase(typeName)
  if parsed.hasInlineFields:
    registerCborObjectType(typeName, parsed.fieldNames, parsed.fieldTypes)
  elif parsed.isVoid:
    # `void` → a zero-field object: a payload-less event notification.
    registerCborObjectType(typeName, @[], @[])
  else:
    registerCborPrimitiveType(typeName, parsed)
  registerCborEventEntry(apiName, typeName)

  when defined(brokerDebug):
    writeBrokerDebug(
      "EventBrokerApi", typeName, result, header = "eventName='" & apiName & "'"
    )
    when defined(brokerDebugStdout):
      echo "[brokers/cbor] EventBroker(API) for '" & typeName & "' (eventName='" &
        apiName & "')"
      echo result.repr

{.pop.}

macro generateApiCborEventBrokerDeferred*(args: varargs[untyped]): untyped =
  ## Typed-phase deferred entry point; populates the registry first.
  ## Args layout: [body, kw0, kw1, ...] — kwargs are forwarded as raw
  ## `nnkExprEqExpr` nodes from `generateApiCborEventBroker` so we
  ## re-parse them here into an MtEvtCfg.
  if args.len == 0:
    error("generateApiCborEventBrokerDeferred requires a body", args)
  let body = args[0]
  var kwargs: seq[NimNode]
  for i in 1 ..< args.len:
    kwargs.add(args[i])
  let cfg = parseMtEvtKwargs(kwargs)
  generateApiCborEventBrokerImpl(body, cfg)

{.push raises: [].}

proc generateApiCborEventBroker*(body: NimNode, kwargs: seq[NimNode]): NimNode =
  result = newStmtList()

  let externalIdents = discoverExternalTypes(body)
  if externalIdents.len > 0:
    result.add(emitAutoRegistrations(externalIdents))

  let deferred = newCall(ident("generateApiCborEventBrokerDeferred"), copyNimTree(body))
  for kw in kwargs:
    deferred.add(copyNimTree(kw))
  result.add(deferred)

{.pop.}

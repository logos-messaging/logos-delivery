## API RequestBroker — CBOR mode codegen
## --------------------------------------
## Generates the CBOR-mode surface for `RequestBroker(API)` declarations.
##
## For each declaration this module emits:
##
## 1. The underlying multi-thread RequestBroker, exactly as the native path
##    does — providers register and run on the processing thread the same
##    way regardless of FFI mode. Internal cross-thread dispatch stays as
##    typed `Channel[T]` traffic; CBOR encoding only happens at the C ABI
##    boundary.
##
## 2. (When the signature has arguments) a synthetic per-request CBOR args
##    object that mirrors the parameter list field-by-field. Decoding the
##    foreign request buffer into this object gives us individual local
##    variables to forward into the broker's `request` call.
##
## 3. A CBOR adapter proc with the canonical signature
##
##      proc <Type>CborAdapter*(ctx: BrokerContext, reqBuf: seq[byte]):
##          Future[seq[byte]] {.async: (raises: []).}
##
##    The adapter decodes the request buffer (or ignores it for zero-arg
##    requests), `await`s the typed broker call, and encodes the resulting
##    `Result[T, string]` as a CBOR response envelope.
##
## 4. A compile-time entry in `gApiCborRequestEntries` so the upcoming
##    `registerBrokerLibrary` CBOR backend can wire the adapter into the
##    library's dispatch table.
##
## The wire `apiName` is the snake_case form of the response type name —
## e.g. `InitializeRequest` becomes `initialize_request`. Foreign wrappers
## are generated to use the same name so the C entry point sees a stable
## identifier per broker.

{.push raises: [].}

import std/[macros, strutils]
import
  ./helper/broker_utils,
  ./mt_request_broker,
  ./mt_config,
  ./api_common,
  ./api_cbor_codec,
  ./api_schema,
  ./api_type_resolver,
  ./broker_debug

# `api_type_resolver` re-export: `autoRegisterApiType` is emitted into the
# user-library AST by the broker macros and must resolve at the user's
# expansion site. Previously this came in transitively via the native
# `api_request_broker` re-export chain (retired in Part A); re-export it
# explicitly here so user code never needs a direct
# `import brokers/internal/api_type_resolver`.
export mt_request_broker, mt_config, api_common, api_cbor_codec, api_type_resolver

# ---------------------------------------------------------------------------
# Schema registration
# ---------------------------------------------------------------------------

proc registerCborObjectType*(
    typeName: string, fieldNames, fieldTypes: seq[NimNode]
) {.compileTime.} =
  ## Register a parsed object type in `gApiTypeRegistry` so the C++ /
  ## Python / etc. wrapper codegen can emit typed structs for it.
  ## Idempotent — subsequent calls for the same type are a no-op so a
  ## type that ends up registered through both the auto-resolver and a
  ## broker macro doesn't double-list.
  if isTypeRegistered(typeName):
    return
  var entry = ApiTypeEntry(name: typeName, kind: atkObject)
  for i in 0 ..< fieldNames.len:
    var fname = $fieldNames[i]
    # `fieldNames` from parseSingleTypeDef carry the original AST,
    # which for inline `object` types is a plain Ident (export marker
    # already lifted by the parser). Strip a trailing '*' defensively.
    if fname.endsWith("*"):
      fname.setLen(fname.len - 1)
    let ftype = fieldTypes[i].repr.strip()
    entry.fields.add(ApiFieldDef(name: fname, nimType: ftype))
  registerTypeEntry(entry)

proc registerCborPrimitiveType*(
    typeName: string, parsed: ParsedBrokerType
) {.compileTime.} =
  ## Register a primitive (non-object) broker type — `type X = int32` — as a
  ## distinct alias of its underlying primitive. Wrapper codegen then emits a
  ## `using X = <prim>` alias and treats X as an emittable scalar payload (the
  ## CBOR wire value is a bare scalar, not a map). A no-op for non-primitive
  ## non-object types, which stay TODO-stubbed in the wrappers.
  if isTypeRegistered(typeName):
    return
  if parsed.objectDef.kind == nnkDistinctTy and parsed.objectDef.len == 1 and
      parsed.objectDef[0].kind == nnkIdent and isNimPrimitive($parsed.objectDef[0]) and
      ($parsed.objectDef[0]).toLowerAscii() notin ["cstring"]:
    # `string` is allowed (maps to the wrapper's native string type) so a POD /
    # option-B `string`-payload request is emittable; `cstring` stays excluded
    # (unsafe to marshal across the FFI/CBOR boundary).
    registerTypeEntry(makeAliasEntry(typeName, $parsed.objectDef[0], atkDistinct))

# ---------------------------------------------------------------------------
# Adapter proc type — exposed so registerBrokerLibrary (CBOR mode) can
# materialise a uniform table of dispatchers.
# ---------------------------------------------------------------------------

type CborApiAdapter* = proc(ctx: BrokerContext, reqBuf: seq[byte]): Future[seq[byte]] {.
  async: (raises: []), gcsafe
.}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc collectSignatures(
    body: NimNode
): tuple[
  zeroArg: NimNode,
  argSig: NimNode,
  argParams: seq[NimNode],
  zeroArgName: string,
  argSigName: string,
] {.compileTime.} =
  ## Walk the macro body and split the (at most two) `signature*` proc
  ## declarations into the zero-arg and arg-based slots, mirroring
  ## `mt_request_broker` and the native path's handling.
  result.zeroArg = nil
  result.argSig = nil
  result.argParams = @[]
  result.zeroArgName = ""
  result.argSigName = ""

  for stmt in body:
    if stmt.kind != nnkProcDef:
      continue
    let procName = stmt[0]
    let procNameIdent =
      case procName.kind
      of nnkIdent:
        procName
      of nnkPostfix:
        procName[1]
      else:
        procName
    if not ($procNameIdent).startsWith("signature"):
      error("Signature proc names must start with `signature`", procName)

    let params = stmt.params
    let paramCount = params.len - 1
    if paramCount == 0:
      result.zeroArg = stmt
      result.zeroArgName = $procNameIdent
    elif paramCount >= 1:
      result.argSig = stmt
      result.argSigName = $procNameIdent
      for idx in 1 ..< params.len:
        result.argParams.add(copyNimTree(params[idx]))

proc snakeApiName(typeIdent: NimNode): string {.compileTime.} =
  ## Wire `apiName` for a request: snake_case form of the response type
  ## identifier. e.g. `InitializeRequest` -> `initialize_request`.
  toSnakeCase(sanitizeIdentName(typeIdent))

proc emitArgsType(
    argsTypeIdent: NimNode, argParams: seq[NimNode]
): NimNode {.compileTime.} =
  ## Build `type <argsTypeIdent>* = object\n  field1*: T1\n  field2*: T2`
  ## from the arg-based signature's parameter nodes.
  ##
  ## Each `argParams[i]` is an `nnkIdentDefs` node carrying one or more
  ## names plus a type. We expand each name into its own field so an arg
  ## like `(a, b: int32)` produces two separate object fields.
  var recList = newNimNode(nnkRecList)
  for paramDefs in argParams:
    let lastIdx = paramDefs.len - 1
    let typeNode = paramDefs[lastIdx - 1]
    for nameIdx in 0 ..< lastIdx - 1:
      let nameNode = paramDefs[nameIdx]
      let fieldIdent =
        case nameNode.kind
        of nnkIdent, nnkSym:
          ident($nameNode)
        of nnkPostfix:
          ident($nameNode[1])
        of nnkPragmaExpr:
          ident($nameNode[0])
        else:
          ident($nameNode)
      recList.add(
        newTree(
          nnkIdentDefs, postfix(fieldIdent, "*"), copyNimTree(typeNode), newEmptyNode()
        )
      )

  newTree(
    nnkTypeSection,
    newTree(
      nnkTypeDef,
      postfix(argsTypeIdent, "*"),
      newEmptyNode(),
      newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), recList),
    ),
  )

# ---------------------------------------------------------------------------
# Adapter emission
# ---------------------------------------------------------------------------

proc emitZeroArgAdapter(
    typeIdent: NimNode, payloadType: NimNode, adapterIdent: NimNode, isVoid: bool
): NimNode {.compileTime.} =
  ## Adapter for a zero-argument request: ignore the input buffer, await
  ## the broker call, encode the response envelope. `typeIdent` is the
  ## dispatch tag; `payloadType` is the (decoupled) value type the request
  ## resolves to and the envelope carries.
  ##
  ## For a `void` payload the public broker resolves to `Result[void, string]`,
  ## which has no `Option[void]`-encodable envelope. We bridge it to the wire
  ## unit type `CborUnit` (a zero-field map `{}`), matching the legacy
  ## `type X = void` form bit-for-bit.
  if isVoid:
    quote:
      proc `adapterIdent`*(
          ctx: BrokerContext, reqBuf: seq[byte]
      ): Future[seq[byte]] {.async: (raises: []), gcsafe.} =
        discard reqBuf
        let r = await `typeIdent`.request(ctx)
        let unitR =
          if r.isOk:
            Result[CborUnit, string].ok(CborUnit())
          else:
            Result[CborUnit, string].err(r.error)
        let envBytes = cborEncodeResultEnvelope(unitR)
        if envBytes.isOk:
          return envBytes.value
        let errEnv = cborEncodeResultEnvelope(
          Result[CborUnit, string].err("response encode failed: " & envBytes.error)
        )
        if errEnv.isOk:
          return errEnv.value
        return @[]

  else:
    quote:
      proc `adapterIdent`*(
          ctx: BrokerContext, reqBuf: seq[byte]
      ): Future[seq[byte]] {.async: (raises: []), gcsafe.} =
        discard reqBuf
        let r = await `typeIdent`.request(ctx)
        let envBytes = cborEncodeResultEnvelope(r)
        if envBytes.isOk:
          return envBytes.value
        let errEnv = cborEncodeResultEnvelope(
          Result[`payloadType`, string].err("response encode failed: " & envBytes.error)
        )
        if errEnv.isOk:
          return errEnv.value
        return @[]

proc emitArgAdapter(
    typeIdent: NimNode,
    payloadType: NimNode,
    adapterIdent: NimNode,
    argsTypeIdent: NimNode,
    argParams: seq[NimNode],
    isVoid: bool,
): NimNode {.compileTime, raises: [ValueError].} =
  ## Adapter for an arg-based request. Decodes the request buffer into the
  ## synthesised `argsTypeIdent`, awaits the broker call with each field
  ## unpacked positionally, and encodes the resulting envelope.
  ##
  ## The proc body is rendered as a Nim source string and parsed back via
  ## `parseStmt`. This sidesteps the awkward interaction between `quote
  ## do:`'s gensym'd proc parameters and pre-built call nodes — every
  ## identifier in the rendered string lives in the same local scope, so
  ## name resolution is straightforward.
  var fieldNames: seq[string] = @[]
  for paramDefs in argParams:
    let lastIdx = paramDefs.len - 1
    for nameIdx in 0 ..< lastIdx - 1:
      let nameNode = paramDefs[nameIdx]
      let nameStr =
        case nameNode.kind
        of nnkIdent, nnkSym:
          $nameNode
        of nnkPostfix:
          $nameNode[1]
        of nnkPragmaExpr:
          $nameNode[0]
        else:
          $nameNode
      fieldNames.add(nameStr)

  var argList = ""
  for f in fieldNames:
    argList.add(", decoded." & f)

  let typeIdentName = $typeIdent
  # A `void` payload resolves to `Result[void, string]` (no encodable
  # envelope); bridge it to the wire unit type `CborUnit`, matching the
  # legacy `type X = void` form. Every envelope on this path then carries
  # `CborUnit`, and the awaited result is converted before encoding.
  let envTypeName =
    if isVoid:
      "CborUnit"
    else:
      payloadType.repr.strip()
  let argsTypeIdentName = $argsTypeIdent
  let adapterIdentName = $adapterIdent

  let encodeRespSrc =
    if isVoid:
      "  let unitR =\n" & "    if r.isOk: Result[CborUnit, string].ok(CborUnit())\n" &
        "    else: Result[CborUnit, string].err(r.error)\n" &
        "  let envBytes = cborEncodeResultEnvelope(unitR)\n"
    else:
      "  let envBytes = cborEncodeResultEnvelope(r)\n"

  let src =
    "proc " & adapterIdentName & "*(\n" & "    ctx: BrokerContext, reqBuf: seq[byte]\n" &
    "): Future[seq[byte]] {.async: (raises: []), gcsafe.} =\n" &
    "  let decRes = cborDecode(reqBuf, " & argsTypeIdentName & ")\n" &
    "  if decRes.isErr:\n" & "    let errEnv = cborEncodeResultEnvelope(\n" &
    "      Result[" & envTypeName &
    ", string].err(\"request decode failed: \" & decRes.error)\n" & "    )\n" &
    "    if errEnv.isOk:\n" & "      return errEnv.value\n" & "    return @[]\n" &
    "  let decoded = decRes.value\n" & "  let r = await " & typeIdentName &
    ".request(ctx" & argList & ")\n" & encodeRespSrc & "  if envBytes.isOk:\n" &
    "    return envBytes.value\n" & "  let errEnv = cborEncodeResultEnvelope(\n" &
    "    Result[" & envTypeName &
    ", string].err(\"response encode failed: \" & envBytes.error)\n" & "  )\n" &
    "  if errEnv.isOk:\n" & "    return errEnv.value\n" & "  return @[]\n"

  parseStmt(src)

# ---------------------------------------------------------------------------
# reduced-A: create-instance adapters. When a request's Ok payload type is a
# registered BrokerInterface(API), the provider builds and returns a sub-
# interface ref. We do NOT CBOR-encode the ref; instead the adapter extracts
# the sub-instance's BrokerContext and encodes it as a bare `uint32` (the
# routing handle). The foreign wrapper decodes that ctx and constructs the
# typed sub-wrapper class. Adapter + provider both run on the processing
# thread (same-thread direct dispatch), so the ref never crosses a channel —
# safe under both --mm:refc and --mm:orc.
# ---------------------------------------------------------------------------

proc emitZeroArgInstanceAdapter(
    typeIdent, adapterIdent: NimNode
): NimNode {.compileTime, raises: [ValueError].} =
  let src =
    "proc " & $adapterIdent & "*(\n" & "    ctx: BrokerContext, reqBuf: seq[byte]\n" &
    "): Future[seq[byte]] {.async: (raises: []), gcsafe.} =\n" & "  discard reqBuf\n" &
    "  let r = await " & $typeIdent & ".request(ctx)\n" & "  if r.isOk:\n" &
    "    installApiListenersForCtx(r.value.brokerCtx)\n" & "  let mapped =\n" &
    "    if r.isOk: Result[uint32, string].ok(uint32(r.value.brokerCtx))\n" &
    "    else: Result[uint32, string].err(r.error)\n" &
    "  let envBytes = cborEncodeResultEnvelope(mapped)\n" & "  if envBytes.isOk:\n" &
    "    return envBytes.value\n" & "  return @[]\n"
  parseStmt(src)

proc emitArgInstanceAdapter(
    typeIdent, adapterIdent, argsTypeIdent: NimNode, argParams: seq[NimNode]
): NimNode {.compileTime, raises: [ValueError].} =
  var fieldNames: seq[string] = @[]
  for paramDefs in argParams:
    let lastIdx = paramDefs.len - 1
    for nameIdx in 0 ..< lastIdx - 1:
      let nameNode = paramDefs[nameIdx]
      let nameStr =
        case nameNode.kind
        of nnkIdent, nnkSym:
          $nameNode
        of nnkPostfix:
          $nameNode[1]
        of nnkPragmaExpr:
          $nameNode[0]
        else:
          $nameNode
      fieldNames.add(nameStr)
  var argList = ""
  for f in fieldNames:
    argList.add(", decoded." & f)
  let src =
    "proc " & $adapterIdent & "*(\n" & "    ctx: BrokerContext, reqBuf: seq[byte]\n" &
    "): Future[seq[byte]] {.async: (raises: []), gcsafe.} =\n" &
    "  let decRes = cborDecode(reqBuf, " & $argsTypeIdent & ")\n" &
    "  if decRes.isErr:\n" & "    let errEnv = cborEncodeResultEnvelope(\n" &
    "      Result[uint32, string].err(\"request decode failed: \" & decRes.error))\n" &
    "    if errEnv.isOk:\n" & "      return errEnv.value\n" & "    return @[]\n" &
    "  let decoded = decRes.value\n" & "  let r = await " & $typeIdent & ".request(ctx" &
    argList & ")\n" & "  if r.isOk:\n" &
    "    installApiListenersForCtx(r.value.brokerCtx)\n" & "  let mapped =\n" &
    "    if r.isOk: Result[uint32, string].ok(uint32(r.value.brokerCtx))\n" &
    "    else: Result[uint32, string].err(r.error)\n" &
    "  let envBytes = cborEncodeResultEnvelope(mapped)\n" & "  if envBytes.isOk:\n" &
    "    return envBytes.value\n" & "  return @[]\n"
  parseStmt(src)

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc generateApiCborRequestBrokerImpl(
    body: NimNode, cfg: MtReqCfg
): NimNode {.raises: [ValueError].} =
  ## Deferred-phase codegen for `RequestBroker(API)` under CBOR mode.
  ## Runs after the typed-phase `autoRegisterApiType` calls have populated
  ## `gApiTypeRegistry` for any external types referenced in the broker
  ## response object or signature parameters (enums, distinct types,
  ## nested objects). Wrapper codegen consumes that registry to emit
  ## typed dataclasses / encoders / decoders.
  result = newStmtList()

  # 1. Emit the underlying MT broker (typed Nim<->Nim dispatch on the
  #    processing thread, identical to the native path). Capacity
  #    config flows in from the outer RequestBroker(API, ...) kwargs —
  #    same knobs as RequestBroker(mt).
  result.add(generateMtRequestBroker(copyNimTree(body), cfg))

  # 2. Determine dispatch tag, payload, signatures, and the schema parse,
  #    supporting both the legacy `signature*` form and the proc-sugar.
  var hasSignatureProc = false
  var hasOtherProc = false
  for stmt in body:
    if stmt.kind == nnkProcDef:
      let nm = stmt[0]
      let nmId = (if nm.kind == nnkPostfix: nm[1] else: nm)
      if ($nmId).startsWith("signature"):
        hasSignatureProc = true
      else:
        hasOtherProc = true
  let isSugar = hasOtherProc and not hasSignatureProc

  var typeIdent: NimNode = nil
  var payloadType: NimNode = nil
  var parsed: ParsedBrokerType
  var zeroArgPresent = false
  var argPresent = false
  var argParams: seq[NimNode] = @[]
  # Wire apiName suffixes. Legacy form keeps its descriptive
  # `signature<Suffix>` mechanism (backward-compatible). The new proc-sugar
  # uses the finalized rule: zero-arg stays bare, arg-based gets `_arg`.
  var zeroApiSuffix = ""
  var argApiSuffix = ""

  proc legacySuffix(sigName: string): string =
    if sigName.len <= "signature".len:
      return ""
    toSnakeCase(sigName["signature".len .. ^1])

  if not isSugar:
    parsed = parseSingleTypeDef(
      body, "RequestBroker", allowRefToNonObject = true, collectFieldInfo = true
    )
    typeIdent = parsed.typeIdent
    payloadType = copyNimTree(typeIdent)
    let sigs = collectSignatures(body)
    zeroArgPresent = not sigs.zeroArg.isNil
    argPresent = not sigs.argSig.isNil
    argParams = sigs.argParams
    if zeroArgPresent and argPresent:
      let zs = legacySuffix(sigs.zeroArgName)
      zeroApiSuffix = (if zs.len > 0: "_" & zs else: "_zero")
      let asfx = legacySuffix(sigs.argSigName)
      argApiSuffix = (if asfx.len > 0: "_" & asfx else: "_args")
  else:
    let sg = parseRequestSugar(body, "RequestBroker", async = true)
    typeIdent = sg.typeIdent
    payloadType = sg.payloadType
    parsed = sg.parsed
    zeroArgPresent = not sg.zeroArgProc.isNil
    argPresent = not sg.argProc.isNil
    argParams = sg.argParams
    if zeroArgPresent and argPresent:
      argApiSuffix = "_arg" # zero-arg stays bare

  let typeName = sanitizeIdentName(typeIdent)
  let apiName = snakeApiName(typeIdent)

  # reduced-A: does this request CREATE AND RETURN a sub-interface instance?
  # (Its Ok payload type is a registered BrokerInterface(API).) If so the wire
  # carries the sub-instance's ctx as a bare uint32 — we skip type registration
  # (the interface ref is never CBOR-encoded) and emit instance adapters below.
  let payloadName = payloadType.repr.strip()
  let returnsIface = (if isApiInterface(payloadName): payloadName else: "")

  # Register the payload type in the schema so wrapper codegen can emit
  # typed structs / aliases. For the proc-sugar POD form this mirrors the
  # legacy `type X = <prim>` registration exactly (wire-identical).
  if returnsIface.len > 0:
    discard # instance-returning request: no payload type to register.
  elif parsed.hasInlineFields:
    registerCborObjectType(typeName, parsed.fieldNames, parsed.fieldTypes)
  elif parsed.isVoid:
    # `void` → a zero-field object: payload-less request, the response
    # envelope carries only the ok/err signal.
    registerCborObjectType(typeName, @[], @[])
  else:
    registerCborPrimitiveType(typeName, parsed)

  # Materialise (paramName, nimType) pairs from the arg-based signature so
  # foreign-language wrapper codegen can emit a typed call signature.
  proc paramFields(argParams: seq[NimNode]): seq[(string, string)] {.compileTime.} =
    for paramDefs in argParams:
      let lastIdx = paramDefs.len - 1
      let typeNode = paramDefs[lastIdx - 1]
      let typeStr = typeNode.repr.strip()
      for nameIdx in 0 ..< lastIdx - 1:
        let nameNode = paramDefs[nameIdx]
        let nameStr =
          case nameNode.kind
          of nnkIdent, nnkSym:
            $nameNode
          of nnkPostfix:
            $nameNode[1]
          of nnkPragmaExpr:
            $nameNode[0]
          else:
            $nameNode
        result.add((nameStr, typeStr))

  # 3. Emit adapters + register descriptors. Naming rule (replaces the old
  #    `_zero`/`_args`): single signature → bare apiName; both slots present →
  #    the zero-arg keeps the bare name, the arg-based gets the `_arg` suffix
  #    (`<broker>Arg` in the foreign wrappers).
  if not zeroArgPresent and not argPresent:
    # No explicit signature — treat as zero-arg, matching the native default.
    let adapterIdent = ident(typeName & "CborAdapter")
    if returnsIface.len > 0:
      result.add(emitZeroArgInstanceAdapter(typeIdent, adapterIdent))
    else:
      result.add(
        emitZeroArgAdapter(typeIdent, payloadType, adapterIdent, parsed.isVoid)
      )
    registerCborRequestEntry(
      apiName, $adapterIdent, typeName, @[], returnsInterface = returnsIface
    )
    return

  if zeroArgPresent:
    let zeroAdapterTag = if argPresent: "Zero" else: ""
    let adapterIdent = ident(typeName & "CborAdapter" & zeroAdapterTag)
    if returnsIface.len > 0:
      result.add(emitZeroArgInstanceAdapter(typeIdent, adapterIdent))
    else:
      result.add(
        emitZeroArgAdapter(typeIdent, payloadType, adapterIdent, parsed.isVoid)
      )
    registerCborRequestEntry(
      apiName & zeroApiSuffix,
      $adapterIdent,
      typeName,
      @[],
      returnsInterface = returnsIface,
    )

  if argPresent:
    let argAdapterTag = if zeroArgPresent: "Args" else: ""
    let adapterIdent = ident(typeName & "CborAdapter" & argAdapterTag)
    let argsTypeIdent = ident(typeName & "CborArgs" & argAdapterTag)
    result.add(emitArgsType(argsTypeIdent, argParams))
    if returnsIface.len > 0:
      result.add(
        emitArgInstanceAdapter(typeIdent, adapterIdent, argsTypeIdent, argParams)
      )
    else:
      result.add(
        emitArgAdapter(
          typeIdent, payloadType, adapterIdent, argsTypeIdent, argParams, parsed.isVoid
        )
      )
    let fields = paramFields(argParams)
    registerCborRequestEntry(
      apiName & argApiSuffix,
      $adapterIdent,
      typeName,
      fields,
      returnsInterface = returnsIface,
    )

  when defined(brokerDebug):
    writeBrokerDebug(
      "RequestBrokerApi", typeName, result, header = "apiName='" & apiName & "'"
    )
    when defined(brokerDebugStdout):
      echo "[brokers/cbor] RequestBroker(API) for '" & typeName & "' (apiName='" &
        apiName & "')"
      echo result.repr

{.pop.}

macro generateApiCborRequestBrokerDeferred*(args: varargs[untyped]): untyped =
  ## Typed-phase deferred codegen entry point. By the time this expands,
  ## any preceding `autoRegisterApiType` calls have already populated
  ## `gApiTypeRegistry`, so wrapper codegen can introspect external
  ## enum / distinct / object types without falling back to TODO stubs.
  ##
  ## Args layout: [body, kw0, kw1, ...]. Kwargs are forwarded as raw
  ## `nnkExprEqExpr` nodes from `generateApiCborRequestBroker` and
  ## re-parsed here into an MtReqCfg.
  if args.len == 0:
    error("generateApiCborRequestBrokerDeferred requires a body", args)
  let body = args[0]
  var kwargs: seq[NimNode]
  for i in 1 ..< args.len:
    kwargs.add(args[i])
  let cfg = parseMtReqKwargs(kwargs)
  generateApiCborRequestBrokerImpl(body, cfg)

{.push raises: [].}

proc generateApiCborRequestBroker*(body: NimNode, kwargs: seq[NimNode]): NimNode =
  ## Two-phase entry point — mirrors the native
  ## `generateApiRequestBroker` pattern. Kwargs are passed through the
  ## deferred macro call as raw nodes so the typed-phase expansion sees
  ## the original literal values for `parseMtReqKwargs`.
  result = newStmtList()

  let externalIdents = discoverExternalTypes(body)
  if externalIdents.len > 0:
    result.add(emitAutoRegistrations(externalIdents))

  let deferred =
    newCall(ident("generateApiCborRequestBrokerDeferred"), copyNimTree(body))
  for kw in kwargs:
    deferred.add(copyNimTree(kw))
  result.add(deferred)

{.pop.}

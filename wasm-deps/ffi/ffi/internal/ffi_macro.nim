import std/[macros, options, tables, strutils]
from std/os import `/`, relativePath
from std/compilesettings import querySetting, SingleValueSetting
import chronos
import ../ffi_types
import ../ffi_thread_request
import ../codegen/[meta, string_helpers]
import ./c_macro_helpers
import ./ffi_scalar
import ./ffi_route
import ./ffi_export
import ./ffi_codegen_common
when defined(ffiGenBindings):
  import ../codegen/rust
  import ../codegen/cpp
  import ../codegen/c
  import ../codegen/cddl

proc requireLibraryDeclared(where: string) {.compileTime.} =
  ## Enforce that `declareLibrary(...)` ran before this annotation.
  if not libraryDeclared:
    error(
      where &
        ": declareLibrary(name, LibType[, defaultABIFormat]) must be called before any FFI annotation"
    )

proc resolveEventWireName(
    leading: seq[NimNode], userProcName: NimNode
): tuple[wireName: string, abiSpecStart: int] {.compileTime.} =
  ## A leading string that isn't an `"abi = ..."` spec is the explicit wire name;
  ## otherwise derive from the proc. Returns name and index where ABI specs begin.
  if leading.len > 0 and leading[0].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit} and
      ($leading[0]).len > 0 and not parseAbiSpec($leading[0]).ok:
    ($leading[0], 1)
  else:
    (camelToSnakeCase($userProcName), 0)

proc requireBeforeGenBindings(where: string) {.compileTime.} =
  ## Enforce this annotation expands before `genBindings()`; anything registered
  ## afterwards never reaches the generator.
  if genBindingsEmitted:
    error(
      where &
        " appears after genBindings(); genBindings() must be the LAST FFI call in the compilation root, after every {.ffi.}/{.ffiCtor.}/{.ffiDtor.}/{.ffiEvent.} annotation"
    )

proc resolveABIFormat(abiSpecs: seq[NimNode]): ABIFormat {.compileTime.} =
  ## Resolve ABI from optional `"abi = ..."` specs (last wins), else lib default.
  var fmt = currentDefaultABIFormat
  for override in abiSpecs:
    if override.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      error(
        "FFI ABI override must be a string literal like \"abi = c\", got: " &
          override.repr
      )
    let parsed = parseAbiSpec($override)
    if not parsed.ok:
      error(parsed.err)
    fmt = parsed.fmt
  fmt

proc resolveFFISpecs(specs: seq[NimNode]): ABIFormat {.compileTime.} =
  ## Resolve `"abi = ..."` specs (last wins), else the library-default ABI.
  var abi = currentDefaultABIFormat
  for override in specs:
    if override.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      error(
        "FFI override must be a string literal like \"abi = c\", got: " & override.repr
      )
    case overrideKey($override)
    of "abi":
      let parsed = parseAbiSpec($override)
      if not parsed.ok:
        error(parsed.err)
      abi = parsed.fmt
    else:
      error("unknown FFI override '" & $override & "'; expected `abi = ...`")
  abi

proc gateABIFormat(fmt: ABIFormat, where: string) {.compileTime.} =
  ## Abort if the selected ABI's codegen isn't wired yet, failing loudly.
  if not abiCodegenImplemented(fmt):
    error(
      where &
        ": ABI format is recognized but not yet implemented (only 'cbor' currently generates working bindings): " &
        $fmt
    )

proc gateFFITypeABIFormat(fmt: ABIFormat, where: string) {.compileTime.} =
  ## Type annotations only register metadata; both ABIs are valid.
  case fmt
  of ABIFormat.Cbor, ABIFormat.C: discard

proc isPtr(typ: NimNode): bool =
  ## True iff `typ` is a `ptr T` type expression.
  typ.kind == nnkPtrTy

proc rejectRawPtrType(typ: NimNode, where: string) =
  ## Reject `pointer`/`ptr T` at macro time: no unvalidatable raw address may
  ## cross the FFI boundary (only the framework-managed ctx handle may). `object`
  ## and `ref T` are fine — they flow as value copies through cbor_serialization.
  if typ.kind == nnkPtrTy:
    error(
      where & ": raw `ptr T` is not allowed across the FFI boundary " &
        "(only the ctx handle, managed by the framework, may be a pointer)"
    )
  if typ.kind == nnkIdent and $typ == "pointer":
    error(
      where & ": raw `pointer` is not allowed across the FFI boundary " &
        "(only the ctx handle, managed by the framework, may be a pointer)"
    )

proc enumWireName(rhs: NimNode, fieldName: string): string {.compileTime.} =
  ## What `$value` yields: the associated string if the enum declares one
  ## (`cRed = "red"` or `cRed = (3, "red")`), else the symbol name.
  case rhs.kind
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    $rhs
  of nnkTupleConstr, nnkPar:
    if rhs.len == 2 and rhs[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      $rhs[1]
    else:
      fieldName
  else:
    fieldName

proc enumValueMetas(
    enumTy: NimNode, typeName: string
): seq[FFIEnumValueMeta] {.compileTime.} =
  ## Walks an `nnkEnumTy`, resolving each value's wire name and ordinal.
  var values: seq[FFIEnumValueMeta] = @[]
  var nextOrd = 0
  for child in enumTy:
    if child.kind == nnkEmpty:
      continue
    var name: string
    var wire: string
    var ordinal = nextOrd
    case child.kind
    of nnkIdent, nnkSym:
      name = $child
      wire = name
    of nnkEnumFieldDef:
      name = $child[0]
      wire = enumWireName(child[1], name)
      let explicitOrd =
        if child[1].kind == nnkIntLit:
          some(int(child[1].intVal))
        elif child[1].kind in {nnkTupleConstr, nnkPar} and child[1].len == 2 and
          child[1][0].kind == nnkIntLit:
          some(int(child[1][0].intVal))
        else:
          none(int)
      if explicitOrd.isSome():
        ordinal = explicitOrd.get()
    else:
      error("`.ffi.` enum " & typeName & ": unsupported enum value " & child.repr)
    values.add(FFIEnumValueMeta(name: name, wire: wire, ord: ordinal))
    nextOrd = ordinal + 1
  values

proc registerFFIEnumInfo(
    typeDef: NimNode, typeNameStr: string, abiFormat: ABIFormat
) {.compileTime.} =
  ## Registers an `{.ffi.}` enum. Only the CBOR wire carries enums; `abi = c`
  ## has no representation for them yet, so reject it at the annotation.
  if abiFormat == ABIFormat.C:
    error(
      "`.ffi.` enum " & typeNameStr &
        ": `abi = c` does not support enum types yet; use the CBOR ABI for this type"
    )
  ffiTypeRegistry.add(
    FFITypeMeta(
      name: typeNameStr,
      abiFormat: abiFormat,
      enumValues: enumValueMetas(typeDef[2], typeNameStr),
    )
  )
  ffiEnumTypeNames.add(typeNameStr)

proc registerFFITypeInfo(
    typeDef: NimNode, abiFormat: ABIFormat
): NimNode {.compileTime.} =
  ## Registers the type in ffiTypeRegistry and returns the clean typeDef.
  let typeName =
    if typeDef[0].kind == nnkPostfix:
      typeDef[0][1]
    else:
      typeDef[0]
  let typeNameStr = $typeName

  if typeDef[2].kind == nnkEnumTy:
    registerFFIEnumInfo(typeDef, typeNameStr, abiFormat)
    return typeDef

  var fieldMetas: seq[FFIFieldMeta] = @[]
  let objTy = typeDef[2]
  if objTy.kind == nnkObjectTy and objTy.len >= 3:
    let recList = objTy[2]
    if recList.kind == nnkRecList:
      for identDef in recList:
        if identDef.kind == nnkIdentDefs:
          let fieldType = identDef[^2]
          for i in 0 ..< identDef.len - 2:
            rejectRawPtrType(
              fieldType, "{.ffi.} type " & typeNameStr & "." & $identDef[i]
            )
          let fieldTypeName =
            if fieldType.kind == nnkIdent:
              $fieldType
            else:
              fieldType.repr
          for i in 0 ..< identDef.len - 2:
            fieldMetas.add(FFIFieldMeta(name: $identDef[i], typeName: fieldTypeName))

  ffiTypeRegistry.add(
    FFITypeMeta(name: typeNameStr, fields: fieldMetas, abiFormat: abiFormat)
  )
  return typeDef

func extractDocComment(prc: NimNode): string {.compileTime.} =
  ## The proc's leading `##`, or "". Nim drops comments outside a proc body, so
  ## types and fields are unreachable from here.
  let body = prc[^1]
  if body.kind != nnkStmtList or body.len == 0:
    return ""
  if body[0].kind != nnkCommentStmt:
    return ""
  return body[0].strVal

proc nimTypeNameRepr(typ: NimNode): string =
  ## Stringifies a parameter or field type for the registry.
  case typ.kind
  of nnkIdent:
    $typ
  of nnkPtrTy:
    "ptr " & nimTypeNameRepr(typ[0])
  else:
    typ.repr

proc isHandleType(typ: NimNode): bool =
  ## True iff `typ` is an `{.ffiHandle.}` type — its wire form is `uint64`.
  typ.kind == nnkIdent and isFFIHandleTypeName($typ)

proc storageType(typ: NimNode): NimNode =
  ## In-Req-struct storage type: `cstring`->`string`, handle->`uint64`, else as-is.
  if typ.kind == nnkIdent and $typ == "cstring":
    return ident("string")
  if isHandleType(typ):
    return ident("uint64")
  typ

proc unpackReqField*(fieldIdent, userType, decodedIdent: NimNode): NimNode =
  ## Emits AST unpacking one field of a CBOR-decoded Req into a local of the
  ## user's original type. `cstring` (stored as `string`) is cast back on unpack,
  ## safe because `decodedIdent` outlives the cstring use in the generated body.
  let storedAsString = userType.kind == nnkIdent and $userType == "cstring"
  if not storedAsString:
    return newLetStmt(fieldIdent, newDotExpr(decodedIdent, fieldIdent))

  let fieldAccess = newDotExpr(decodedIdent, fieldIdent)
  let castExpr = newDotExpr(fieldAccess, ident("cstring"))
  return
    nnkLetSection.newTree(nnkIdentDefs.newTree(fieldIdent, ident("cstring"), castExpr))

proc unpackHandleField*(
    fieldIdent, userType, ctxIdent, decodedIdent: NimNode
): NimNode =
  ## Reconstitutes a handle param from its wire `uint64` via the ctx registry.
  let errPrefix = "ffiHandle for parameter '" & $fieldIdent & "': "
  quote:
    let `fieldIdent` = block:
      let ffiH = `ctxIdent`[].handles.lookup(`decodedIdent`.`fieldIdent`, $`userType`).valueOr:
        return err(`errPrefix` & error)
      cast[`userType`](ffiH)

proc cExportedParams(ctxType: NimNode, withCtx = true): seq[NimNode] =
  ## C-exported wrapper param list (cint; ctx, callback, userData, reqCbor,
  ## reqCborLen). A `{.ffiStatic.}` wrapper drops the leading `ctx`.
  var params: seq[NimNode] = @[]
  params.add(ident("cint"))
  if withCtx:
    params.add(newIdentDefs(ident("ctx"), ctxType))
  params.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  params.add(newIdentDefs(ident("userData"), ident("pointer")))
  params.add(newIdentDefs(ident("reqCbor"), nnkPtrTy.newTree(ident("byte"))))
  params.add(newIdentDefs(ident("reqCborLen"), ident("csize_t")))
  return params

proc buildReqTypeFromFields(
    reqTypeName: NimNode, paramNames: seq[string], paramTypes: seq[NimNode]
): NimNode =
  ## Builds the exported per-proc Req `type Foo* = object` from parallel name/type
  ## lists. `cstring` fields become `string`; an empty param list gets a single
  ## `_placeholder: uint8` field since Nim rejects an empty object body here.
  var fields: seq[NimNode] = @[]
  for i in 0 ..< paramNames.len:
    let storedType = storageType(paramTypes[i])
    fields.add newTree(nnkIdentDefs, ident(paramNames[i]), storedType, newEmptyNode())

  let recList =
    if fields.len > 0:
      newTree(nnkRecList, fields)
    else:
      newTree(
        nnkRecList,
        newTree(nnkIdentDefs, ident("_placeholder"), ident("uint8"), newEmptyNode()),
      )

  let objTy = newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), recList)

  let typeName =
    if reqTypeName.kind == nnkPostfix:
      reqTypeName
    else:
      postfix(reqTypeName, "*")

  return
    newNimNode(nnkTypeSection).add(newTree(nnkTypeDef, typeName, newEmptyNode(), objTy))

proc buildRequestType(reqTypeName: NimNode, body: NimNode): NimNode =
  ## Builds the per-proc Req object type from a registerReqFFI lambda body,
  ## mirroring its param names and types (`cstring` -> `string`).
  var procNode = body
  if procNode.kind == nnkStmtList and procNode.len == 1:
    procNode = procNode[0]
  if procNode.kind != nnkLambda and procNode.kind != nnkProcDef:
    error "registerReqFFI expects a lambda proc, found: " & $procNode.kind

  let params = procNode[3]
  var paramNames: seq[string] = @[]
  var paramTypes: seq[NimNode] = @[]
  for p in params[1 .. ^1]:
    paramNames.add($p[0])
    paramTypes.add(p[1])

  let typeSection = buildReqTypeFromFields(reqTypeName, paramNames, paramTypes)

  when defined(ffiDumpMacros):
    echo typeSection.repr
  return typeSection

proc buildFFINewReqProc(reqTypeName, body: NimNode): NimNode =
  ## Builds ffiNewReq: packs the user's typed params into a Req, CBOR-encodes it,
  ## and constructs the FFIThreadRequest that owns the buffer.
  var formalParams = newSeq[NimNode]()

  var procNode: NimNode
  if body.kind == nnkStmtList and body.len == 1:
    procNode = body[0]
  else:
    procNode = body

  if procNode.kind != nnkLambda and procNode.kind != nnkProcDef:
    error "registerReqFFI expects a lambda definition. Found: " & $procNode.kind

  let typedescParam =
    newIdentDefs(ident("T"), nnkBracketExpr.newTree(ident("typedesc"), reqTypeName))
  formalParams.add(typedescParam)
  formalParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  formalParams.add(newIdentDefs(ident("userData"), ident("pointer")))

  # Handle params travel as their uint64 id; others keep the user's type.
  let procParams = procNode[3]
  for p in procParams[1 .. ^1]:
    if isHandleType(p[1]):
      formalParams.add(newIdentDefs(p[0], ident("uint64")))
      continue
    formalParams.add(p)

  let retType = newNimNode(nnkPtrTy)
  retType.add(ident("FFIThreadRequest"))

  formalParams = @[retType] & formalParams

  let reqObjIdent = ident("reqObj")
  var newBody = newStmtList()
  newBody.add(
    quote do:
      var `reqObjIdent`: T
  )

  for p in procParams[1 .. ^1]:
    let fieldName = ident($p[0])
    let userType = p[1]
    let storeAsString = userType.kind == nnkIdent and $userType == "cstring"
    if storeAsString:
      newBody.add(
        quote do:
          `reqObjIdent`.`fieldName` = $`fieldName`
      )
    else:
      newBody.add(
        quote do:
          `reqObjIdent`.`fieldName` = `fieldName`
      )

  let reqNameLit = newLit($unwrapPostfix(reqTypeName))
  newBody.add(
    quote do:
      # Encode into shared memory, avoiding a second seq[byte] copy.
      let (sharedData, sharedLen) = cborEncodeShared(`reqObjIdent`)
      return FFIThreadRequest.initFromOwnedShared(
        callback, userData, cstring(`reqNameLit`), sharedData, sharedLen
      )
  )

  let newReqProc = newProc(
    name = postfix(ident("ffiNewReq"), "*"),
    params = formalParams,
    body = newBody,
    pragmas = newEmptyNode(),
  )

  when defined(ffiDumpMacros):
    echo newReqProc.repr
  return newReqProc

proc reqDecodePreamble(
    reqTypeName, reqIdent, decodedIdent: NimNode, abi: ABIFormat
): NimNode =
  ## Materialise the typed Req from the request payload. `abi = c` unpacks the
  ## packed `_CWire` struct the caller thread handed over and frees it here (the
  ## unpack deep-copies into Nim memory); the envelope buffer itself goes with
  ## `deleteRequest`. Otherwise the payload is CBOR.
  if abi != ABIFormat.C:
    return quote:
      let `reqIdent`: ptr FFIThreadRequest = cast[ptr FFIThreadRequest](request)
      let `decodedIdent` = cborDecodePtr(
        cast[ptr UncheckedArray[byte]](`reqIdent`[].data),
        `reqIdent`[].dataLen,
        `reqTypeName`,
      ).valueOr:
        return err("CBOR decode failed for " & $T & ": " & $error)

  let wireType = ident(cwireTypeName($reqTypeName))
  let wirePtr = genSym(nskLet, "wireReq")
  return quote:
    let `reqIdent`: ptr FFIThreadRequest = cast[ptr FFIThreadRequest](request)
    if `reqIdent`[].data.isNil() or `reqIdent`[].dataLen != sizeof(`wireType`):
      return err("abi = c: unexpected request payload size for " & $T)
    let `wirePtr` = cast[ptr `wireType`](`reqIdent`[].data)
    let `decodedIdent` = cwireUnpack(`wirePtr`[])
    cwireFree(`wirePtr`[])

proc buildProcessFFIRequestProc(
    reqTypeName, reqHandler, body: NimNode, abi: ABIFormat
): NimNode =
  ## FFI-thread processor: materialises the Req, unpacks fields, runs user body.
  if reqHandler.kind != nnkExprColonExpr:
    error(
      "Second argument must be a typed parameter, e.g., waku: ptr Waku. Found: " &
        $reqHandler.kind
    )

  let rhs = reqHandler[1]
  if rhs.kind != nnkPtrTy:
    error("Second argument must be a pointer type, e.g., waku: ptr Waku")

  var procNode = body
  if procNode.kind == nnkStmtList and procNode.len == 1:
    procNode = procNode[0]
  if procNode.kind != nnkLambda and procNode.kind != nnkProcDef:
    error "registerReqFFI expects a lambda definition. Found: " & $procNode.kind

  let typedescParam =
    newIdentDefs(ident("T"), nnkBracketExpr.newTree(ident("typedesc"), reqTypeName))

  let procParams = procNode[3]
  var formalParams: seq[NimNode] = @[]
  formalParams.add(procParams[0])
  formalParams.add(typedescParam)
  formalParams.add(newIdentDefs(ident("request"), ident("pointer")))
  formalParams.add(newIdentDefs(reqHandler[0], rhs))

  let bodyNode =
    if procNode.body.kind == nnkStmtList:
      procNode.body
    else:
      newStmtList(procNode.body)

  let newBody = newStmtList()
  let reqIdent = genSym(nskLet, "ffiReq")
  let decodedIdent = genSym(nskLet, "decoded")

  newBody.add reqDecodePreamble(reqTypeName, reqIdent, decodedIdent, abi)

  for p in procParams[1 ..^ 1]:
    if isHandleType(p[1]):
      newBody.add unpackHandleField(p[0], p[1], reqHandler[0], decodedIdent)
      continue
    newBody.add unpackReqField(p[0], p[1], decodedIdent)

  newBody.add(bodyNode)

  let processProc = newProc(
    name = postfix(ident("processFFIRequest"), "*"),
    params = formalParams,
    body = newBody,
    procType = nnkProcDef,
    pragmas =
      if procNode.len >= 5:
        procNode[4]
      else:
        newEmptyNode(),
  )

  when defined(ffiDumpMacros):
    echo processProc.repr
  return processProc

proc replyEncode(
    typedResIdent, handlerCtxIdent, respType: NimNode, abi: ABIFormat
): NimNode =
  ## Lower the handler's typed value into the `seq[byte]` reply payload. `abi = c`
  ## rides raw — a `string` as its own UTF-8, an object as the native image of its
  ## packed `_CWire`, whose buffers the reply trampoline frees.
  if abi == ABIFormat.C:
    if isStringType(respType):
      return quote:
        return ok(ffiRawRetBytes(`typedResIdent`.value))
    let wireType = ident(cwireTypeName($respType))
    let wireIdent = genSym(nskVar, "replyWire")
    return quote:
      var `wireIdent`: `wireType`
      cwirePack(`wireIdent`, `typedResIdent`.value)
      return ok(cwireStructBytes(`wireIdent`))

  return quote:
    # A `seq[byte]` result goes on the wire as CBOR, the same as every other
    # `abi = cbor` return. The C, C++ and Rust decoders expect CBOR. They reject
    # raw bytes with the error "value encoded in non-canonical form".
    when typeof(`typedResIdent`.value) is void:
      return ok(newSeq[byte]())
    elif typeof(`typedResIdent`.value) is FFIHandleRoot:
      return ok(
        encodeHandle(
          `handlerCtxIdent`[].handles.register(
            `typedResIdent`.value, $typeof(`typedResIdent`.value)
          )
        )
      )
    else:
      return ok(cborEncode(`typedResIdent`.value))

proc addNewRequestToRegistry(
    reqTypeName, reqHandler, respType: NimNode, abi: ABIFormat
): NimNode =
  ## Dispatcher the FFI thread calls: runs processFFIRequest and lowers the typed
  ## T value into the seq[byte] payload.
  let returnType = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(
      ident("Result"),
      nnkBracketExpr.newTree(ident("seq"), ident("byte")),
      ident("string"),
    ),
  )

  let rhsType =
    if reqHandler.kind == nnkExprColonExpr:
      reqHandler[1]
    else:
      error "Second argument must be a typed parameter, e.g. waku: ptr Waku"

  let handlerCtxIdent = genSym(nskLet, "handlerCtx")

  let callExpr = newCall(
    newDotExpr(reqTypeName, ident("processFFIRequest")),
    ident("request"),
    handlerCtxIdent,
  )

  let typedResIdent = genSym(nskLet, "typedRes")

  var newBody = newStmtList()
  newBody.add quote do:
    let `handlerCtxIdent` = cast[`rhsType`](reqHandler)
    let `typedResIdent` = await `callExpr`
    if `typedResIdent`.isErr:
      return err(`typedResIdent`.error)

  newBody.add replyEncode(typedResIdent, handlerCtxIdent, respType, abi)

  let asyncProc = newProc(
    name = newEmptyNode(),
    params = @[
      returnType,
      newIdentDefs(ident("request"), ident("pointer")),
      newIdentDefs(ident("reqHandler"), ident("pointer")),
    ],
    body = newBody,
    pragmas = nnkPragma.newTree(ident("async")),
  )

  let key = newLit($reqTypeName)
  let regAssign =
    newAssignment(newTree(nnkBracketExpr, ident("registeredRequests"), key), asyncProc)

  when defined(ffiDumpMacros):
    echo regAssign.repr
  return regAssign

macro registerReqFFI*(reqTypeName, reqHandler, body: untyped): untyped =
  ## Registers a request handled by the FFI/working thread. The lambda takes only
  ## no-GC'ed params (cstring travels as `string`) and must return
  ## Future[Result[string, string]] {.async.}.
  let typeDef = buildRequestType(reqTypeName, body)
  let ffiNewReqProc = buildFFINewReqProc(reqTypeName, body)
  let processProc =
    buildProcessFFIRequestProc(reqTypeName, reqHandler, body, ABIFormat.Cbor)
  let addNewReqToReg =
    addNewRequestToRegistry(reqTypeName, reqHandler, newEmptyNode(), ABIFormat.Cbor)
  let stmts = newStmtList(typeDef, ffiNewReqProc, processProc, addNewReqToReg)

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

macro processReq*(
    reqType, ctx, callback, userData: untyped, args: varargs[untyped]
): untyped =
  ## Expands T.processReq(ctx, callback, userData, args...) into a
  ## sendRequestToFFIThread call, reporting errors via `callback`.
  var callArgs = @[reqType, callback, userData]
  for a in args:
    callArgs.add a

  let newReqCall = newCall(ident("ffiNewReq"), callArgs)

  let sendCall = newCall(
    newDotExpr(ident("ffi_context"), ident("sendRequestToFFIThread")), ctx, newReqCall
  )

  let blockExpr = quote:
    block:
      let res = `sendCall`
      if res.isErr():
        let msg = "error in sendRequestToFFIThread: " & res.error
        `callback`(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), `userData`)
        return RET_ERR
      return RET_OK

  when defined(ffiDumpMacros):
    echo blockExpr.repr
  return blockExpr

macro ffiRaw*(args: varargs[untyped]): untyped =
  ## Raw/legacy FFI proc: first three params (ctx, callback, userData) are explicit,
  ## extra no-GC'ed params travel as one CBOR blob, return is implied
  ## Future[Result[string, string]] {.async.}. Override abi via `{.ffiRaw: "abi = c".}`.
  requireBeforeGenBindings("`.ffiRaw.`")
  requireLibraryDeclared("`.ffiRaw.`")
  let prc = args[^1]
  let rawAbiFormat = resolveFFISpecs(args[0 ..^ 2])
  gateABIFormat(rawAbiFormat, "`.ffiRaw.` proc")

  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  if formalParams.len < 2:
    error("`.ffiRaw.` procs require at least 1 parameter")

  let firstParam = formalParams[1]
  let paramIdent = firstParam[0]
  let paramType = firstParam[1]

  let libTypeName = paramType[0][1]
  let poolIdent = ident($libTypeName & "FFIPool")

  let reqName = ident($procName & "Req")
  let returnType = ident("cint")

  var newParams = newSeq[NimNode]()
  newParams.add(returnType)
  for i in 1 ..< formalParams.len:
    newParams.add(newIdentDefs(formalParams[i][0], formalParams[i][1]))

  let futReturnType = quote:
    Future[Result[string, string]]

  var userParams = newSeq[NimNode]()
  userParams.add(futReturnType)
  if formalParams.len > 3:
    for i in 4 ..< formalParams.len:
      userParams.add(newIdentDefs(formalParams[i][0], formalParams[i][1]))

  var argsList = newSeq[NimNode]()
  for i in 1 ..< formalParams.len:
    argsList.add(formalParams[i][0])

  let dotExpr = newTree(nnkDotExpr, reqName, ident"processReq")

  let callNode = newTree(nnkCall, dotExpr)
  for arg in argsList:
    callNode.add(arg)

  let ffiBody = newStmtList(
    quote do:
      initializeLibrary()
      if not `poolIdent`.isValidCtx(cast[pointer](ctx)):
        return RET_ERR
      ctx[].userData = userData
      if isNil(callback):
        return RET_MISSING_CALLBACK
  )

  ffiBody.add(callNode)

  let ffiProc = newProc(
    name = procName,
    params = newParams,
    body = ffiBody,
    pragmas = newTree(nnkPragma, ident "dynlib", ident "exportc", ident "cdecl"),
  )

  var anonymousProcNode = newProc(
    name = newEmptyNode(),
    params = userParams,
    body = newStmtList(bodyNode),
    pragmas = newTree(nnkPragma, ident"async"),
  )

  let registerReq = quote:
    registerReqFFI(`reqName`, `paramIdent`: `paramType`):
      `anonymousProcNode`

  let stmts = newStmtList(registerReq, ffiProc)

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

macro ffiHandle*(args: varargs[untyped]): untyped =
  ## Marks a `ref object` as an opaque FFI handle: it rides as a `uint64` id while
  ## the live object stays in the per-ctx registry. An `"abi = ..."` spec is
  ## accepted but only validated (a handle is abi-agnostic).
  requireBeforeGenBindings("`.ffiHandle.`")
  requireLibraryDeclared("`.ffiHandle.`")
  let prc = args[^1]
  discard resolveABIFormat(args[0 ..^ 2])
  if prc.kind != nnkTypeDef:
    error("`.ffiHandle.` must be applied to a type definition")

  var clean = prc.copyNimTree()
  if clean[0].kind == nnkPragmaExpr:
    clean[0] = clean[0][0]

  let typeName =
    if clean[0].kind == nnkPostfix:
      clean[0][1]
    else:
      clean[0]

  let refTy = clean[2]
  if refTy.kind != nnkRefTy or refTy[0].kind != nnkObjectTy:
    error("`.ffiHandle.` type " & $typeName & " must be a `ref object`")
  let objTy = refTy[0]
  if objTy[1].kind != nnkEmpty:
    error("`.ffiHandle.` type " & $typeName & " must not already inherit a base")
  # Inherit the registry's storable base so handle refs share one static type.
  objTy[1] = nnkOfInherit.newTree(ident("FFIHandleRoot"))

  ffiHandleTypeNames.add($typeName)

  when defined(ffiDumpMacros):
    echo clean.repr
  return clean

proc registerFFIConst(nameNode: NimNode): NimNode {.compileTime.} =
  ## Emits the type guard plus the `static:` block that records the const's
  ## evaluated value; `$typeof` runs after the const is defined, so computed
  ## expressions (`3 * 7`) land in the registry as their result.
  let nameStr = newLit($nameNode)
  let unsupported = newLit(
    "`.ffiConst.` " & $nameNode &
      ": only integer, float, bool and string consts can cross the FFI boundary"
  )
  # bindSym: the emitted code lands in the user's module, which doesn't import meta.
  let registry = bindSym("ffiConstRegistry")
  let metaType = bindSym("FFIConstMeta")
  quote:
    when not (`nameNode` is (SomeInteger | SomeFloat | bool | string)):
      {.error: `unsupported`.}
    static:
      `registry`.add(
        `metaType`(name: `nameStr`, typeName: $typeof(`nameNode`), value: $(`nameNode`))
      )

macro ffiConst*(args: varargs[untyped]): untyped =
  ## Exposes a Nim `const` to the generated bindings as a native constant
  ## (`static const` in C/C++, `pub const` in Rust). An `"abi = ..."` spec is
  ## accepted but only validated — a constant never rides the wire.
  requireBeforeGenBindings("`.ffiConst.`")
  requireLibraryDeclared("`.ffiConst.`")
  let section = args[^1]
  discard resolveABIFormat(args[0 ..^ 2])
  if section.kind != nnkConstSection:
    error("`.ffiConst.` must be applied to a `const` definition")

  # Nim splits the section so only the annotated defs reach this macro.
  var stmts = newStmtList(section.copyNimTree())
  for def in section:
    let nameNode =
      if def[0].kind == nnkPostfix:
        def[0][1]
      else:
        def[0]
    stmts.add(registerFFIConst(nameNode))

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

proc buildFFIProc(
    prc: NimNode, abiFormat: ABIFormat, isStatic: bool
): NimNode {.compileTime.} =
  ## Shared body of `{.ffi.}` and `{.ffiStatic.}`. A static has no library receiver:
  ## its wire params start at param 1 and its C wrapper binds the static context.
  let where = if isStatic: "`.ffiStatic.`" else: "`.ffi.`"

  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  if not isStatic and formalParams.len < 2:
    error("`.ffi.` procs require at least 1 parameter (the library type)")

  var recvName, recvType: NimNode = newEmptyNode()
  var firstIsHandle = false
  if not isStatic:
    let firstParam = formalParams[1]
    recvName = firstParam[0]
    recvType = firstParam[1]
    firstIsHandle = isHandleType(recvType)
  if (firstIsHandle or isStatic) and currentLibType.len == 0:
    let why =
      if isStatic: " takes no library param" else: " has an {.ffiHandle.} receiver"
    error(
      where & " proc " & $procName & why & " but no library is declared; " &
        "call declareLibrary(name, LibType) first"
    )
  # Neither carries a library type, so fall back to the declared one.
  let libTypeName =
    if firstIsHandle or isStatic:
      ident(currentLibType)
    else:
      recvType

  let retTypeNode = formalParams[0]
  if retTypeNode.kind == nnkEmpty:
    error(
      where & " proc must have an explicit return type Future[Result[RetType, string]]"
    )
  if retTypeNode.kind != nnkBracketExpr or $retTypeNode[0] != "Future":
    error(
      where & " return type must be Future[Result[RetType, string]], got: " &
        retTypeNode.repr
    )
  let resultInner = retTypeNode[1]
  if resultInner.kind != nnkBracketExpr or $resultInner[0] != "Result":
    error(
      where & " return type must be Future[Result[RetType, string]], got: " &
        retTypeNode.repr
    )

  let resultRetType = resultInner[1]
  rejectRawPtrType(resultRetType, where & " proc " & $procName & " return type")
  # An {.ffiHandle.} lives in one ctx's registry, which a static proc cannot reach.
  if isStatic and isHandleType(resultRetType):
    error(
      where & " proc " & $procName & " returns the {.ffiHandle.} type " & $resultRetType &
        "; a handle belongs to a context. Make it an `{.ffi.}` method instead."
    )

  # A handle receiver rides the wire; a value-type lib receiver binds to ctx.myLib.
  var extraParamNames: seq[string] = @[]
  var extraParamTypes: seq[NimNode] = @[]
  let wireStart = if isStatic or firstIsHandle: 1 else: 2
  for i in wireStart ..< formalParams.len:
    let p = formalParams[i]
    for j in 0 ..< p.len - 2:
      rejectRawPtrType(p[^2], where & " proc " & $procName & " parameter " & $p[j])
      if isStatic and isHandleType(p[^2]):
        error(
          where & " proc " & $procName & " takes the {.ffiHandle.} parameter " & $p[j] &
            ": " & $p[^2] & "; a handle belongs to a context. " &
            "Make it an `{.ffi.}` method instead."
        )
      extraParamNames.add($p[j])
      extraParamTypes.add(p[^2])

  let procNameStr = block:
    let raw = $procName
    if raw.endsWith("*"):
      raw[0 ..^ 2]
    else:
      raw
  let cExportName = camelToSnakeCase(procNameStr)
  let camelName = snakeToPascalCase(procNameStr)

  let reqTypeName = ident(camelName & "Req")

  var userProcName = procName
  if procName.kind == nnkPostfix:
    userProcName = procName[1]
  # Nim proc and C wrapper share the user's name (resolved by overload); the wrapper's `{.exportc.}` keeps the foreign ABI symbol.
  let cExportProcName = userProcName

  let ctxType =
    nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libTypeName))

  proc wireParamMeta(pname: string, ptype: NimNode): FFIParamMeta =
    let isPointer = isPtr(ptype)
    let handle = isHandleType(ptype)
    let tn =
      if isPointer:
        nimTypeNameRepr(ptype[0])
      else:
        nimTypeNameRepr(ptype)
    FFIParamMeta(name: pname, typeName: tn, isPtr: isPointer, isHandle: handle)

  var wireParamMetas: seq[FFIParamMeta] = @[]
  for i in 0 ..< extraParamNames.len:
    wireParamMetas.add(wireParamMeta(extraParamNames[i], extraParamTypes[i]))

  let retTypeInner = resultInner[1]
  let retIsPtr = isPtr(retTypeInner)
  let retIsHandle = isHandleType(retTypeInner)
  let retTn =
    if retIsPtr:
      nimTypeNameRepr(retTypeInner[0])
    else:
      nimTypeNameRepr(retTypeInner)

  # Built once, registered by whichever path runs; reused for the check below.
  let procMeta = FFIProcMeta(
    procName: cExportName,
    libName: currentLibName,
    kind: if isStatic: FFIKind.STATIC else: FFIKind.FFI,
    libTypeName: $libTypeName,
    extraParams: wireParamMetas,
    returnTypeName: retTn,
    returnIsPtr: retIsPtr,
    returnIsHandle: retIsHandle,
    abiFormat: abiFormat,
    doc: extractDocComment(prc),
  )

  # CBOR-free scalar fast path: only `abi = c` with all-scalar params/return that fit the inline slots; non-scalar `abi = c` rides the `_CWire` C-dispatch.
  let scalarEligible =
    abiFormat == ABIFormat.C and isScalarOnly(procMeta) and
    extraParamNames.len <= MaxScalarArgs

  let poolIdent = ident($libTypeName & "FFIPool")

  proc buildCtxGuard(): NimNode =
    ## Nil-checks callback and validates `ctx`, replying `RET_ERR` before build.
    quote:
      if callback.isNil:
        return RET_MISSING_CALLBACK
      if not `poolIdent`.isValidCtx(cast[pointer](ctx)):
        let errStr = "ctx is not a valid FFI context"
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
        return RET_ERR

  proc buildStaticCtxGuard(): NimNode =
    ## Binds the library's static context; a static call may be the host's first
    ## entry, hence `initializeLibrary`.
    # `ctxIdent` is substituted so the send below sees it (`quote` gensyms).
    let ctxIdent = ident("ctx")
    quote:
      initializeLibrary()
      if callback.isNil():
        return RET_MISSING_CALLBACK
      let `ctxIdent` = `poolIdent`.staticFFIContext().valueOr:
        let errStr = "ffiStatic: " & error
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
        return RET_ERR

  proc buildSendAndReply(reqPtrIdent: NimNode): NimNode =
    ## Hands `reqPtrIdent` to the FFI thread and maps the outcome to a C return code.
    let sendResIdent = genSym(nskLet, "sendRes")
    quote:
      let `sendResIdent` =
        try:
          ffi_context.sendRequestToFFIThread(ctx, `reqPtrIdent`)
        except Exception as exc:
          Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
      if `sendResIdent`.isErr():
        let errStr = "error in sendRequestToFFIThread: " & `sendResIdent`.error
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
        return RET_ERR
      return RET_OK

  proc buildCExportProc(params: seq[NimNode], body: NimNode): NimNode =
    ## The dynlib/exportc/cdecl C-ABI wrapper both wire paths emit.
    newProc(
      name = postfix(cExportProcName, "*"),
      params = params,
      body = body,
      pragmas = newTree(
        nnkPragma,
        ident("dynlib"),
        newTree(nnkExprColonExpr, ident("exportc"), newStrLitNode(cExportName)),
        ident("cdecl"),
        newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
      ),
    )

  proc buildAsyncHelperProc(): NimNode =
    ## Reproduces the user's exact signature so it stays callable from Nim.
    var helperParams = newSeq[NimNode]()
    helperParams.add(retTypeNode)
    let helperStart = if isStatic: 1 else: 2
    if not isStatic:
      helperParams.add(newIdentDefs(recvName, recvType))
    for i in helperStart ..< formalParams.len:
      let p = formalParams[i]
      for j in 0 ..< p.len - 2:
        helperParams.add(newIdentDefs(p[j], p[^2]))
    newProc(
      name = postfix(userProcName, "*"),
      params = helperParams,
      body = newStmtList(bodyNode),
      pragmas = newTree(nnkPragma, ident("async")),
    )

  proc asyncPath(): NimNode =
    ## Emits the C-exported wrapper and registers the FFI-thread handler.
    let helperProc = buildAsyncHelperProc()

    # registerReqFFI lambda: typed params, returns user's typed Result.
    let ctxHandlerName = ident("ffiCtxHandler")
    let ptrFFICtx =
      nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libTypeName))

    var lambdaParams = newSeq[NimNode]()
    lambdaParams.add(retTypeNode)
    for i in 0 ..< extraParamNames.len:
      lambdaParams.add(newIdentDefs(ident(extraParamNames[i]), extraParamTypes[i]))

    let helperCall = newTree(nnkCall, userProcName)
    let bindsLib = not firstIsHandle and not isStatic
    if bindsLib:
      let ctxMyLib = newDotExpr(newTree(nnkDerefExpr, ctxHandlerName), ident("myLib"))
      helperCall.add(newTree(nnkDerefExpr, ctxMyLib))
    for name in extraParamNames:
      helperCall.add(ident(name))

    let lambdaBody = newStmtList()
    if bindsLib:
      lambdaBody.add(buildLibReadyGuard(ctxHandlerName, libTypeName))
    let retValIdent = ident("retVal")
    lambdaBody.add quote do:
      let `retValIdent` = (await `helperCall`).valueOr:
        return err($error)
      return ok(`retValIdent`)

    let lambdaNode = newProc(
      name = newEmptyNode(),
      params = lambdaParams,
      body = lambdaBody,
      pragmas = newTree(nnkPragma, ident("async")),
    )

    let registerReq = quote:
      registerReqFFI(`reqTypeName`, `ctxHandlerName`: `ptrFFICtx`):
        `lambdaNode`

    # C-exported wrapper: (ctx, callback, userData, reqCbor, reqCborLen).
    let exportedParams = cExportedParams(ctxType, withCtx = not isStatic)

    let ffiBody = newStmtList()
    # Flattened: the guard's `let ctx` must be a sibling of the send to be in scope.
    let guard =
      if isStatic:
        buildStaticCtxGuard()
      else:
        buildCtxGuard()
    for stmt in guard:
      ffiBody.add(stmt)

    let reqPtrIdent = genSym(nskLet, "reqPtr")
    let reqNameLit = newLit($unwrapPostfix(reqTypeName))
    ffiBody.add quote do:
      let `reqPtrIdent` = FFIThreadRequest.initFromPtr(
        callback, userData, cstring(`reqNameLit`), reqCbor, int(reqCborLen)
      )
    ffiBody.add buildSendAndReply(reqPtrIdent)

    let ffiProc = buildCExportProc(exportedParams, ffiBody)

    ffiProcRegistry.add(procMeta)

    if abiFormat == ABIFormat.C:
      # The handler unpacks through the `_CWire` companions, which only exist once every `{.ffi.}` type has been seen, so it (with the wrapper + reply trampoline) is emitted at genBindings() time (flushCAbiDispatch). The Req type stays here for the companion to name. The CBOR `ffiProc`/`ffiNewReq` aren't emitted at all.
      let handlerParam = nnkExprColonExpr.newTree(ctxHandlerName, ptrFFICtx)
      let handler = newStmtList(
        buildProcessFFIRequestProc(reqTypeName, handlerParam, lambdaNode, ABIFormat.C),
        addNewRequestToRegistry(reqTypeName, handlerParam, resultRetType, ABIFormat.C),
      )
      registerCAbiProc(
        isStatic, cExportName, libTypeName, reqTypeName, extraParamNames,
        extraParamTypes, resultRetType, handler,
      )
      return newStmtList(helperProc, buildRequestType(reqTypeName, lambdaNode))

    return newStmtList(helperProc, registerReq, ffiProc)

  proc scalarPath(): NimNode =
    ## Scalar fast path lives in `ffi_scalar`; here we only build the shared
    ## dispatch pieces and hand them over.
    let reqPtrIdent = genSym(nskLet, "reqPtr")
    buildScalarPath(
      helperProc = buildAsyncHelperProc(),
      ctxGuard = buildCtxGuard(),
      reqPtrIdent = reqPtrIdent,
      sendAndReply = buildSendAndReply(reqPtrIdent),
      userProcName = userProcName,
      cExportProcName = cExportProcName,
      cExportName = cExportName,
      ctxType = ctxType,
      camelName = camelName,
      extraParamNames = extraParamNames,
      extraParamTypes = extraParamTypes,
      procMeta = procMeta,
    )

  let stmts =
    if scalarEligible:
      scalarPath()
    else:
      asyncPath()

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

proc buildFFIDtorProc(prc: NimNode, abiFormat: ABIFormat): NimNode {.compileTime.}
proc buildFFIEventProc(prc: NimNode, leading: seq[NimNode]): NimNode {.compileTime.}

macro ffi*(args: varargs[untyped]): untyped =
  ## Simplified FFI macro for a type or a proc. A type registers for binding
  ## generation. For a proc, `routeFFIProc` reads the signature and picks the
  ## path: a context method, a static call, a synchronous export, a destructor,
  ## or an event. See `ffi/internal/ffi_route.nim` for the rules.
  requireBeforeGenBindings("`.ffi.`")
  # Annotated node is the last vararg; leading args are `"abi = ..."` specs.
  let prc = args[^1]
  let leading = args[0 ..^ 2]

  # A value type stands alone (no library required); its `c` companion is emitted later by `genBindings()`, since a type-pragma macro can only return a TypeDef.
  if prc.kind == nnkTypeDef:
    let typeABIFormat = resolveFFISpecs(leading)
    gateFFITypeABIFormat(typeABIFormat, "`.ffi.` type")
    var cleanTypeDef = prc.copyNimTree()
    if cleanTypeDef[0].kind == nnkPragmaExpr:
      cleanTypeDef[0] = cleanTypeDef[0][0]
    return registerFFITypeInfo(cleanTypeDef, typeABIFormat)

  if prc.kind notin {nnkProcDef, nnkFuncDef}:
    error("`.ffi.` must be applied to a type or a proc definition")
  requireLibraryDeclared("`.ffi.`")

  proc gatedABIFormat(what: string): ABIFormat =
    let abiFormat = resolveFFISpecs(leading)
    gateABIFormat(abiFormat, what)
    return abiFormat

  case routeFFIProc(prc)
  of fpEvent:
    # An event may lead with a wire-name literal, which the ABI parser rejects,
    # so it resolves its own specs.
    return buildFFIEventProc(prc, leading)
  of fpExport:
    # The export crosses the ABI with its own return value, so no ABI applies.
    if leading.len > 0:
      error(
        "`.ffi.` proc " & $procIdent(prc) &
          " is a synchronous export and takes no `abi = ...` spec"
      )
    return buildFFIExportProc(prc)
  of fpDtor:
    return buildFFIDtorProc(prc, gatedABIFormat("`.ffi.` destructor"))
  of fpStatic:
    return buildFFIProc(prc, gatedABIFormat("`.ffi.` static proc"), isStatic = true)
  of fpMethod:
    return buildFFIProc(prc, resolveFFISpecs(leading), isStatic = false)

macro ffiStatic*(args: varargs[untyped]): untyped =
  ## Context-independent `{.ffi.}`: no library receiver, and no `ctx` in the C
  ## wrapper, so a host calls it without constructing the library. `{.ffi.}`
  ## reaches the same path from the shape alone.
  requireBeforeGenBindings("`.ffiStatic.`")
  requireLibraryDeclared("`.ffiStatic.`")
  let prc = args[^1]
  let abiFormat = resolveFFISpecs(args[0 ..^ 2])
  gateABIFormat(abiFormat, "`.ffiStatic.` proc")
  if prc.kind notin {nnkProcDef, nnkFuncDef}:
    error("`.ffiStatic.` must be applied to a proc definition")
  assertFFIPath(prc, fpStatic)
  return buildFFIProc(prc, abiFormat, isStatic = true)

proc buildCtorRequestType(
    reqTypeName: NimNode, paramNames: seq[string], paramTypes: seq[NimNode]
): NimNode =
  ## Builds the ctor's Req object using the user's actual Nim types.
  var fields: seq[NimNode] = @[]
  for i in 0 ..< paramNames.len:
    let fieldName = ident(paramNames[i])
    let storedType = storageType(paramTypes[i])
    fields.add newTree(nnkIdentDefs, fieldName, storedType, newEmptyNode())

  let recList =
    if fields.len > 0:
      newTree(nnkRecList, fields)
    else:
      newTree(
        nnkRecList,
        newTree(nnkIdentDefs, ident("_placeholder"), ident("uint8"), newEmptyNode()),
      )

  let objTy = newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), recList)
  let typeName = postfix(reqTypeName, "*")
  let typeSection =
    newNimNode(nnkTypeSection).add(newTree(nnkTypeDef, typeName, newEmptyNode(), objTy))

  when defined(ffiDumpMacros):
    echo typeSection.repr
  return typeSection

proc buildCtorFFINewReqProc(reqTypeName: NimNode, paramNames: seq[string]): NimNode =
  ## Wraps a CBOR byte buffer into an FFIThreadRequest for the ctor request type.

  var formalParams = newSeq[NimNode]()

  let typedescParam =
    newIdentDefs(ident("T"), nnkBracketExpr.newTree(ident("typedesc"), reqTypeName))
  formalParams.add(typedescParam)
  formalParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  formalParams.add(newIdentDefs(ident("userData"), ident("pointer")))
  formalParams.add(newIdentDefs(ident("reqCbor"), nnkPtrTy.newTree(ident("byte"))))
  formalParams.add(newIdentDefs(ident("reqCborLen"), ident("csize_t")))

  let retType = newTree(nnkPtrTy, ident("FFIThreadRequest"))
  formalParams = @[retType] & formalParams

  let reqNameLit = newLit($unwrapPostfix(reqTypeName))
  var newBody = newStmtList()
  newBody.add quote do:
    return FFIThreadRequest.initFromPtr(
      callback, userData, cstring(`reqNameLit`), reqCbor, int(reqCborLen)
    )

  let newReqProc = newProc(
    name = postfix(ident("ffiNewReq"), "*"),
    params = formalParams,
    body = newBody,
    pragmas = newEmptyNode(),
  )

  when defined(ffiDumpMacros):
    echo newReqProc.repr
  return newReqProc

proc buildCtorBodyProc(
    helperName: NimNode,
    paramNames: seq[string],
    paramTypes: seq[NimNode],
    libTypeName: NimNode,
    userBody: NimNode,
): NimNode =
  let innerRetType = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(ident("Result"), libTypeName, ident("string")),
  )
  var innerParams = newSeq[NimNode]()
  innerParams.add(innerRetType)
  for i in 0 ..< paramNames.len:
    innerParams.add(newIdentDefs(ident(paramNames[i]), paramTypes[i]))

  let bodyProc = newProc(
    name = postfix(helperName, "*"),
    params = innerParams,
    body = newStmtList(userBody),
    pragmas = newTree(nnkPragma, ident("async")),
  )

  when defined(ffiDumpMacros):
    echo bodyProc.repr
  return bodyProc

proc buildCtorProcessFFIRequestProc(
    reqTypeName: NimNode,
    helperName: NimNode,
    paramNames: seq[string],
    paramTypes: seq[NimNode],
    libTypeName: NimNode,
    abi: ABIFormat,
): NimNode =
  ## Materialises the Req, runs the user body, stores the library value in ctx.myLib.
  let returnType = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(ident("Result"), ident("string"), ident("string")),
  )

  let ctxType =
    nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libTypeName))

  let typedescParam =
    newIdentDefs(ident("T"), nnkBracketExpr.newTree(ident("typedesc"), reqTypeName))

  var formalParams: seq[NimNode] = @[]
  formalParams.add(returnType)
  formalParams.add(typedescParam)
  formalParams.add(newIdentDefs(ident("request"), ident("pointer")))
  formalParams.add(newIdentDefs(ident("ctx"), ctxType))

  let newBody = newStmtList()
  let reqIdent = ident("req")
  let ctxIdent = ident("ctx")
  let decodedIdent = ident("decoded")

  newBody.add reqDecodePreamble(reqTypeName, reqIdent, decodedIdent, abi)

  for i in 0 ..< paramNames.len:
    newBody.add unpackReqField(ident(paramNames[i]), paramTypes[i], decodedIdent)

  let helperCallNode = newTree(nnkCall, helperName)
  for name in paramNames:
    helperCallNode.add(ident(name))

  let libValIdent = ident("libVal")
  newBody.add quote do:
    let `libValIdent` = (await `helperCallNode`).valueOr:
      return err($error)

  let myLibIdent = newDotExpr(newTree(nnkDerefExpr, ctxIdent), ident("myLib"))
  let myLibOwnedIdent = newDotExpr(newTree(nnkDerefExpr, ctxIdent), ident("myLibOwned"))
  let myLibRefdIdent = newDotExpr(newTree(nnkDerefExpr, ctxIdent), ident("myLibRefd"))
  let libReadyIdent = newDotExpr(newTree(nnkDerefExpr, ctxIdent), ident("libReady"))
  newBody.add quote do:
    `myLibIdent` = createShared(`libTypeName`)
    `myLibIdent`[] = `libValIdent`
    `myLibOwnedIdent` = true
    # Root the ref lib under refc: it lives only via this ptr in non-GC
    # createShared memory, invisible to the cycle collector. freeLib unroots it.
    when defined(gcRefc):
      when `libTypeName` is ref:
        GC_ref(`myLibIdent`[])
        `myLibRefdIdent` = true
    # Set the flag after the store, so an observer never sees the fallback.
    `libReadyIdent`.store(true)

  newBody.add quote do:
    return ok($cast[uint](`ctxIdent`))

  let processProc = newProc(
    name = postfix(ident("processFFIRequest"), "*"),
    params = formalParams,
    body = newBody,
    procType = nnkProcDef,
    pragmas = newTree(nnkPragma, ident("async")),
  )

  when defined(ffiDumpMacros):
    echo processProc.repr
  return processProc

proc addCtorRequestToRegistry(
    reqTypeName, libTypeName: NimNode, abi: ABIFormat
): NimNode =
  ## Wraps the ctor processFFIRequest result in a seq[byte] dispatcher; the ctor
  ## returns the ctx address as a decimal string — raw UTF-8 under `abi = c`,
  ## CBOR-encoded otherwise.
  let ctxType =
    nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libTypeName))

  let returnType = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(
      ident("Result"),
      nnkBracketExpr.newTree(ident("seq"), ident("byte")),
      ident("string"),
    ),
  )

  let callExpr = newCall(
    newDotExpr(reqTypeName, ident("processFFIRequest")),
    ident("request"),
    newTree(nnkCast, ctxType, ident("reqHandler")),
  )

  let resIdent = genSym(nskLet, "ctorRes")
  let encodeRet =
    if abi == ABIFormat.C:
      quote:
        return ok(ffiRawRetBytes(`resIdent`.value))
    else:
      quote:
        return ok(cborEncode(`resIdent`.value))

  var newBody = newStmtList()
  newBody.add quote do:
    let `resIdent` = await `callExpr`
    if `resIdent`.isErr:
      return err(`resIdent`.error)

  newBody.add encodeRet

  let asyncProc = newProc(
    name = newEmptyNode(),
    params = @[
      returnType,
      newIdentDefs(ident("request"), ident("pointer")),
      newIdentDefs(ident("reqHandler"), ident("pointer")),
    ],
    body = newBody,
    pragmas = nnkPragma.newTree(ident("async")),
  )

  let key = newLit($reqTypeName)
  let regAssign =
    newAssignment(newTree(nnkBracketExpr, ident("registeredRequests"), key), asyncProc)

  when defined(ffiDumpMacros):
    echo regAssign.repr
  return regAssign

macro ffiCtor*(args: varargs[untyped]): untyped =
  ## C-exported constructor: creates an FFIContext and fills ctx.myLib async on the
  ## FFI thread. Takes Nim params (one CBOR blob), no ctx/callback/userData. Wrapper
  ## returns the ctx pointer sync (NULL on failure); callback fires with its address.
  requireBeforeGenBindings("`.ffiCtor.`")
  requireLibraryDeclared("`.ffiCtor.`")
  let prc = args[^1]
  let abiFormat = resolveFFISpecs(args[0 ..^ 2])
  gateABIFormat(abiFormat, "`.ffiCtor.` proc")

  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  let retTypeNode = formalParams[0]
  if retTypeNode.kind == nnkEmpty:
    error(
      "ffiCtor: proc must have an explicit return type Future[Result[LibType, string]]"
    )
  if retTypeNode.kind != nnkBracketExpr or $retTypeNode[0] != "Future":
    error(
      "ffiCtor: return type must be Future[Result[LibType, string]], got: " &
        retTypeNode.repr
    )
  let resultInner = retTypeNode[1]
  if resultInner.kind != nnkBracketExpr or $resultInner[0] != "Result":
    error(
      "ffiCtor: return type must be Future[Result[LibType, string]], got: " &
        retTypeNode.repr
    )
  let libTypeName = resultInner[1]

  var paramNames: seq[string] = @[]
  var paramTypes: seq[NimNode] = @[]
  for i in 1 ..< formalParams.len:
    let p = formalParams[i]
    for j in 0 ..< p.len - 2:
      rejectRawPtrType(p[^2], "`.ffiCtor.` proc " & $procName & " parameter " & $p[j])
      paramNames.add($p[j])
      paramTypes.add(p[^2])

  let procNameStr = $procName
  let cleanName =
    if procNameStr.endsWith("*"):
      procNameStr[0 ..^ 2]
    else:
      procNameStr
  let cExportName = camelToSnakeCase(cleanName)
  let reqTypeNameStr = snakeToPascalCase(cleanName) & "CtorReq"
  let reqTypeName = ident(reqTypeNameStr)

  let typeDef = buildCtorRequestType(reqTypeName, paramNames, paramTypes)
  let ffiNewReqProc = buildCtorFFINewReqProc(reqTypeName, paramNames)
  var userProcName = procName
  if procName.kind == nnkPostfix:
    userProcName = procName[1]
  # Nim ctor and C wrapper share the user's name as overloads; the wrapper's `{.exportc.}` keeps the ABI symbol.
  let cExportProcName = userProcName
  let helperProc =
    buildCtorBodyProc(userProcName, paramNames, paramTypes, libTypeName, bodyNode)
  let processProc = buildCtorProcessFFIRequestProc(
    reqTypeName, userProcName, paramNames, paramTypes, libTypeName, abiFormat
  )
  let addToReg = addCtorRequestToRegistry(reqTypeName, libTypeName, abiFormat)

  # C-exported proc: (reqCbor, reqCborLen, callback, userData) -> pointer
  var exportedParams = newSeq[NimNode]()
  exportedParams.add(ident("pointer"))
  exportedParams.add(newIdentDefs(ident("reqCbor"), nnkPtrTy.newTree(ident("byte"))))
  exportedParams.add(newIdentDefs(ident("reqCborLen"), ident("csize_t")))
  exportedParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  exportedParams.add(newIdentDefs(ident("userData"), ident("pointer")))

  let ffiBody = newStmtList()

  ffiBody.add quote do:
    when declared(initializeLibrary):
      initializeLibrary()

  let ctxSym = genSym(nskLet, "ctx")
  let poolIdent = ident($libTypeName & "FFIPool")

  ffiBody.add quote do:
    let `ctxSym` = `poolIdent`.createFFIContext().valueOr:
      if not callback.isNil:
        let errStr = "ffiCtor: failed to create FFIContext: " & $error
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
      return nil

  # Early validation: decode the CBOR payload to verify it parses cleanly.
  ffiBody.add quote do:
    block:
      let validateRes = cborDecodePtr(
        cast[ptr UncheckedArray[byte]](reqCbor), int(reqCborLen), `reqTypeName`
      )
      if validateRes.isErr():
        if not callback.isNil:
          let errStr = "ffiCtor: failed to decode request: " & $validateRes.error
          callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
        return nil

  let newReqCall = newCall(
    ident("ffiNewReq"),
    reqTypeName,
    ident("callback"),
    ident("userData"),
    ident("reqCbor"),
    ident("reqCborLen"),
  )

  let sendCall =
    newCall(newDotExpr(ctxSym, ident("sendRequestToFFIThread")), newReqCall)

  let sendResIdent = genSym(nskLet, "sendRes")
  ffiBody.add quote do:
    let `sendResIdent` =
      try:
        `sendCall`
      except Exception as exc:
        Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
    if `sendResIdent`.isErr():
      if not callback.isNil:
        let errStr = "ffiCtor: failed to send request: " & $`sendResIdent`.error
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
      return nil

  ffiBody.add quote do:
    return cast[pointer](`ctxSym`)

  let ffiProc = newProc(
    name = postfix(cExportProcName, "*"),
    params = exportedParams,
    body = ffiBody,
    pragmas = newTree(
      nnkPragma,
      ident("dynlib"),
      newTree(nnkExprColonExpr, ident("exportc"), newStrLitNode(cExportName)),
      ident("cdecl"),
      newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
    ),
  )

  block:
    var ctorExtraParams: seq[FFIParamMeta] = @[]
    for i in 0 ..< paramNames.len:
      let ptype = paramTypes[i]
      let isPointer = isPtr(ptype)
      let tn =
        if isPointer:
          nimTypeNameRepr(ptype[0])
        else:
          nimTypeNameRepr(ptype)
      ctorExtraParams.add(
        FFIParamMeta(name: paramNames[i], typeName: tn, isPtr: isPointer)
      )
    ffiProcRegistry.add(
      FFIProcMeta(
        procName: cExportName,
        libName: currentLibName,
        kind: FFIKind.CTOR,
        libTypeName: $libTypeName,
        extraParams: ctorExtraParams,
        returnTypeName: $libTypeName,
        returnIsPtr: false,
        abiFormat: abiFormat,
        doc: extractDocComment(prc),
      )
    )

  let poolDecl = quote:
    when not declared(`poolIdent`):
      var `poolIdent`: FFIContextPool[`libTypeName`]

  let stmts =
    if abiFormat == ABIFormat.C:
      # The `abi = c` handler + wrapper are emitted at genBindings() time (the handler unpacks through the `_CWire` companions); the CBOR `ffiProc`/`ffiNewReq` aren't emitted at all.
      registerCAbiCtor(
        cExportName,
        libTypeName,
        reqTypeName,
        paramNames,
        paramTypes,
        newStmtList(processProc, addToReg),
      )
      newStmtList(typeDef, helperProc, poolDecl)
    else:
      newStmtList(
        typeDef, ffiNewReqProc, helperProc, processProc, addToReg, poolDecl, ffiProc
      )

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

proc buildFFIDtorProc(prc: NimNode, abiFormat: ABIFormat): NimNode {.compileTime.} =
  ## Emits the C-exported FFIContext destructor. `{.ffi.}` and `{.ffiDtor.}`
  ## share it.
  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  if formalParams.len < 2:
    error("ffiDtor: proc must have exactly one parameter (w: LibType)")

  let libParamName = formalParams[1][0]
  let libTypeName = formalParams[1][1]

  # A dtor is sync (no return) or async (`Future[void]`); reject anything else.
  let retTypeNode = formalParams[0]
  let retIsFutureVoid =
    retTypeNode.kind == nnkBracketExpr and $retTypeNode[0] == "Future" and
    retTypeNode.len == 2 and $retTypeNode[1] == "void"
  if retTypeNode.kind != nnkEmpty and not retIsFutureVoid:
    error(
      "ffiDtor: proc must return nothing (sync) or Future[void] (async), got: " &
        retTypeNode.repr
    )

  let procNameStr = block:
    let raw = $procName
    if raw.endsWith("*"):
      raw[0 ..^ 2]
    else:
      raw
  let cExportName = camelToSnakeCase(procNameStr)
  # The dtor only emits a C wrapper and uses the user's name directly (no Nim-facing helper to overload against).
  var cExportProcName = procName
  if procName.kind == nnkPostfix:
    cExportProcName = procName[1]

  let destroyResIdent = genSym(nskLet, "destroyRes")

  let ffiBody = newStmtList()

  ffiBody.add quote do:
    when declared(initializeLibrary):
      initializeLibrary()

  ffiBody.add quote do:
    if ctx.isNil or cast[ptr FFIContext[`libTypeName`]](ctx)[].myLib.isNil:
      return RET_ERR

  let isNoop =
    bodyNode.kind == nnkEmpty or (
      bodyNode.kind == nnkStmtList and bodyNode.len == 1 and
      bodyNode[0].kind == nnkDiscardStmt
    )

  # Lift the body into an async `ffiTeardownHook` the FFI thread awaits at shutdown; the C wrapper no longer runs the body.
  let teardownImplName = genSym(nskProc, "ffiTeardownImpl")
  let teardownRegistration =
    if isNoop:
      newEmptyNode()
    else:
      quote:
        proc `teardownImplName`(lib: ptr `libTypeName`): Future[void] {.async.} =
          let `libParamName` = lib[]
          `bodyNode`

        ffiTeardownHook[`libTypeName`]() = `teardownImplName`

  let poolIdent = ident($libTypeName & "FFIPool")
  ffiBody.add quote do:
    let `destroyResIdent` =
      `poolIdent`.recycleFFIContext(cast[ptr FFIContext[`libTypeName`]](ctx))
    if `destroyResIdent`.isErr():
      return RET_ERR

  ffiBody.add quote do:
    return RET_OK

  let ffiProc = newProc(
    name = postfix(cExportProcName, "*"),
    params = @[ident("cint"), newIdentDefs(ident("ctx"), ident("pointer"))],
    body = ffiBody,
    pragmas = newTree(
      nnkPragma,
      ident("dynlib"),
      newTree(nnkExprColonExpr, ident("exportc"), newStrLitNode(cExportName)),
      ident("cdecl"),
      newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
    ),
  )

  ffiProcRegistry.add(
    FFIProcMeta(
      procName: cExportName,
      libName: currentLibName,
      kind: FFIKind.DTOR,
      libTypeName: $libTypeName,
      extraParams: @[],
      returnTypeName: "",
      returnIsPtr: false,
      abiFormat: abiFormat,
      doc: extractDocComment(prc),
    )
  )

  let poolDecl = quote:
    when not declared(`poolIdent`):
      var `poolIdent`: FFIContextPool[`libTypeName`]

  let stmts = newStmtList(teardownRegistration, poolDecl, ffiProc)

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

macro ffiDtor*(args: varargs[untyped]): untyped =
  ## C-exported FFIContext destructor. Sync (no return) or async (`Future[void]`);
  ## a non-empty body becomes an async `ffiTeardownHook` the FFI thread awaits at
  ## shutdown, so teardown runs on the worker thread. RET_ERR on null/invalid ctx.
  ## `{.ffi.}` reaches the same path from the shape alone.
  requireBeforeGenBindings("`.ffiDtor.`")
  requireLibraryDeclared("`.ffiDtor.`")
  let prc = args[^1]
  let abiFormat = resolveABIFormat(args[0 ..^ 2])
  gateABIFormat(abiFormat, "`.ffiDtor.` proc")
  assertFFIPath(prc, fpDtor)
  return buildFFIDtorProc(prc, abiFormat)

proc buildFFIEventProc(prc: NimNode, leading: seq[NimNode]): NimNode {.compileTime.} =
  ## Emits the event dispatcher. `{.ffi.}` and `{.ffiEvent.}` share it.
  ## One parameter rides the wire directly (a scalar, or an existing `{.ffi.}`
  ## object). Two or more are bundled into a synthesised, registered envelope
  ## object named `<WireNamePascalCase>Payload` whose fields are the parameters,
  ## so the foreign side still decodes one typed value.
  let procName = prc[0]
  var userProcName = procName
  if procName.kind == nnkPostfix:
    userProcName = procName[1]

  let (wireName, abiSpecStart) = resolveEventWireName(leading, userProcName)
  let abiFormat = resolveABIFormat(leading[abiSpecStart ..^ 1])
  gateABIFormat(abiFormat, "`.ffiEvent.` proc")
  if abiFormat == ABIFormat.C:
    error(
      "`.ffiEvent.` proc: the `c` ABI does not yet support events; declare the " &
        "event with `abi = cbor` (events still ride CBOR internally)"
    )

  let formalParams = prc[3]

  if formalParams.len < 2:
    error("ffiEvent requires at least one parameter")

  # Flatten the parameter list (a grouped `a, b: T` expands to one entry each).
  var paramNames: seq[NimNode] = @[]
  var paramTypes: seq[NimNode] = @[]
  for i in 1 ..< formalParams.len:
    let p = formalParams[i]
    for j in 0 ..< p.len - 2:
      rejectRawPtrType(
        p[^2], "`.ffiEvent.` proc " & $userProcName & " parameter " & $p[j]
      )
      paramNames.add(p[j])
      paramTypes.add(p[^2])

  let wireNameLit = newStrLitNode(wireName)
  let resultStmts = newStmtList()

  var payloadTypeNameStr: string
  var dispatchPayload: NimNode

  if paramNames.len == 1:
    let payloadTypeNode = paramTypes[0]
    payloadTypeNameStr =
      if payloadTypeNode.kind == nnkIdent:
        $payloadTypeNode
      else:
        payloadTypeNode.repr
    dispatchPayload = paramNames[0]
  else:
    # Synthesise + register an envelope object, then dispatch an instance built
    # from the parameters.
    let payloadType = ident(snakeToPascalCase(wireName) & "Payload")
    payloadTypeNameStr = $payloadType

    var paramNameStrs: seq[string] = @[]
    for n in paramNames:
      paramNameStrs.add($n)
    let typeSection = buildCtorRequestType(payloadType, paramNameStrs, paramTypes)
    discard registerFFITypeInfo(typeSection[0], abiFormat)
    resultStmts.add(typeSection)

    let envelope = nnkObjConstr.newTree(payloadType)
    for i in 0 ..< paramNames.len:
      # `cstring` rides as `string` in the envelope (per storageType).
      let value =
        if paramTypes[i].kind == nnkIdent and $paramTypes[i] == "cstring":
          newCall(ident("$"), paramNames[i])
        else:
          paramNames[i]
      envelope.add(nnkExprColonExpr.newTree(paramNames[i], value))
    dispatchPayload = envelope

  let dispatchBody =
    newStmtList(newCall(ident("dispatchFFIEventCbor"), wireNameLit, dispatchPayload))

  var newParams = newSeq[NimNode]()
  newParams.add(formalParams[0])
  for i in 1 ..< formalParams.len:
    newParams.add(formalParams[i])

  let pragmas =
    if prc.len >= 5 and prc[4].kind != nnkEmpty:
      prc[4]
    else:
      newEmptyNode()

  let generated = newProc(
    name = procName,
    params = newParams,
    body = dispatchBody,
    procType = prc.kind,
    pragmas = pragmas,
  )
  resultStmts.add(generated)

  ffiEventRegistry.add(
    FFIEventMeta(
      wireName: wireName,
      nimProcName: $userProcName,
      libName: currentLibName,
      payloadTypeName: payloadTypeNameStr,
      abiFormat: abiFormat,
      doc: extractDocComment(prc),
    )
  )

  when defined(ffiDumpMacros):
    echo resultStmts.repr
  return resultStmts

macro ffiEvent*(args: varargs[untyped]): untyped =
  ## Declares a library-initiated event: the empty-bodied proc is filled with a
  ## `dispatchFFIEventCbor` call. Wire name defaults to `camelToSnakeCase` of the
  ## proc name (a string literal overrides it) and is the cross-binding source of truth.
  ## `{.ffi.}` reaches the same path from the shape alone.
  requireBeforeGenBindings("`.ffiEvent.`")
  requireLibraryDeclared("`.ffiEvent.`")
  if args.len < 1:
    error("ffiEvent must be applied to a proc declaration")

  let prc = args[^1]
  if prc.kind notin {nnkProcDef, nnkFuncDef}:
    error("ffiEvent must be applied to a proc declaration")
  assertFFIPath(prc, fpEvent)
  return buildFFIEventProc(prc, args[0 ..^ 2])

proc reportScalarFastPathDrops(procs: seq[FFIProcMeta]) {.compileTime.} =
  ## Fail loudly on scalar-fast-path procs a target can't bind, unless
  ## `-d:ffiAllowScalarSkip` downgrades it to a hint.
  var skipped: seq[string] = @[]
  for p in procs:
    if p.scalarFastPath:
      skipped.add(p.procName)
  if skipped.len == 0:
    return
  if ffiAllowScalarSkip:
    for name in skipped:
      hint(
        "genBindings: omitting scalar-fast-path proc '" & name &
          "' from the bindings (-d:ffiAllowScalarSkip)"
      )
    return
  error(
    """genBindings: this target has no foreign-binding codegen for scalar-fast-path
`abi = c` procs, so these would be silently omitted from the generated bindings:
$1
They are emitted only into the `abi = c` C header (an `abi = c` library generated
with -d:targetLang=c).
Fix by one of:
  - make the library `abi = c` (declareLibrary(..., "c")) and generate C bindings, or
  - switch the proc to `abi = cbor`, or
  - add a non-scalar param (e.g. a struct or handle) so it takes the CBOR wire shape, or
  - pass -d:ffiAllowScalarSkip to accept the omission.""" %
      [skipped.join(", ")]
  )

proc bindingsOutputDir(lang, explicit: string): string {.compileTime.} =
  ## Output dir for `lang`; defaults to `<lang>_bindings/` next to the compiled
  ## source, or an explicit -d:ffiOutputDir override.
  if explicit.len > 0:
    explicit
  else:
    return querySetting(SingleValueSetting.projectPath) / (lang & "_bindings")

proc bindingsSrcPath(outDir, explicit: string): string {.compileTime.} =
  ## Nim source path embedded in build files, relative to `outDir`; defaults to
  ## the compiled file, or an explicit -d:ffiSrcPath override.
  if explicit.len > 0:
    explicit
  else:
    relativePath(querySetting(SingleValueSetting.projectFull), outDir)

when defined(ffiGenBindings):
  proc emitBindingsFor(
      lang: string, genProcs: seq[FFIProcMeta], libName, outDir, srcRel: string
  ) {.compileTime.} =
    ## Route one language token to its generator; unknown tokens error.
    case lang
    of "rust":
      generateRustCrate(
        genProcs, ffiTypeRegistry, libName, outDir, srcRel, ffiEventRegistry,
        ffiConstRegistry,
      )
    of "cpp", "c++":
      generateCppBindings(
        genProcs, ffiTypeRegistry, libName, outDir, srcRel, ffiEventRegistry,
        ffiConstRegistry,
      )
    of "c":
      generateCBindings(
        genProcs, ffiTypeRegistry, libName, outDir, srcRel, ffiEventRegistry,
        ffiConstRegistry,
      )
    of "cddl":
      generateCddlBindings(genProcs, ffiTypeRegistry, libName, outDir, srcRel)
    else:
      error(
        "genBindings: unknown targetLang '" & lang &
          "'. Use 'rust', 'cpp', 'c', or 'cddl'."
      )

macro genBindings*(
    outputDir: static[string] = ffiOutputDir, nimSrcRelPath: static[string] = ffiSrcPath
): untyped =
  ## Emits binding files from the compile-time FFI registries. MUST be called AFTER
  ## every {.ffi.}/{.ffiCtor.}/{.ffiDtor.} annotation, so place it at the compilation
  ## root's bottom. -d:targetLang picks languages; emission needs -d:ffiGenBindings.
  genBindingsEmitted = true

  when defined(ffiGenBindings):
    let libName = deriveLibName(ffiProcRegistry)
    for rawLang in targetLang.split(','):
      let lang = string_helpers.toLower(rawLang.strip())
      if lang.len == 0:
        continue
      # The `abi = c` C header is the only output with scalar-fast-path codegen.
      let emitsScalars = lang == "c" and currentDefaultABIFormat == ABIFormat.C
      let genProcs =
        if emitsScalars:
          ffiProcRegistry
        else:
          bindableProcs(ffiProcRegistry)
      if not emitsScalars:
        reportScalarFastPathDrops(ffiProcRegistry)
      let outDir = bindingsOutputDir(lang, outputDir)
      emitBindingsFor(
        lang, genProcs, libName, outDir, bindingsSrcPath(outDir, nimSrcRelPath)
      )

  let emitted = flushCWireCompanions()
  for node in flushCAbiDispatch():
    emitted.add(node)
  when defined(ffiDumpMacros):
    echo emitted.repr
  emitted

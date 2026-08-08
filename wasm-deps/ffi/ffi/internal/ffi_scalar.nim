## CBOR-free scalar fast path for all-scalar `{.ffi: "abi = c".}` methods.

import std/macros
import ../codegen/meta
import ./ffi_codegen_common

const scalarPodTypeNames = [
  "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32",
  "uint64", "byte", "float", "float32", "float64", "bool",
]
  ## Fixed-width POD scalars that survive the async hop by value; `cstring`/
  ## `string` are excluded as params (they alias caller memory read after return).

func isScalarParamTypeName*(name: string): bool =
  name in scalarPodTypeNames

func isScalarReturnTypeName*(name: string): bool =
  ## Unlike params, a `string`/`cstring` return is fine: the bytes ride back raw.
  name in scalarPodTypeNames or name == "string" or name == "cstring"

func isScalarOnly*(p: FFIProcMeta): bool =
  ## True iff every wire param and return of `p` is scalar. Handles and raw
  ## pointers are excluded.
  if p.kind != FFIKind.FFI:
    return false
  if p.returnIsPtr or p.returnIsHandle:
    return false
  if not isScalarReturnTypeName(p.returnTypeName):
    return false
  for ep in p.extraParams:
    if ep.isPtr or ep.isHandle or not isScalarParamTypeName(ep.typeName):
      return false
  true

func bindableProcs*(procs: seq[FFIProcMeta]): seq[FFIProcMeta] =
  ## Procs the CBOR-speaking generators emit for; scalar-fast-path procs are
  ## dropped (their inline-scalar export doesn't match the CBOR codegen shape).
  ## The `abi = c` C header binds the full registry instead.
  var kept: seq[FFIProcMeta] = @[]
  for p in procs:
    if not p.scalarFastPath:
      kept.add(p)
  kept

proc buildScalarPath*(
    helperProc, ctxGuard, reqPtrIdent, sendAndReply: NimNode,
    userProcName, cExportProcName: NimNode,
    cExportName: string,
    ctxType: NimNode,
    camelName: string,
    extraParamNames: seq[string],
    extraParamTypes: seq[NimNode],
    procMeta: FFIProcMeta,
): NimNode {.compileTime.} =
  ## Emits the scalar-fast-path codegen for one `.ffi.` proc; the caller supplies
  ## the generic dispatch pieces, this owns the inline pack/unpack/raw-bytes wiring.
  let scalarReqKey = camelName & "Req"

  let reqIdent = genSym(nskLet, "ffiReq")
  let ctxHandlerName = genSym(nskLet, "ffiCtxHandler")
  let handlerBody = newStmtList()
  handlerBody.add quote do:
    let `reqIdent` = cast[ptr FFIThreadRequest](request)
    let `ctxHandlerName` = cast[`ctxType`](reqHandler)

  # ctxType is `ptr FFIContext[LibType]`; the guard needs the library type.
  handlerBody.add(buildLibReadyGuard(ctxHandlerName, ctxType[0][1]))

  let helperCall = newTree(nnkCall, userProcName)
  let ctxMyLib = newDotExpr(newTree(nnkDerefExpr, ctxHandlerName), ident("myLib"))
  helperCall.add(newTree(nnkDerefExpr, ctxMyLib))
  for i in 0 ..< extraParamNames.len:
    let argIdent = ident(extraParamNames[i])
    let slot = nnkBracketExpr.newTree(
      newDotExpr(newTree(nnkDerefExpr, reqIdent), ident("scalarArgs")), newLit(i)
    )
    handlerBody.add(
      newLetStmt(argIdent, newCall(ident("ffiUnpackScalar"), slot, extraParamTypes[i]))
    )
    helperCall.add(argIdent)

  let retValIdent = genSym(nskLet, "retVal")
  handlerBody.add quote do:
    let `retValIdent` = (await `helperCall`).valueOr:
      return err(error)
    return ok(ffiRawRetBytes(`retValIdent`))

  let seqByteResult = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(
      ident("Result"),
      nnkBracketExpr.newTree(ident("seq"), ident("byte")),
      ident("string"),
    ),
  )
  let handlerProc = newProc(
    name = newEmptyNode(),
    params = @[
      seqByteResult,
      newIdentDefs(ident("request"), ident("pointer")),
      newIdentDefs(ident("reqHandler"), ident("pointer")),
    ],
    body = handlerBody,
    pragmas = nnkPragma.newTree(ident("async")),
  )
  let registerAssign = newAssignment(
    nnkBracketExpr.newTree(ident("registeredRequests"), newLit(scalarReqKey)),
    handlerProc,
  )

  var scalarParams = @[
    ident("cint"),
    newIdentDefs(ident("ctx"), ctxType),
    newIdentDefs(ident("callback"), ident("FFICallBack")),
    newIdentDefs(ident("userData"), ident("pointer")),
  ]
  for i in 0 ..< extraParamNames.len:
    scalarParams.add(newIdentDefs(ident(extraParamNames[i]), extraParamTypes[i]))

  let ffiBody = newStmtList()
  ffiBody.add ctxGuard

  let initScalarCall = newTree(
    nnkCall,
    newDotExpr(ident("FFIThreadRequest"), ident("initScalar")),
    ident("callback"),
    ident("userData"),
    newDotExpr(newLit(scalarReqKey), ident("cstring")),
  )
  for i in 0 ..< extraParamNames.len:
    initScalarCall.add(newCall(ident("ffiPackScalar"), ident(extraParamNames[i])))

  ffiBody.add newLetStmt(reqPtrIdent, initScalarCall)
  ffiBody.add sendAndReply

  let ffiProc = newProc(
    name = postfix(cExportProcName, "*"),
    params = scalarParams,
    body = ffiBody,
    pragmas = newTree(
      nnkPragma,
      ident("dynlib"),
      newTree(nnkExprColonExpr, ident("exportc"), newStrLitNode(cExportName)),
      ident("cdecl"),
      newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
    ),
  )

  # Registered so metadata stays introspectable; `bindableProcs` drops it later.
  var scalarMeta = procMeta
  scalarMeta.scalarFastPath = true
  ffiProcRegistry.add(scalarMeta)

  newStmtList(helperProc, registerAssign, ffiProc)

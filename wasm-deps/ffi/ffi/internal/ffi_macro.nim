import std/[macros, tables]
import chronos
import ../ffi_types

proc extractFieldsFromLambda(body: NimNode): seq[NimNode] =
  ## Extracts the fields (params) from the given lambda body, when using the registerReqFFI macro.
  ## e.g., for:
  ##   registerReqFFI(CreateNodeRequest, ctx: ptr FFIContext[Waku]):
  ##     proc(
  ##         configJson: cstring, appCallbacks: AppCallbacks
  ##     ): Future[Result[string, string]] {.async.} =
  ##       ...
  ## The extracted fields will be:
  ##   - configJson: cstring
  ##   - appCallbacks: AppCallbacks
  ## 

  var procNode = body
  if procNode.kind == nnkStmtList and procNode.len == 1:
    procNode = procNode[0]
  if procNode.kind != nnkLambda and procNode.kind != nnkProcDef:
    error "registerReqFFI expects a lambda proc, found: " & $procNode.kind

  let params = procNode[3] # parameters list
  result = @[]
  for p in params[1 .. ^1]: # skip return type
    result.add newIdentDefs(p[0], p[1])

  when defined(ffiDumpMacros):
    echo result.repr

proc buildRequestType(reqTypeName: NimNode, body: NimNode): NimNode =
  ## Builds:
  ## type <reqTypeName>* = object
  ##   <lambdaParam1Name>: <lambdaParam1Type>
  ##   ...
  ## e.g.:
  ## type CreateNodeRequest* = object
  ##     configJson: cstring
  ##     appCallbacks: AppCallbacks
  ## 

  var procNode = body
  if procNode.kind == nnkStmtList and procNode.len == 1:
    procNode = procNode[0]
  if procNode.kind != nnkLambda and procNode.kind != nnkProcDef:
    error "registerReqFFI expects a lambda proc, found: " & $procNode.kind

  let params = procNode[3] # formal params of the lambda
  var fields: seq[NimNode] = @[]
  for p in params[1 .. ^1]: # skip return type at index 0
    let name = p[0]
    let typ = p[1]
    # Field must be nnkIdentDefs(name, type, defaultExpr)
    fields.add newTree(nnkIdentDefs, name, typ, newEmptyNode())

  # Wrap fields in a rec list
  let recList = newTree(nnkRecList, fields)

  # object type node: object [of?] [] [pragma?] recList
  let objTy = newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), recList)

  # Export the type (CreateNodeRequest*)
  let typeName =
    if reqTypeName.kind == nnkPostfix:
      reqTypeName
    else:
      postfix(reqTypeName, "*")

  result =
    newNimNode(nnkTypeSection).add(newTree(nnkTypeDef, typeName, newEmptyNode(), objTy))

  when defined(ffiDumpMacros):
    echo result.repr

proc buildFfiNewReqProc(reqTypeName, body: NimNode): NimNode =
  ## Builds the ffiNewProc in charge of creating the FFIThreadRequest in shared memory.
  ## Then, a pointer to this request will be sent to the FFI thread for processing.
  ## e.g.:
  ## proc ffiNewReq*(T: typedesc[CreateNodeRequest]; callback: FFICallBack;
  ##                 userData: pointer; configJson: cstring;
  ##                 appCallbacks: AppCallbacks): ptr FFIThreadRequest =
  ##   var reqObj = createShared(T)
  ##   reqObj[].configJson = configJson.alloc()
  ##   reqObj[].appCallbacks = appCallbacks
  ##   let typeStr`gensym2866 = $T
  ##   var ret`gensym2866 = FFIThreadRequest.init(callback, userData,
  ##       typeStr`gensym2866.cstring, reqObj)
  ##   return ret`gensym2866
  ## 
  ## This should be invoked by the ffi consumer thread (generally, main thread.)
  ## Notice that the shared memory allocated by the main thread is freed by the FFI thread
  ## after processing the request.

  var formalParams = newSeq[NimNode]()

  var procNode: NimNode
  if body.kind == nnkStmtList and body.len == 1:
    procNode = body[0] # unwrap single statement
  else:
    procNode = body

  if procNode.kind != nnkLambda and procNode.kind != nnkProcDef:
    error "registerReqFFI expects a lambda definition. Found: " & $procNode.kind

  # T: typedesc[CreateNodeRequest]
  let typedescParam = newIdentDefs(
    ident("T"), # param name
    nnkBracketExpr.newTree(ident("typedesc"), reqTypeName), # typedesc[T]
  )
  formalParams.add(typedescParam)

  # Other fixed FFI params
  formalParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  formalParams.add(newIdentDefs(ident("userData"), ident("pointer")))

  # Add original lambda params
  let procParams = procNode[3]
  for p in procParams[1 .. ^1]:
    formalParams.add(p)

  # Build `ptr FFIThreadRequest`
  let retType = newNimNode(nnkPtrTy)
  retType.add(ident("FFIThreadRequest"))

  formalParams = @[retType] & formalParams

  # Build body
  let reqObjIdent = ident("reqObj")
  var newBody = newStmtList()
  newBody.add(
    quote do:
      var `reqObjIdent` = createShared(T)
  )

  for p in procParams[1 .. ^1]:
    let fieldNameIdent = ident($p[0])
    let fieldTypeNode = p[1]

    # Extract type name as string
    var typeStr: string
    if fieldTypeNode.kind == nnkIdent:
      typeStr = $fieldTypeNode
    elif fieldTypeNode.kind == nnkBracketExpr:
      typeStr = $fieldTypeNode[0] # e.g., `ptr` in `ptr[Waku]`
    else:
      typeStr = "" # fallback

    # Apply .alloc() only to cstrings
    if typeStr == "cstring":
      newBody.add(
        quote do:
          `reqObjIdent`[].`fieldNameIdent` = `fieldNameIdent`.alloc()
      )
    else:
      newBody.add(
        quote do:
          `reqObjIdent`[].`fieldNameIdent` = `fieldNameIdent`
      )

  # FFIThreadRequest.init using fnv1aHash32
  newBody.add(
    quote do:
      let typeStr = $T
      var ret =
        FFIThreadRequest.init(callback, userData, typeStr.cstring, `reqObjIdent`)
      return ret
  )

  # Build the proc node
  result = newProc(
    name = postfix(ident("ffiNewReq"), "*"),
    params = formalParams,
    body = newBody,
    pragmas = newEmptyNode(),
  )

  when defined(ffiDumpMacros):
    echo result.repr

proc buildFfiDeleteReqProc(reqTypeName: NimNode, fields: seq[NimNode]): NimNode =
  ## Generates:
  ## proc ffiDeleteReq(self: ptr <reqTypeName>) =
  ##   deallocShared(self[].<cstringField>)
  ##   deallocShared(self)

  # Build the body
  var body = newStmtList()
  for f in fields:
    if $f[1] == "cstring": # only dealloc cstring fields
      body.add newCall(
        ident("deallocShared"),
        newDotExpr(newTree(nnkDerefExpr, ident("self")), ident($f[0])),
      )

  # Always free the whole object at the end
  body.add newCall(ident("deallocShared"), ident("self"))

  # Build the parameter: (self: ptr <reqTypeName>)
  let selfParam = newIdentDefs(ident("self"), newTree(nnkPtrTy, reqTypeName))

  # Build the proc definition
  result = newProc(
    name = postfix(ident("ffiDeleteReq"), "*"),
    params = @[newEmptyNode()] & @[selfParam], # ✅ properly wrapped in a sequence
    body = body,
  )

  when defined(ffiDumpMacros):
    echo result.repr

proc buildProcessFFIRequestProc(reqTypeName, reqHandler, body: NimNode): NimNode =
  ## Builds, f.e.:
  ## proc processFFIRequest(T: typedesc[CreateNodeRequest];
  ##                        configJson: cstring;
  ##                        appCallbacks: AppCallbacks;
  ##                        ctx: ptr FFIContext[Waku]) ...

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

  # Build formal params: (returnType, request: pointer, waku: ptr Waku)
  let procParams = procNode[3]
  var formalParams: seq[NimNode] = @[]
  formalParams.add(procParams[0]) # return type
  formalParams.add(typedescParam)
  formalParams.add(newIdentDefs(ident("request"), ident("pointer")))
  formalParams.add(newIdentDefs(reqHandler[0], rhs)) # e.g. waku: ptr Waku

  # Inject cast/unpack/defer into the body
  let bodyNode =
    if procNode.body.kind == nnkStmtList:
      procNode.body
    else:
      newStmtList(procNode.body)

  let newBody = newStmtList()
  let reqIdent = ident("req")

  newBody.add quote do:
    let `reqIdent`: ptr `reqTypeName` = cast[ptr `reqTypeName`](request)
    defer:
      ffiDeleteReq(`reqIdent`)

  # automatically unpack fields into locals
  for p in procParams[1 ..^ 1]:
    let fieldName = p[0] # Ident

    newBody.add quote do:
      let `fieldName` = `reqIdent`[].`fieldName`

  # Append user's lambda body
  newBody.add(bodyNode)

  result = newProc(
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
    echo result.repr

proc addNewRequestToRegistry(reqTypeName, reqHandler: NimNode): NimNode =
  ## Adds a new request to the registeredRequests table.
  ## The key is a representation of the request, e.g. "CreateNodeReq".
  ## The value is a proc definition in charge of handling the request from FFI thread.

  # Build: request[].reqContent
  let reqContent =
    newDotExpr(newTree(nnkDerefExpr, ident("request")), ident("reqContent"))

  # Build Future[Result[string, string]] return type
  let returnType = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(ident("Result"), ident("string"), ident("string")),
  )

  # Extract the type from reqHandler (generic: ptr Waku, ptr Foo, ptr Bar, etc.)
  let rhsType =
    if reqHandler.kind == nnkExprColonExpr:
      reqHandler[1] # Use the explicit type
    else:
      error "Second argument must be a typed parameter, e.g. waku: ptr Waku"

  # Build: cast[ptr Waku](reqHandler) or cast[ptr Foo](reqHandler) dynamically
  let castedHandler = newTree(
    nnkCast,
    rhsType, # The type, e.g. ptr Waku
    ident("reqHandler"), # The expression to cast
  )

  let callExpr = newCall(
    newDotExpr(reqTypeName, ident("processFFIRequest")), ident("request"), castedHandler
  )

  var newBody = newStmtList()
  newBody.add(
    quote do:
      return await `callExpr`
  )

  # Build:
  # proc(request: pointer, reqHandler: pointer):
  #     Future[Result[string, string]] {.async.} =
  #   CreateNodeRequest.processFFIRequest(request, reqHandler)
  let asyncProc = newProc(
    name = newEmptyNode(), # anonymous proc
    params =
      @[
        returnType,
        newIdentDefs(ident("request"), ident("pointer")),
        newIdentDefs(ident("reqHandler"), ident("pointer")),
      ],
    body = newBody,
    pragmas = nnkPragma.newTree(ident("async")),
  )

  let reqTypeNameStr = $reqTypeName

  let key = newLit($reqTypeName)
  # Generate: registeredRequests["CreateNodeRequest"] = <generated proc>
  result =
    newAssignment(newTree(nnkBracketExpr, ident("registeredRequests"), key), asyncProc)

  when defined(ffiDumpMacros):
    echo result.repr

macro registerReqFFI*(reqTypeName, reqHandler, body: untyped): untyped =
  ## Registers a request that will be handled by the FFI/working thread.
  ## The request should be sent from the ffi consumer thread.
  ## 
  ## e.g.:
  ## In this example, we register a CreateNodeRequest that will be handled by a proc that contains
  ## the provided lambda body and parameters, by the FFI/working thread.
  ## 
  ## The lambda passed to this macro must:
  ##   - only have no-GC'ed types.
  ##   - Return Future[Result[string, string]] and be annotated with {.async.}
  ##     And notice that the returned values will be sent back to the ffi consumer thread.
  ## 
  ## registerReqFFI(CreateNodeRequest, ctx: ptr FFIContext[Waku]):
  ##   proc(
  ##       configJson: cstring, appCallbacks: AppCallbacks
  ##   ): Future[Result[string, string]] {.async.} =
  ##     ctx.myLib[] = (await createWaku(configJson, cast[AppCallbacks](appCallbacks))).valueOr:
  ##       return err($error)
  ##     return ok("")
  ## 
  ## On the other hand, the created FFI request should be dispatched from the ffi consumer thread
  ## (generally, the main thread) following something like:
  ## 
  ## ffi.sendRequestToFFIThread(
  ##     ctx, CreateNodeRequest.ffiNewReq(callback, userData, configJson, appCallbacks)
  ##   ).isOkOr:
  ##   ...
  ## ...
  ## 

  # Extract lambda params to generate fields
  let fields = extractFieldsFromLambda(body)

  let typeDef = buildRequestType(reqTypeName, body)
  let ffiNewReqProc = buildFfiNewReqProc(reqTypeName, body)
  let processProc = buildProcessFFIRequestProc(reqTypeName, reqHandler, body)
  let addNewReqToReg = addNewRequestToRegistry(reqTypeName, reqHandler)
  let deleteProc = buildFfiDeleteReqProc(reqTypeName, fields)
  result = newStmtList(typeDef, ffiNewReqProc, deleteProc, processProc, addNewReqToReg)

  when defined(ffiDumpMacros):
    echo result.repr

macro processReq*(
    reqType, ctx, callback, userData: untyped, args: varargs[untyped]
): untyped =
  ## Expands T.processReq(ctx, callback, userData, a, b, ...)
  ## e.g.:
  ##   waku_dial_peerReq.processReq(ctx, callback, userData, peerMultiAddr, protocol, timeoutMs)
  ## 

  var callArgs = @[reqType, callback, userData]
  for a in args:
    callArgs.add a

  let newReqCall = newCall(ident("ffiNewReq"), callArgs)

  let sendCall = newCall(
    newDotExpr(ident("ffi_context"), ident("sendRequestToFFIThread")), ctx, newReqCall
  )

  result = quote:
    block:
      let res = `sendCall`
      if res.isErr():
        let msg = "error in sendRequestToFFIThread: " & res.error
        `callback`(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), `userData`)
        return RET_ERR
      return RET_OK

  when defined(ffiDumpMacros):
    echo result.repr

macro ffi*(prc: untyped): untyped =
  ## Defines an FFI-exported proc that registers a request handler to be executed
  ## asynchronously in the FFI thread.
  ## 
  ## {.ffi.} implicitly implies: ...Return[Future[Result[string, string]] {.async.}
  ## 
  ## When using {.ffi.}, the first three parameters must be:
  ##  - ctx: ptr FFIContext[T]  <-- T is the type that handles the FFI requests
  ##  - callback: FFICallBack
  ##  - userData: pointer
  ## Then, additional parameters may be defined as needed, after these first three, always
  ## considering that only no-GC'ed (or C-like) types are allowed.
  ## 
  ## e.g.:
  ## proc waku_version(
  ##     ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
  ## ) {.ffi.} =
  ##   return ok(WakuNodeVersionString)
  ## 
  ## e.g2.:
  ## proc waku_start(
  ##     ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
  ## ) {.ffi.} =
  ##   (await startWaku(ctx[].myLib)).isOkOr:
  ##     error "START_NODE failed", error = error
  ##     return err("failed to start: " & $error)
  ##   return ok("")
  ## 
  ## e.g3.:
  ## proc waku_peer_exchange_request(
  ##     ctx: ptr FFIContext[Waku],
  ##     callback: FFICallBack,
  ##     userData: pointer,
  ##     numPeers: uint64,
  ## ) {.ffi.} =
  ##   let numValidPeers = (await performPeerExchangeRequestTo(numPeers, ctx.myLib[])).valueOr:
  ##     error "waku_peer_exchange_request failed", error = error
  ##     return err("failed peer exchange: " & $error)
  ##   return ok($numValidPeers)
  ## 
  ## In these examples, notice that ctx.myLib is of type "ptr Waku", being Waku main library type.
  ## 

  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  if formalParams.len < 2:
    error("`.ffi.` procs require at least 1 parameter")

  let firstParam = formalParams[1]
  let paramIdent = firstParam[0]
  let paramType = firstParam[1]

  let reqName = ident($procName & "Req")
  let returnType = ident("cint")

  # Build parameter list (skip return type)
  var newParams = newSeq[NimNode]()
  newParams.add(returnType)
  for i in 1 ..< formalParams.len:
    newParams.add(newIdentDefs(formalParams[i][0], formalParams[i][1]))

  # Build Future[Result[string, string]] return type
  let futReturnType = quote:
    Future[Result[string, string]]

  var userParams = newSeq[NimNode]()
  userParams.add(futReturnType)
  if formalParams.len > 3:
    for i in 4 ..< formalParams.len:
      userParams.add(newIdentDefs(formalParams[i][0], formalParams[i][1]))

  # Build argument list for processReq
  var argsList = newSeq[NimNode]()
  for i in 1 ..< formalParams.len:
    argsList.add(formalParams[i][0])

  # 1. Build the dot expression. e.g.: waku_is_onlineReq.processReq
  let dotExpr = newTree(nnkDotExpr, reqName, ident"processReq")

  # 2. Build the call node with dotExpr as callee
  let callNode = newTree(nnkCall, dotExpr)
  for arg in argsList:
    callNode.add(arg)

  # Proc body
  let ffiBody = newStmtList(
    quote do:
      initializeLibrary()
      if not isNil(ctx):
        ctx[].userData = userData
      if isNil(callback):
        return RET_MISSING_CALLBACK
  )

  ffiBody.add(callNode)

  # Under emscripten, `dynlib` makes Nim emit `emcc -shared` (a wasm SIDE module),
  # which breaks EXPORTED_FUNCTIONS/malloc. The wasm/edge build is a MAIN module,
  # so export with plain `exportc` there.
  let exportPragmas =
    when defined(emscripten):
      newTree(nnkPragma, ident "exportc", ident "cdecl")
    else:
      newTree(nnkPragma, ident "dynlib", ident "exportc", ident "cdecl")
  let ffiProc =
    newProc(name = procName, params = newParams, body = ffiBody, pragmas = exportPragmas)

  var anonymousProcNode = newProc(
    name = newEmptyNode(), # anonymous proc
    params = userParams,
    body = newStmtList(bodyNode),
    pragmas = newTree(nnkPragma, ident"async"),
  )

  # registerReqFFI wrapper
  let registerReq = quote:
    registerReqFFI(`reqName`, `paramIdent`: `paramType`):
      `anonymousProcNode`

  result = newStmtList(registerReq, ffiProc)

  when defined(ffiDumpMacros):
    echo result.repr

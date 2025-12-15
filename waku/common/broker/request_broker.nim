## RequestBroker
## --------------------
## RequestBroker represents a proactive decoupling pattern, that
## allows defining request-response style interactions between modules without
## need for direct dependencies in between.
## Worth considering using it in a single provider, many requester scenario.
##
## Provides a declarative way to define an immutable value type together with a
## thread-local broker that can register an asynchronous provider, dispatch typed
## requests and clear provider.
##
## Usage:
## Declare your desired request type inside a `RequestBroker` macro, add any number of fields.
## Define the provider signature, that is enforced at compile time.
##
## ```nim
## RequestBroker:
##   type TypeName = object
##     field1*: FieldType
##     field2*: AnotherFieldType
##
##   proc signature*(): Future[Result[TypeName, string]]
##   ## Also possible to define signature with arbitrary input arguments.
##   proc signature*(arg1: ArgType, arg2: AnotherArgType): Future[Result[TypeName, string]]
##
## ```
##
## Sync mode (no `async` / `Future`) can be generated with:
##
## ```nim
## RequestBroker(sync):
##   type TypeName = object
##     field1*: FieldType
##
##   proc signature*(): Result[TypeName, string]
##   proc signature*(arg1: ArgType): Result[TypeName, string]
## ```
##
## Note: When the request type is declared as a POD / alias / externally-defined
## type (i.e. not an inline `object` / `ref object` definition), RequestBroker
## will wrap it in `distinct` automatically unless you already used `distinct`.
## This avoids overload ambiguity when multiple brokers share the same
## underlying base type (Nim overload resolution does not consider return type).
##
## This means that for non-object request types you typically:
## - construct values with an explicit cast/constructor, e.g. `MyType("x")`
## - unwrap with a cast when needed, e.g. `string(myVal)` or `BaseType(myVal)`
##
## Example (POD response type):
## ```nim
## RequestBroker(sync):
##   type MyCount = int   # exported as: `distinct int`
##
## MyCount.setProvider(proc(): Result[MyCount, string] = ok(MyCount(42)))
## let res = MyCount.request()
## if res.isOk():
##   let raw = int(res.get())
## ```
##
## Example (externally-defined type):
## ```nim
## type External = object
##   label*: string
##
## RequestBroker:
##   type MyExternal = External   # exported as: `distinct External`
##
## MyExternal.setProvider(
##   proc(): Future[Result[MyExternal, string]] {.async.} =
##     ok(MyExternal(External(label: "hi")))
## )
## let res = await MyExternal.request()
## if res.isOk():
##   let base = External(res.get())
##   echo base.label
## ```
## The 'TypeName' object defines the requestable data (but also can be seen as request for action with return value).
## The 'signature' proc defines the provider(s) signature, that is enforced at compile time.
## One signature can be with no arguments, another with any number of arguments - where the input arguments are
## not related to the request type - but alternative inputs for the request to be processed.
##
## After this, you can register a provider anywhere in your code with
## `TypeName.setProvider(...)`, which returns error if already having a provider.
## Providers are async procs/lambdas in default mode and sync procs in sync mode.
## Only one provider can be registered at a time per signature type (zero arg and/or multi arg).
##
## Requests can be made from anywhere with no direct dependency on the provider by
## calling `TypeName.request()` - with arguments respecting the signature(s).
## In async mode, this returns a Future[Result[TypeName, string]]. In sync mode, it returns Result[TypeName, string].
##
## Whenever you no want to process requests (or your object instance that provides the request goes out of scope),
## you can remove it from the broker with `TypeName.clearProvider()`.
##
##
## Example:
## ```nim
## RequestBroker:
##   type Greeting = object
##     text*: string
##
##   ## Define the request and provider signature, that is enforced at compile time.
##   proc signature*(): Future[Result[Greeting, string]] {.async.}
##
##   ## Also possible to define signature with arbitrary input arguments.
##   proc signature*(lang: string): Future[Result[Greeting, string]] {.async.}
##
## ...
## Greeting.setProvider(
##   proc(): Future[Result[Greeting, string]] {.async.} =
##     ok(Greeting(text: "hello"))
## )
## let res = await Greeting.request()
##
##
## ...
## # using POD type as response for a synchronous request.
## RequestBroker(sync):
##   type NeedThatInfo = string
##
##...
##   NeedThatInfo.setProvider(
##     proc(): Result[NeedThatInfo, string] =
##       ok("this is the info you wanted")
##   )
## let res = NeedThatInfo.request().valueOr:
##   echo "not ok due" & error
##   NeedThatInfo(":-(")
##
## echo string(res)
## ```
## If no `signature` proc is declared, a zero-argument form is generated
## automatically, so the caller only needs to provide the type definition.

import std/[macros, strutils]
import chronos
import results
import ./helper/broker_utils

export results, chronos

proc errorFuture[T](message: string): Future[Result[T, string]] {.inline.} =
  ## Build a future that is already completed with an error result.
  let fut = newFuture[Result[T, string]]("request_broker.errorFuture")
  fut.complete(err(Result[T, string], message))
  fut

type RequestBrokerMode = enum
  rbAsync
  rbSync

proc isAsyncReturnTypeValid(returnType, typeIdent: NimNode): bool =
  ## Accept Future[Result[TypeIdent, string]] as the contract.
  if returnType.kind != nnkBracketExpr or returnType.len != 2:
    return false
  if returnType[0].kind != nnkIdent or not returnType[0].eqIdent("Future"):
    return false
  let inner = returnType[1]
  if inner.kind != nnkBracketExpr or inner.len != 3:
    return false
  if inner[0].kind != nnkIdent or not inner[0].eqIdent("Result"):
    return false
  if inner[1].kind != nnkIdent or not inner[1].eqIdent($typeIdent):
    return false
  inner[2].kind == nnkIdent and inner[2].eqIdent("string")

proc isSyncReturnTypeValid(returnType, typeIdent: NimNode): bool =
  ## Accept Result[TypeIdent, string] as the contract.
  if returnType.kind != nnkBracketExpr or returnType.len != 3:
    return false
  if returnType[0].kind != nnkIdent or not returnType[0].eqIdent("Result"):
    return false
  if returnType[1].kind != nnkIdent or not returnType[1].eqIdent($typeIdent):
    return false
  returnType[2].kind == nnkIdent and returnType[2].eqIdent("string")

proc isReturnTypeValid(returnType, typeIdent: NimNode, mode: RequestBrokerMode): bool =
  case mode
  of rbAsync:
    isAsyncReturnTypeValid(returnType, typeIdent)
  of rbSync:
    isSyncReturnTypeValid(returnType, typeIdent)

proc cloneParams(params: seq[NimNode]): seq[NimNode] =
  ## Deep copy parameter definitions so they can be inserted in multiple places.
  result = @[]
  for param in params:
    result.add(copyNimTree(param))

proc collectParamNames(params: seq[NimNode]): seq[NimNode] =
  ## Extract all identifier symbols declared across IdentDefs nodes.
  result = @[]
  for param in params:
    assert param.kind == nnkIdentDefs
    for i in 0 ..< param.len - 2:
      let nameNode = param[i]
      if nameNode.kind == nnkEmpty:
        continue
      result.add(ident($nameNode))

proc makeProcType(
    returnType: NimNode, params: seq[NimNode], mode: RequestBrokerMode
): NimNode =
  var formal = newTree(nnkFormalParams)
  formal.add(returnType)
  for param in params:
    formal.add(param)
  case mode
  of rbAsync:
    let pragmas = newTree(nnkPragma, ident("async"))
    newTree(nnkProcTy, formal, pragmas)
  of rbSync:
    let raisesPragma = newTree(
      nnkExprColonExpr, ident("raises"), newTree(nnkBracket, ident("CatchableError"))
    )
    let pragmas = newTree(nnkPragma, raisesPragma)
    newTree(nnkProcTy, formal, pragmas)

proc parseMode(modeNode: NimNode): RequestBrokerMode =
  ## Parses the mode selector for the 2-argument macro overload.
  ## Supported spellings: `sync` / `async` (case-insensitive).
  let raw = ($modeNode).strip().toLowerAscii()
  case raw
  of "sync", "rbsync":
    rbSync
  of "async", "rbasync":
    rbAsync
  else:
    error("RequestBroker mode must be `sync` or `async` (default is async)", modeNode)

proc ensureDistinctType(rhs: NimNode): NimNode =
  ## For PODs / aliases / externally-defined types, wrap in `distinct` unless
  ## it's already distinct.
  if rhs.kind == nnkDistinctTy:
    return copyNimTree(rhs)
  newTree(nnkDistinctTy, copyNimTree(rhs))

proc generateRequestBroker(body: NimNode, mode: RequestBrokerMode): NimNode =
  when defined(requestBrokerDebug):
    echo body.treeRepr
    echo "RequestBroker mode: ", $mode
  var typeIdent: NimNode = nil
  var objectDef: NimNode = nil
  for stmt in body:
    if stmt.kind == nnkTypeSection:
      for def in stmt:
        if def.kind != nnkTypeDef:
          continue
        if not typeIdent.isNil():
          error("Only one type may be declared inside RequestBroker", def)

        typeIdent = baseTypeIdent(def[0])
        let rhs = def[2]

        ## Support inline object types (fields are auto-exported)
        ## AND non-object types / aliases (e.g. `string`, `int`, `OtherType`).
        case rhs.kind
        of nnkObjectTy:
          let recList = rhs[2]
          if recList.kind != nnkRecList:
            error("RequestBroker object must declare a standard field list", rhs)
          var exportedRecList = newTree(nnkRecList)
          for field in recList:
            case field.kind
            of nnkIdentDefs:
              ensureFieldDef(field)
              var cloned = copyNimTree(field)
              for i in 0 ..< cloned.len - 2:
                cloned[i] = exportIdentNode(cloned[i])
              exportedRecList.add(cloned)
            of nnkEmpty:
              discard
            else:
              error(
                "RequestBroker object definition only supports simple field declarations",
                field,
              )
          objectDef = newTree(
            nnkObjectTy, copyNimTree(rhs[0]), copyNimTree(rhs[1]), exportedRecList
          )
        of nnkRefTy:
          if rhs.len != 1:
            error("RequestBroker ref type must have a single base", rhs)
          if rhs[0].kind == nnkObjectTy:
            let obj = rhs[0]
            let recList = obj[2]
            if recList.kind != nnkRecList:
              error("RequestBroker object must declare a standard field list", obj)
            var exportedRecList = newTree(nnkRecList)
            for field in recList:
              case field.kind
              of nnkIdentDefs:
                ensureFieldDef(field)
                var cloned = copyNimTree(field)
                for i in 0 ..< cloned.len - 2:
                  cloned[i] = exportIdentNode(cloned[i])
                exportedRecList.add(cloned)
              of nnkEmpty:
                discard
              else:
                error(
                  "RequestBroker object definition only supports simple field declarations",
                  field,
                )
            let exportedObjectType = newTree(
              nnkObjectTy, copyNimTree(obj[0]), copyNimTree(obj[1]), exportedRecList
            )
            objectDef = newTree(nnkRefTy, exportedObjectType)
          else:
            ## `ref SomeType` (SomeType can be defined elsewhere)
            objectDef = ensureDistinctType(rhs)
        else:
          ## Non-object type / alias (e.g. `string`, `int`, `SomeExternalType`).
          objectDef = ensureDistinctType(rhs)
  if typeIdent.isNil():
    error("RequestBroker body must declare exactly one type", body)

  when defined(requestBrokerDebug):
    echo "RequestBroker generating type: ", $typeIdent

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let typeDisplayName = sanitizeIdentName(typeIdent)
  let typeNameLit = newLit(typeDisplayName)
  var zeroArgSig: NimNode = nil
  var zeroArgProviderName: NimNode = nil
  var zeroArgFieldName: NimNode = nil
  var argSig: NimNode = nil
  var argParams: seq[NimNode] = @[]
  var argProviderName: NimNode = nil
  var argFieldName: NimNode = nil

  for stmt in body:
    case stmt.kind
    of nnkProcDef:
      let procName = stmt[0]
      let procNameIdent =
        case procName.kind
        of nnkIdent:
          procName
        of nnkPostfix:
          procName[1]
        else:
          procName
      let procNameStr = $procNameIdent
      if not procNameStr.startsWith("signature"):
        error("Signature proc names must start with `signature`", procName)
      let params = stmt.params
      if params.len == 0:
        error("Signature must declare a return type", stmt)
      let returnType = params[0]
      if not isReturnTypeValid(returnType, typeIdent, mode):
        case mode
        of rbAsync:
          error(
            "Signature must return Future[Result[`" & $typeIdent & "`, string]]", stmt
          )
        of rbSync:
          error("Signature must return Result[`" & $typeIdent & "`, string]", stmt)
      let paramCount = params.len - 1
      if paramCount == 0:
        if zeroArgSig != nil:
          error("Only one zero-argument signature is allowed", stmt)
        zeroArgSig = stmt
        zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")
        zeroArgFieldName = ident("providerNoArgs")
      elif paramCount >= 1:
        if argSig != nil:
          error("Only one argument-based signature is allowed", stmt)
        argSig = stmt
        argParams = @[]
        for idx in 1 ..< params.len:
          let paramDef = params[idx]
          if paramDef.kind != nnkIdentDefs:
            error(
              "Signature parameter must be a standard identifier declaration", paramDef
            )
          let paramTypeNode = paramDef[paramDef.len - 2]
          if paramTypeNode.kind == nnkEmpty:
            error("Signature parameter must declare a type", paramDef)
          var hasName = false
          for i in 0 ..< paramDef.len - 2:
            if paramDef[i].kind != nnkEmpty:
              hasName = true
          if not hasName:
            error("Signature parameter must declare a name", paramDef)
          argParams.add(copyNimTree(paramDef))
        argProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderWithArgs")
        argFieldName = ident("providerWithArgs")
    of nnkTypeSection, nnkEmpty:
      discard
    else:
      error("Unsupported statement inside RequestBroker definition", stmt)

  if zeroArgSig.isNil() and argSig.isNil():
    zeroArgSig = newEmptyNode()
    zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")
    zeroArgFieldName = ident("providerNoArgs")

  var typeSection = newTree(nnkTypeSection)
  typeSection.add(newTree(nnkTypeDef, exportedTypeIdent, newEmptyNode(), objectDef))

  let returnType =
    case mode
    of rbAsync:
      quote:
        Future[Result[`typeIdent`, string]]
    of rbSync:
      quote:
        Result[`typeIdent`, string]

  if not zeroArgSig.isNil():
    let procType = makeProcType(returnType, @[], mode)
    typeSection.add(newTree(nnkTypeDef, zeroArgProviderName, newEmptyNode(), procType))
  if not argSig.isNil():
    let procType = makeProcType(returnType, cloneParams(argParams), mode)
    typeSection.add(newTree(nnkTypeDef, argProviderName, newEmptyNode(), procType))

  var brokerRecList = newTree(nnkRecList)
  if not zeroArgSig.isNil():
    brokerRecList.add(
      newTree(nnkIdentDefs, zeroArgFieldName, zeroArgProviderName, newEmptyNode())
    )
  if not argSig.isNil():
    brokerRecList.add(
      newTree(nnkIdentDefs, argFieldName, argProviderName, newEmptyNode())
    )
  let brokerTypeIdent = ident(sanitizeIdentName(typeIdent) & "Broker")
  let brokerTypeDef = newTree(
    nnkTypeDef,
    brokerTypeIdent,
    newEmptyNode(),
    newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), brokerRecList),
  )
  typeSection.add(brokerTypeDef)
  result = newStmtList()
  result.add(typeSection)

  let globalVarIdent = ident("g" & sanitizeIdentName(typeIdent) & "Broker")
  let accessProcIdent = ident("access" & sanitizeIdentName(typeIdent) & "Broker")
  result.add(
    quote do:
      var `globalVarIdent` {.threadvar.}: `brokerTypeIdent`

      proc `accessProcIdent`(): var `brokerTypeIdent` =
        `globalVarIdent`

  )

  var clearBody = newStmtList()
  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `zeroArgProviderName`
        ): Result[void, string] =
          if not `accessProcIdent`().`zeroArgFieldName`.isNil():
            return err("Zero-arg provider already set")
          `accessProcIdent`().`zeroArgFieldName` = handler
          return ok()

    )
    clearBody.add(
      quote do:
        `accessProcIdent`().`zeroArgFieldName` = nil
    )
    case mode
    of rbAsync:
      result.add(
        quote do:
          proc request*(
              _: typedesc[`typeIdent`]
          ): Future[Result[`typeIdent`, string]] {.async: (raises: []).} =
            let provider = `accessProcIdent`().`zeroArgFieldName`
            if provider.isNil():
              return err(
                "RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered"
              )
            let catchedRes = catch:
              await provider()

            if catchedRes.isErr():
              return err("Request failed:" & catchedRes.error.msg)

            let providerRes = catchedRes.get()
            if providerRes.isOk():
              let resultValue = providerRes.get()
              when compiles(resultValue.isNil()):
                if resultValue.isNil():
                  return err(
                    "RequestBroker(" & `typeNameLit` & "): provider returned nil result"
                  )
            return providerRes

      )
    of rbSync:
      result.add(
        quote do:
          proc request*(
              _: typedesc[`typeIdent`]
          ): Result[`typeIdent`, string] {.raises: [].} =
            let provider = `accessProcIdent`().`zeroArgFieldName`
            if provider.isNil():
              return err(
                "RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered"
              )

            var providerRes: Result[`typeIdent`, string]
            try:
              providerRes = provider()
            except CatchableError as e:
              return err("Request failed:" & e.msg)

            if providerRes.isOk():
              let resultValue = providerRes.get()
              when compiles(resultValue.isNil()):
                if resultValue.isNil():
                  return err(
                    "RequestBroker(" & `typeNameLit` & "): provider returned nil result"
                  )
            return providerRes

      )
  if not argSig.isNil():
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `argProviderName`
        ): Result[void, string] =
          if not `accessProcIdent`().`argFieldName`.isNil():
            return err("Provider already set")
          `accessProcIdent`().`argFieldName` = handler
          return ok()

    )
    clearBody.add(
      quote do:
        `accessProcIdent`().`argFieldName` = nil
    )
    let requestParamDefs = cloneParams(argParams)
    let argNameIdents = collectParamNames(requestParamDefs)
    let providerSym = genSym(nskLet, "provider")
    var formalParams = newTree(nnkFormalParams)
    formalParams.add(copyNimTree(returnType))
    formalParams.add(
      newTree(
        nnkIdentDefs,
        ident("_"),
        newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
        newEmptyNode(),
      )
    )
    for paramDef in requestParamDefs:
      formalParams.add(paramDef)

    let requestPragmas =
      case mode
      of rbAsync:
        quote:
          {.async: (raises: []), gcsafe.}
      of rbSync:
        quote:
          {.raises: [].}
    var providerCall = newCall(providerSym)
    for argName in argNameIdents:
      providerCall.add(argName)
    var requestBody = newStmtList()
    requestBody.add(
      quote do:
        let `providerSym` = `accessProcIdent`().`argFieldName`
    )
    requestBody.add(
      quote do:
        if `providerSym`.isNil():
          return err(
            "RequestBroker(" & `typeNameLit` &
              "): no provider registered for input signature"
          )
    )

    case mode
    of rbAsync:
      requestBody.add(
        quote do:
          let catchedRes = catch:
            await `providerCall`
          if catchedRes.isErr():
            return err("Request failed:" & catchedRes.error.msg)

          let providerRes = catchedRes.get()
          if providerRes.isOk():
            let resultValue = providerRes.get()
            when compiles(resultValue.isNil()):
              if resultValue.isNil():
                return err(
                  "RequestBroker(" & `typeNameLit` & "): provider returned nil result"
                )
          return providerRes
      )
    of rbSync:
      requestBody.add(
        quote do:
          var providerRes: Result[`typeIdent`, string]
          try:
            providerRes = `providerCall`
          except CatchableError as e:
            return err("Request failed:" & e.msg)

          if providerRes.isOk():
            let resultValue = providerRes.get()
            when compiles(resultValue.isNil()):
              if resultValue.isNil():
                return err(
                  "RequestBroker(" & `typeNameLit` & "): provider returned nil result"
                )
          return providerRes
      )
    # requestBody.add(providerCall)
    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("request"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        formalParams,
        requestPragmas,
        newEmptyNode(),
        requestBody,
      )
    )

  result.add(
    quote do:
      proc clearProvider*(_: typedesc[`typeIdent`]) =
        `clearBody`

  )

  when defined(requestBrokerDebug):
    echo result.repr

  return result

macro RequestBroker*(body: untyped): untyped =
  ## Default (async) mode.
  generateRequestBroker(body, rbAsync)

macro RequestBroker*(mode: untyped, body: untyped): untyped =
  ## Explicit mode selector.
  ## Example:
  ##   RequestBroker(sync):
  ##     type Foo = object
  ##     proc signature*(): Result[Foo, string]
  generateRequestBroker(body, parseMode(mode))

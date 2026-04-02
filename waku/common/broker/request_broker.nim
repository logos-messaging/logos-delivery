## RequestBroker
## --------------------
## RequestBroker represents a proactive decoupling pattern, that
## allows defining request-response style interactions between modules without
## need for direct dependencies in between.
## Worth considering using it in a single provider, many requester scenario.
##
## Provides a declarative way to define an immutable value type together with a
## thread-local broker that can register an asynchronous or synchronous provider,
## dispatch typed requests and clear provider.
##
## For consideration use `sync` mode RequestBroker when you need to provide simple value(s)
## where there is no long-running async operation involved.
## Typically it act as a accessor for the local state of generic setting.
##
## `async` mode is better to be used when you request date that may involve some long IO operation
## or action.
##
## Default vs. context aware use:
## Every generated broker is a thread-local global instance. This means each RequestBroker enables decoupled
## data exchange threadwise. Sometimes we use brokers inside a context - like inside a component that has many modules or subsystems.
## In case you would instantiate multiple such components in a single thread, and each component must has its own provider for the same RequestBroker type,
## in order to avoid provider collision, you can use context aware RequestBroker.
## Context awareness is supported through the `BrokerContext` argument for `setProvider`, `request`, `clearProvider` interfaces.
## Suce use requires generating a new unique `BrokerContext` value per component instance, and spread it to all modules using the brokers.
## Example, store the `BrokerContext` as a field inside the top level component instance, and spread around at initialization of the subcomponents..
##
## Default broker context is defined as `DefaultBrokerContext` constant. But if you don't need context awareness, you can use the
## interfaces without context argument.
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
## Note: When the request type is declared as a native type / alias / externally-defined
## type (i.e. not an inline `object` / `ref object` definition), RequestBroker
## will wrap it in `distinct` automatically unless you already used `distinct`.
## This avoids overload ambiguity when multiple brokers share the same
## underlying base type (Nim overload resolution does not consider return type).
##
## This means that for non-object request types you typically:
## - construct values with an explicit cast/constructor, e.g. `MyType("x")`
## - unwrap with a cast when needed, e.g. `string(myVal)` or `BaseType(myVal)`
##
## Example (native response type):
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
##
## Providers are stored as a broker-context keyed list:
## - the default provider is always stored at index 0 (reserved broker context: 0)
## - additional providers can be registered under arbitrary non-zero broker contexts
##
## The original `setProvider(handler)` / `request(...)` APIs continue to operate
## on the default provider (broker context 0) for backward compatibility.
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
## # using native type as response for a synchronous request.
## RequestBroker(sync):
##   type NeedThatInfo = string
##
##...
##   NeedThatInfo.setProvider(
##     proc(): Result[NeedThatInfo, string] =
##       ok("this is the info you wanted")
##   )
## let res = NeedThatInfo.request().valueOr:
##   echo "not ok due to: " & error
##   NeedThatInfo(":-(")
##
## echo string(res)
## ```
## If no `signature` proc is declared, a zero-argument form is generated
## automatically, so the caller only needs to provide the type definition.

import std/[macros, strutils]
from std/sequtils import keepItIf
import chronos
import results
import ./helper/broker_utils, broker_context

export results, chronos, keepItIf, broker_context

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
    let pragmas = newTree(nnkPragma, raisesPragma, ident("gcsafe"))
    newTree(nnkProcTy, formal, pragmas)

proc parseMode(modeNode: NimNode): RequestBrokerMode =
  ## Parses the mode selector for the 2-argument macro overload.
  ## Supported spellings: `sync` / `async` (case-insensitive).
  let raw = ($modeNode).strip().toLowerAscii()
  case raw
  of "sync":
    rbSync
  of "async":
    rbAsync
  else:
    error("RequestBroker mode must be `sync` or `async` (default is async)", modeNode)

proc generateRequestBroker(body: NimNode, mode: RequestBrokerMode): NimNode =
  when defined(requestBrokerDebug):
    echo body.treeRepr
    echo "RequestBroker mode: ", $mode
  let parsed = parseSingleTypeDef(body, "RequestBroker", allowRefToNonObject = true)
  let typeIdent = parsed.typeIdent
  let objectDef = parsed.objectDef

  when defined(requestBrokerDebug):
    echo "RequestBroker generating type: ", $typeIdent

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let typeDisplayName = sanitizeIdentName(typeIdent)
  let typeNameLit = newLit(typeDisplayName)
  var zeroArgSig: NimNode = nil
  var zeroArgProviderName: NimNode = nil
  var argSig: NimNode = nil
  var argParams: seq[NimNode] = @[]
  var argProviderName: NimNode = nil

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
    of nnkTypeSection, nnkEmpty:
      discard
    else:
      error("Unsupported statement inside RequestBroker definition", stmt)

  if zeroArgSig.isNil() and argSig.isNil():
    zeroArgSig = newEmptyNode()
    zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")

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
    let zeroArgProvidersFieldName = ident("providersNoArgs")
    let zeroArgProvidersTupleTy = newTree(
      nnkTupleTy,
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode()),
      newTree(nnkIdentDefs, ident("handler"), zeroArgProviderName, newEmptyNode()),
    )
    let zeroArgProvidersSeqTy =
      newTree(nnkBracketExpr, ident("seq"), zeroArgProvidersTupleTy)
    brokerRecList.add(
      newTree(
        nnkIdentDefs, zeroArgProvidersFieldName, zeroArgProvidersSeqTy, newEmptyNode()
      )
    )
  if not argSig.isNil():
    let argProvidersFieldName = ident("providersWithArgs")
    let argProvidersTupleTy = newTree(
      nnkTupleTy,
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode()),
      newTree(nnkIdentDefs, ident("handler"), argProviderName, newEmptyNode()),
    )
    let argProvidersSeqTy = newTree(nnkBracketExpr, ident("seq"), argProvidersTupleTy)
    brokerRecList.add(
      newTree(nnkIdentDefs, argProvidersFieldName, argProvidersSeqTy, newEmptyNode())
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

  var brokerNewBody = newStmtList()
  if not zeroArgSig.isNil():
    brokerNewBody.add(
      quote do:
        result.providersNoArgs =
          @[(brokerCtx: DefaultBrokerContext, handler: default(`zeroArgProviderName`))]
    )
  if not argSig.isNil():
    brokerNewBody.add(
      quote do:
        result.providersWithArgs =
          @[(brokerCtx: DefaultBrokerContext, handler: default(`argProviderName`))]
    )

  var brokerInitChecks = newStmtList()
  if not zeroArgSig.isNil():
    brokerInitChecks.add(
      quote do:
        if `globalVarIdent`.providersNoArgs.len == 0:
          `globalVarIdent` = `brokerTypeIdent`.new()
    )
  if not argSig.isNil():
    brokerInitChecks.add(
      quote do:
        if `globalVarIdent`.providersWithArgs.len == 0:
          `globalVarIdent` = `brokerTypeIdent`.new()
    )

  result.add(
    quote do:
      var `globalVarIdent` {.threadvar.}: `brokerTypeIdent`

      proc new(_: type `brokerTypeIdent`): `brokerTypeIdent` =
        result = `brokerTypeIdent`()
        `brokerNewBody`

      proc `accessProcIdent`(): var `brokerTypeIdent` =
        `brokerInitChecks`
        `globalVarIdent`

  )

  var clearBodyKeyed = newStmtList()
  let brokerCtxParamIdent = ident("brokerCtx")
  if not zeroArgSig.isNil():
    let zeroArgProvidersFieldName = ident("providersNoArgs")
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `zeroArgProviderName`
        ): Result[void, string] =
          if not `accessProcIdent`().`zeroArgProvidersFieldName`[0].handler.isNil():
            return err("Zero-arg provider already set")
          `accessProcIdent`().`zeroArgProvidersFieldName`[0].handler = handler
          return ok()

    )

    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            handler: `zeroArgProviderName`,
        ): Result[void, string] =
          if brokerCtx == DefaultBrokerContext:
            return setProvider(`typeIdent`, handler)

          for entry in `accessProcIdent`().`zeroArgProvidersFieldName`:
            if entry.brokerCtx == brokerCtx:
              return err(
                "RequestBroker(" & `typeNameLit` &
                  "): provider already set for broker context " & $brokerCtx
              )

          `accessProcIdent`().`zeroArgProvidersFieldName`.add(
            (brokerCtx: brokerCtx, handler: handler)
          )
          return ok()

    )
    clearBodyKeyed.add(
      quote do:
        if `brokerCtxParamIdent` == DefaultBrokerContext:
          `accessProcIdent`().`zeroArgProvidersFieldName`[0].handler =
            default(`zeroArgProviderName`)
        else:
          `accessProcIdent`().`zeroArgProvidersFieldName`.keepItIf(
            it.brokerCtx != `brokerCtxParamIdent`
          )
    )
    case mode
    of rbAsync:
      result.add(
        quote do:
          proc request*(
              _: typedesc[`typeIdent`]
          ): Future[Result[`typeIdent`, string]] {.async: (raises: []).} =
            return await request(`typeIdent`, DefaultBrokerContext)

      )

      result.add(
        quote do:
          proc request*(
              _: typedesc[`typeIdent`], brokerCtx: BrokerContext
          ): Future[Result[`typeIdent`, string]] {.async: (raises: []).} =
            var provider: `zeroArgProviderName`
            if brokerCtx == DefaultBrokerContext:
              provider = `accessProcIdent`().`zeroArgProvidersFieldName`[0].handler
            else:
              for entry in `accessProcIdent`().`zeroArgProvidersFieldName`:
                if entry.brokerCtx == brokerCtx:
                  provider = entry.handler
                  break

            if provider.isNil():
              if brokerCtx == DefaultBrokerContext:
                return err(
                  "RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered"
                )
              return err(
                "RequestBroker(" & `typeNameLit` &
                  "): no provider registered for broker context " & $brokerCtx
              )

            let catchedRes = catch:
              await provider()

            if catchedRes.isErr():
              return err(
                "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                  catchedRes.error.msg
              )

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
          ): Result[`typeIdent`, string] {.gcsafe, raises: [].} =
            return request(`typeIdent`, DefaultBrokerContext)

      )

      result.add(
        quote do:
          proc request*(
              _: typedesc[`typeIdent`], brokerCtx: BrokerContext
          ): Result[`typeIdent`, string] {.gcsafe, raises: [].} =
            var provider: `zeroArgProviderName`
            if brokerCtx == DefaultBrokerContext:
              provider = `accessProcIdent`().`zeroArgProvidersFieldName`[0].handler
            else:
              for entry in `accessProcIdent`().`zeroArgProvidersFieldName`:
                if entry.brokerCtx == brokerCtx:
                  provider = entry.handler
                  break

            if provider.isNil():
              if brokerCtx == DefaultBrokerContext:
                return err(
                  "RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered"
                )
              return err(
                "RequestBroker(" & `typeNameLit` &
                  "): no provider registered for broker context " & $brokerCtx
              )

            var providerRes: Result[`typeIdent`, string]
            try:
              providerRes = provider()
            except CatchableError as e:
              return err(
                "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                  e.msg
              )

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
    let argProvidersFieldName = ident("providersWithArgs")
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `argProviderName`
        ): Result[void, string] =
          if not `accessProcIdent`().`argProvidersFieldName`[0].handler.isNil():
            return err("Provider already set")
          `accessProcIdent`().`argProvidersFieldName`[0].handler = handler
          return ok()

    )

    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            handler: `argProviderName`,
        ): Result[void, string] =
          if brokerCtx == DefaultBrokerContext:
            return setProvider(`typeIdent`, handler)

          for entry in `accessProcIdent`().`argProvidersFieldName`:
            if entry.brokerCtx == brokerCtx:
              return err(
                "RequestBroker(" & `typeNameLit` &
                  "): provider already set for broker context " & $brokerCtx
              )

          `accessProcIdent`().`argProvidersFieldName`.add(
            (brokerCtx: brokerCtx, handler: handler)
          )
          return ok()

    )
    clearBodyKeyed.add(
      quote do:
        if `brokerCtxParamIdent` == DefaultBrokerContext:
          `accessProcIdent`().`argProvidersFieldName`[0].handler =
            default(`argProviderName`)
        else:
          `accessProcIdent`().`argProvidersFieldName`.keepItIf(
            it.brokerCtx != `brokerCtxParamIdent`
          )
    )
    let requestParamDefs = cloneParams(argParams)
    let argNameIdents = collectParamNames(requestParamDefs)
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
          {.async: (raises: []).}
      of rbSync:
        quote:
          {.gcsafe, raises: [].}

    var forwardCall = newCall(ident("request"))
    forwardCall.add(copyNimTree(typeIdent))
    forwardCall.add(ident("DefaultBrokerContext"))
    for argName in argNameIdents:
      forwardCall.add(argName)

    var requestBody = newStmtList()
    case mode
    of rbAsync:
      requestBody.add(
        quote do:
          return await `forwardCall`
      )
    of rbSync:
      requestBody.add(
        quote do:
          return `forwardCall`
      )

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

    # Keyed request variant for the argument-based signature.
    let requestParamDefsKeyed = cloneParams(argParams)
    let argNameIdentsKeyed = collectParamNames(requestParamDefsKeyed)
    let providerSymKeyed = genSym(nskVar, "provider")
    var formalParamsKeyed = newTree(nnkFormalParams)
    formalParamsKeyed.add(copyNimTree(returnType))
    formalParamsKeyed.add(
      newTree(
        nnkIdentDefs,
        ident("_"),
        newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
        newEmptyNode(),
      )
    )
    formalParamsKeyed.add(
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
    )
    for paramDef in requestParamDefsKeyed:
      formalParamsKeyed.add(paramDef)

    let requestPragmasKeyed = requestPragmas
    var providerCallKeyed = newCall(providerSymKeyed)
    for argName in argNameIdentsKeyed:
      providerCallKeyed.add(argName)

    var requestBodyKeyed = newStmtList()
    requestBodyKeyed.add(
      quote do:
        var `providerSymKeyed`: `argProviderName`
        if brokerCtx == DefaultBrokerContext:
          `providerSymKeyed` = `accessProcIdent`().`argProvidersFieldName`[0].handler
        else:
          for entry in `accessProcIdent`().`argProvidersFieldName`:
            if entry.brokerCtx == brokerCtx:
              `providerSymKeyed` = entry.handler
              break
    )
    requestBodyKeyed.add(
      quote do:
        if `providerSymKeyed`.isNil():
          if brokerCtx == DefaultBrokerContext:
            return err(
              "RequestBroker(" & `typeNameLit` &
                "): no provider registered for input signature"
            )
          return err(
            "RequestBroker(" & `typeNameLit` &
              "): no provider registered for broker context " & $brokerCtx
          )
    )

    case mode
    of rbAsync:
      requestBodyKeyed.add(
        quote do:
          let catchedRes = catch:
            await `providerCallKeyed`
          if catchedRes.isErr():
            return err(
              "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                catchedRes.error.msg
            )

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
      requestBodyKeyed.add(
        quote do:
          var providerRes: Result[`typeIdent`, string]
          try:
            providerRes = `providerCallKeyed`
          except CatchableError as e:
            return err(
              "RequestBroker(" & `typeNameLit` & "): provider threw exception: " & e.msg
            )

          if providerRes.isOk():
            let resultValue = providerRes.get()
            when compiles(resultValue.isNil()):
              if resultValue.isNil():
                return err(
                  "RequestBroker(" & `typeNameLit` & "): provider returned nil result"
                )
          return providerRes
      )

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("request"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        formalParamsKeyed,
        requestPragmasKeyed,
        newEmptyNode(),
        requestBodyKeyed,
      )
    )

  block:
    var formalParamsClearKeyed = newTree(nnkFormalParams)
    formalParamsClearKeyed.add(newEmptyNode())
    formalParamsClearKeyed.add(
      newTree(
        nnkIdentDefs,
        ident("_"),
        newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
        newEmptyNode(),
      )
    )
    formalParamsClearKeyed.add(
      newTree(nnkIdentDefs, brokerCtxParamIdent, ident("BrokerContext"), newEmptyNode())
    )

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("clearProvider"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        formalParamsClearKeyed,
        newEmptyNode(),
        newEmptyNode(),
        clearBodyKeyed,
      )
    )

  result.add(
    quote do:
      proc clearProvider*(_: typedesc[`typeIdent`]) =
        clearProvider(`typeIdent`, DefaultBrokerContext)

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

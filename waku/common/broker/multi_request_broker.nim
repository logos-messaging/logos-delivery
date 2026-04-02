## MultiRequestBroker
## --------------------
## MultiRequestBroker represents a proactive decoupling pattern, that
## allows defining request-response style interactions between modules without
## need for direct dependencies in between.
## Worth considering using it for use cases where you need to collect data from multiple providers.
##
## Generates a standalone, type-safe request broker for the declared type.
## The macro exports the value type itself plus a broker companion that manages
## providers via thread-local storage.
##
## Unlike `RequestBroker`, every call to `request` fan-outs to every registered
## provider and returns all collected responses.
## The request succeeds only if all providers succeed, otherwise it fails.
##
## Type definitions:
## - Inline `object` / `ref object` definitions are supported.
## - Native types, aliases, and externally-defined types are also supported.
##   In that case, MultiRequestBroker will automatically wrap the declared RHS
##   type in `distinct` unless you already used `distinct`.
##   This keeps request types unique even when multiple brokers share the same
##   underlying base type.
##
## Default vs. context aware use:
## Every generated broker is a thread-local global instance.
## Sometimes you want multiple independent provider sets for the same request
## type within the same thread (e.g. multiple components). For that, you can use
## context-aware MultiRequestBroker.
##
## Context awareness is supported through the `BrokerContext` argument for
## `setProvider`, `request`, `removeProvider`, and `clearProviders`.
## Provider stores are kept separate per broker context.
##
## Default broker context is defined as `DefaultBrokerContext`. If you don't
## need context awareness, you can keep using the interfaces without the context
## argument, which operate on `DefaultBrokerContext`.
##
## Usage:
##
## Declare collectable request data type inside a `MultiRequestBroker` macro, add any number of fields:
## ```nim
## MultiRequestBroker:
##   type TypeName = object
##     field1*: Type1
##     field2*: Type2
##
##   ## Define the request and provider signature, that is enforced at compile time.
##   proc signature*(): Future[Result[TypeName, string]] {.async: (raises: []).}
##
##   ## Also possible to define signature with arbitrary input arguments.
##   proc signature*(arg1: ArgType, arg2: AnotherArgType): Future[Result[TypeName, string]] {.async: (raises: []).}
##
## ```
##
## You can register a request processor (provider) anywhere without the need to
## know who will request.
## Register provider functions with `TypeName.setProvider(...)`.
## Providers are async procs or lambdas that return `Future[Result[TypeName, string]]`.
## `setProvider` returns a handle (or an error) that can later be used to remove
## the provider.

## Requests can be made from anywhere with no direct dependency on the provider(s)
## by calling `TypeName.request()` (with arguments respecting the declared signature).
## This will asynchronously call all registered providers and return the collected
## responses as `Future[Result[seq[TypeName], string]]`.
##
## Whenever you don't want to process requests anymore (or your object instance that provides the request goes out of scope),
## you can remove it from the broker with `TypeName.removeProvider(handle)`.
## Alternatively, you can remove all registered providers through `TypeName.clearProviders()`.
##
## Example:
## ```nim
## MultiRequestBroker:
##   type Greeting = object
##     text*: string
##
##   ## Define the request and provider signature, that is enforced at compile time.
##   proc signature*(): Future[Result[Greeting, string]] {.async: (raises: []).}
##
##   ## Also possible to define signature with arbitrary input arguments.
##   proc signature*(lang: string): Future[Result[Greeting, string]] {.async: (raises: []).}
##
## ...
## let handle = Greeting.setProvider(
##   proc(): Future[Result[Greeting, string]] {.async: (raises: []).} =
##     ok(Greeting(text: "hello"))
## )
##
## let anotherHandle = Greeting.setProvider(
##  proc(): Future[Result[Greeting, string]] {.async: (raises: []).} =
##   ok(Greeting(text: "szia"))
## )
##
## let responses = (await Greeting.request()).valueOr(@[Greeting(text: "default")])
##
## echo responses.len
## Greeting.clearProviders()
## ```
## If no `signature` proc is declared, a zero-argument form is generated
## automatically, so the caller only needs to provide the type definition.

import std/[macros, strutils, tables, sugar]
import chronos
import results
import ./helper/broker_utils
import ./broker_context

export results, chronos, broker_context

proc isReturnTypeValid(returnType, typeIdent: NimNode): bool =
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

proc makeProcType(returnType: NimNode, params: seq[NimNode]): NimNode =
  var formal = newTree(nnkFormalParams)
  formal.add(returnType)
  for param in params:
    formal.add(param)

  let pragmas = quote:
    {.async.}

  newTree(nnkProcTy, formal, pragmas)

macro MultiRequestBroker*(body: untyped): untyped =
  when defined(requestBrokerDebug):
    echo body.treeRepr
  let parsed = parseSingleTypeDef(body, "MultiRequestBroker")
  let typeIdent = parsed.typeIdent
  let objectDef = parsed.objectDef
  let isRefObject = parsed.isRefObject

  when defined(requestBrokerDebug):
    echo "MultiRequestBroker generating type: ", $typeIdent

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let sanitized = sanitizeIdentName(typeIdent)
  let typeNameLit = newLit($typeIdent)
  let isRefObjectLit = newLit(isRefObject)
  let uint64Ident = ident("uint64")
  let providerKindIdent = ident(sanitized & "ProviderKind")
  let providerHandleIdent = ident(sanitized & "ProviderHandle")
  let exportedProviderHandleIdent = postfix(copyNimTree(providerHandleIdent), "*")
  let bucketTypeIdent = ident(sanitized & "CtxBucket")
  let findBucketIdxIdent = ident(sanitized & "FindBucketIdx")
  let getOrCreateBucketIdxIdent = ident(sanitized & "GetOrCreateBucketIdx")
  let zeroKindIdent = ident("pk" & sanitized & "NoArgs")
  let argKindIdent = ident("pk" & sanitized & "WithArgs")
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
      if not isReturnTypeValid(returnType, typeIdent):
        error(
          "Signature must return Future[Result[`" & $typeIdent & "`, string]]", stmt
        )
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
      error("Unsupported statement inside MultiRequestBroker definition", stmt)

  if zeroArgSig.isNil() and argSig.isNil():
    zeroArgSig = newEmptyNode()
    zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")
    zeroArgFieldName = ident("providerNoArgs")

  var typeSection = newTree(nnkTypeSection)
  typeSection.add(newTree(nnkTypeDef, exportedTypeIdent, newEmptyNode(), objectDef))

  var kindEnum = newTree(nnkEnumTy, newEmptyNode())
  if not zeroArgSig.isNil():
    kindEnum.add(zeroKindIdent)
  if not argSig.isNil():
    kindEnum.add(argKindIdent)
  typeSection.add(newTree(nnkTypeDef, providerKindIdent, newEmptyNode(), kindEnum))

  var handleRecList = newTree(nnkRecList)
  handleRecList.add(newTree(nnkIdentDefs, ident("id"), uint64Ident, newEmptyNode()))
  handleRecList.add(
    newTree(nnkIdentDefs, ident("kind"), providerKindIdent, newEmptyNode())
  )
  typeSection.add(
    newTree(
      nnkTypeDef,
      exportedProviderHandleIdent,
      newEmptyNode(),
      newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), handleRecList),
    )
  )

  let returnType = quote:
    Future[Result[`typeIdent`, string]]

  if not zeroArgSig.isNil():
    let procType = makeProcType(returnType, @[])
    typeSection.add(newTree(nnkTypeDef, zeroArgProviderName, newEmptyNode(), procType))
  if not argSig.isNil():
    let procType = makeProcType(returnType, cloneParams(argParams))
    typeSection.add(newTree(nnkTypeDef, argProviderName, newEmptyNode(), procType))

  var bucketRecList = newTree(nnkRecList)
  bucketRecList.add(
    newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
  )
  if not zeroArgSig.isNil():
    bucketRecList.add(
      newTree(
        nnkIdentDefs,
        zeroArgFieldName,
        newTree(nnkBracketExpr, ident("seq"), zeroArgProviderName),
        newEmptyNode(),
      )
    )
  if not argSig.isNil():
    bucketRecList.add(
      newTree(
        nnkIdentDefs,
        argFieldName,
        newTree(nnkBracketExpr, ident("seq"), argProviderName),
        newEmptyNode(),
      )
    )
  typeSection.add(
    newTree(
      nnkTypeDef,
      bucketTypeIdent,
      newEmptyNode(),
      newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), bucketRecList),
    )
  )

  var brokerRecList = newTree(nnkRecList)
  brokerRecList.add(
    newTree(
      nnkIdentDefs,
      ident("buckets"),
      newTree(nnkBracketExpr, ident("seq"), bucketTypeIdent),
      newEmptyNode(),
    )
  )
  let brokerTypeIdent = ident(sanitizeIdentName(typeIdent) & "Broker")
  typeSection.add(
    newTree(
      nnkTypeDef,
      brokerTypeIdent,
      newEmptyNode(),
      newTree(
        nnkRefTy, newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), brokerRecList)
      ),
    )
  )
  result = newStmtList()
  result.add(typeSection)

  let globalVarIdent = ident("g" & sanitizeIdentName(typeIdent) & "Broker")
  let accessProcIdent = ident("access" & sanitizeIdentName(typeIdent) & "Broker")
  result.add(
    quote do:
      var `globalVarIdent` {.threadvar.}: `brokerTypeIdent`

      proc `findBucketIdxIdent`(
          broker: `brokerTypeIdent`, brokerCtx: BrokerContext
      ): int =
        if brokerCtx == DefaultBrokerContext:
          return 0
        for i in 1 ..< broker.buckets.len:
          if broker.buckets[i].brokerCtx == brokerCtx:
            return i
        return -1

      proc `getOrCreateBucketIdxIdent`(
          broker: `brokerTypeIdent`, brokerCtx: BrokerContext
      ): int =
        let idx = `findBucketIdxIdent`(broker, brokerCtx)
        if idx >= 0:
          return idx
        broker.buckets.add(`bucketTypeIdent`(brokerCtx: brokerCtx))
        return broker.buckets.high

      proc `accessProcIdent`(): `brokerTypeIdent` =
        if `globalVarIdent`.isNil():
          new(`globalVarIdent`)
          `globalVarIdent`.buckets =
            @[`bucketTypeIdent`(brokerCtx: DefaultBrokerContext)]
        return `globalVarIdent`

  )

  var clearBody = newStmtList()
  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            handler: `zeroArgProviderName`,
        ): Result[`providerHandleIdent`, string] =
          if handler.isNil():
            return err("Provider handler must be provided")
          let broker = `accessProcIdent`()
          let bucketIdx = `getOrCreateBucketIdxIdent`(broker, brokerCtx)
          for i, existing in broker.buckets[bucketIdx].`zeroArgFieldName`:
            if not existing.isNil() and existing == handler:
              return ok(`providerHandleIdent`(id: uint64(i + 1), kind: `zeroKindIdent`))
          broker.buckets[bucketIdx].`zeroArgFieldName`.add(handler)
          return ok(
            `providerHandleIdent`(
              id: uint64(broker.buckets[bucketIdx].`zeroArgFieldName`.len),
              kind: `zeroKindIdent`,
            )
          )

        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `zeroArgProviderName`
        ): Result[`providerHandleIdent`, string] =
          return setProvider(`typeIdent`, DefaultBrokerContext, handler)

    )
    result.add(
      quote do:
        proc request*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): Future[Result[seq[`typeIdent`], string]] {.async: (raises: []), gcsafe.} =
          var aggregated: seq[`typeIdent`] = @[]
          let broker = `accessProcIdent`()
          let bucketIdx = `findBucketIdxIdent`(broker, brokerCtx)
          if bucketIdx < 0:
            return ok(aggregated)
          let providers = broker.buckets[bucketIdx].`zeroArgFieldName`
          if providers.len == 0:
            return ok(aggregated)
          # var providersFut: seq[Future[Result[`typeIdent`, string]]] = collect:
          var providersFut = collect(newSeq):
            for provider in providers:
              if provider.isNil():
                continue
              provider()

          let catchable = catch:
            await allFinished(providersFut)

          catchable.isOkOr:
            return err("Some provider(s) failed:" & error.msg)

          for fut in catchable.get():
            if fut.failed():
              return err("Some provider(s) failed:" & fut.error.msg)
            elif fut.finished():
              let providerResult = fut.value()
              if providerResult.isOk:
                let providerValue = providerResult.get()
                when `isRefObjectLit`:
                  if providerValue.isNil():
                    return err(
                      "MultiRequestBroker(" & `typeNameLit` &
                        "): provider returned nil result"
                    )
                aggregated.add(providerValue)
              else:
                return err("Some provider(s) failed:" & providerResult.error)

          return ok(aggregated)

        proc request*(
            _: typedesc[`typeIdent`]
        ): Future[Result[seq[`typeIdent`], string]] =
          return request(`typeIdent`, DefaultBrokerContext)

    )
  if not argSig.isNil():
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            handler: `argProviderName`,
        ): Result[`providerHandleIdent`, string] =
          if handler.isNil():
            return err("Provider handler must be provided")
          let broker = `accessProcIdent`()
          let bucketIdx = `getOrCreateBucketIdxIdent`(broker, brokerCtx)
          for i, existing in broker.buckets[bucketIdx].`argFieldName`:
            if not existing.isNil() and existing == handler:
              return ok(`providerHandleIdent`(id: uint64(i + 1), kind: `argKindIdent`))
          broker.buckets[bucketIdx].`argFieldName`.add(handler)
          return ok(
            `providerHandleIdent`(
              id: uint64(broker.buckets[bucketIdx].`argFieldName`.len),
              kind: `argKindIdent`,
            )
          )

        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `argProviderName`
        ): Result[`providerHandleIdent`, string] =
          return setProvider(`typeIdent`, DefaultBrokerContext, handler)

    )
    let requestParamDefs = cloneParams(argParams)
    let argNameIdents = collectParamNames(requestParamDefs)
    let providerSym = genSym(nskLet, "providerVal")
    var providerCall = newCall(providerSym)
    for argName in argNameIdents:
      providerCall.add(argName)
    var formalParams = newTree(nnkFormalParams)
    formalParams.add(
      quote do:
        Future[Result[seq[`typeIdent`], string]]
    )
    formalParams.add(
      newTree(
        nnkIdentDefs,
        ident("_"),
        newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
        newEmptyNode(),
      )
    )
    formalParams.add(
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
    )
    for paramDef in requestParamDefs:
      formalParams.add(paramDef)
    let requestPragmas = quote:
      {.async: (raises: []), gcsafe.}
    let requestBody = quote:
      var aggregated: seq[`typeIdent`] = @[]
      let broker = `accessProcIdent`()
      let bucketIdx = `findBucketIdxIdent`(broker, brokerCtx)
      if bucketIdx < 0:
        return ok(aggregated)
      let providers = broker.buckets[bucketIdx].`argFieldName`
      if providers.len == 0:
        return ok(aggregated)
      var providersFut = collect(newSeq):
        for provider in providers:
          if provider.isNil():
            continue
          let `providerSym` = provider
          `providerCall`
      let catchable = catch:
        await allFinished(providersFut)
      catchable.isOkOr:
        return err("Some provider(s) failed:" & error.msg)
      for fut in catchable.get():
        if fut.failed():
          return err("Some provider(s) failed:" & fut.error.msg)
        elif fut.finished():
          let providerResult = fut.value()
          if providerResult.isOk:
            let providerValue = providerResult.get()
            when `isRefObjectLit`:
              if providerValue.isNil():
                return err(
                  "MultiRequestBroker(" & `typeNameLit` &
                    "): provider returned nil result"
                )
            aggregated.add(providerValue)
          else:
            return err("Some provider(s) failed:" & providerResult.error)
      return ok(aggregated)

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

    # Backward-compatible default-context overload (no brokerCtx parameter).
    var formalParamsDefault = newTree(nnkFormalParams)
    formalParamsDefault.add(
      quote do:
        Future[Result[seq[`typeIdent`], string]]
    )
    formalParamsDefault.add(
      newTree(
        nnkIdentDefs,
        ident("_"),
        newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
        newEmptyNode(),
      )
    )
    for paramDef in requestParamDefs:
      formalParamsDefault.add(copyNimTree(paramDef))

    var wrapperCall = newCall(ident("request"))
    wrapperCall.add(copyNimTree(typeIdent))
    wrapperCall.add(ident("DefaultBrokerContext"))
    for argName in argNameIdents:
      wrapperCall.add(copyNimTree(argName))

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("request"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        formalParamsDefault,
        newEmptyNode(),
        newEmptyNode(),
        newStmtList(newTree(nnkReturnStmt, wrapperCall)),
      )
    )
  let removeHandleCtxSym = genSym(nskParam, "handle")
  let removeHandleDefaultSym = genSym(nskParam, "handle")

  when true:
    # Generate clearProviders / removeProvider with macro-time knowledge about which
    # provider lists exist (zero-arg and/or arg providers).
    if not zeroArgSig.isNil() and not argSig.isNil():
      result.add(
        quote do:
          proc clearProviders*(_: typedesc[`typeIdent`], brokerCtx: BrokerContext) =
            let broker = `accessProcIdent`()
            if broker.isNil():
              return
            let bucketIdx = `findBucketIdxIdent`(broker, brokerCtx)
            if bucketIdx < 0:
              return
            broker.buckets[bucketIdx].`zeroArgFieldName`.setLen(0)
            broker.buckets[bucketIdx].`argFieldName`.setLen(0)
            if brokerCtx != DefaultBrokerContext:
              broker.buckets.delete(bucketIdx)

          proc clearProviders*(_: typedesc[`typeIdent`]) =
            clearProviders(`typeIdent`, DefaultBrokerContext)

          proc removeProvider*(
              _: typedesc[`typeIdent`],
              brokerCtx: BrokerContext,
              `removeHandleCtxSym`: `providerHandleIdent`,
          ) =
            if `removeHandleCtxSym`.id == 0'u64:
              return
            let broker = `accessProcIdent`()
            if broker.isNil():
              return
            let bucketIdx = `findBucketIdxIdent`(broker, brokerCtx)
            if bucketIdx < 0:
              return

            if `removeHandleCtxSym`.kind == `zeroKindIdent`:
              let idx = int(`removeHandleCtxSym`.id) - 1
              if idx >= 0 and idx < broker.buckets[bucketIdx].`zeroArgFieldName`.len:
                broker.buckets[bucketIdx].`zeroArgFieldName`[idx] = nil
            elif `removeHandleCtxSym`.kind == `argKindIdent`:
              let idx = int(`removeHandleCtxSym`.id) - 1
              if idx >= 0 and idx < broker.buckets[bucketIdx].`argFieldName`.len:
                broker.buckets[bucketIdx].`argFieldName`[idx] = nil

            if brokerCtx != DefaultBrokerContext:
              var hasAny = false
              for p in broker.buckets[bucketIdx].`zeroArgFieldName`:
                if not p.isNil():
                  hasAny = true
                  break
              if not hasAny:
                for p in broker.buckets[bucketIdx].`argFieldName`:
                  if not p.isNil():
                    hasAny = true
                    break
              if not hasAny:
                broker.buckets.delete(bucketIdx)

          proc removeProvider*(
              _: typedesc[`typeIdent`], `removeHandleDefaultSym`: `providerHandleIdent`
          ) =
            removeProvider(`typeIdent`, DefaultBrokerContext, `removeHandleDefaultSym`)

      )
    elif not zeroArgSig.isNil():
      result.add(
        quote do:
          proc clearProviders*(_: typedesc[`typeIdent`], brokerCtx: BrokerContext) =
            let broker = `accessProcIdent`()
            if broker.isNil():
              return
            let bucketIdx = `findBucketIdxIdent`(broker, brokerCtx)
            if bucketIdx < 0:
              return
            broker.buckets[bucketIdx].`zeroArgFieldName`.setLen(0)
            if brokerCtx != DefaultBrokerContext:
              broker.buckets.delete(bucketIdx)

          proc clearProviders*(_: typedesc[`typeIdent`]) =
            clearProviders(`typeIdent`, DefaultBrokerContext)

          proc removeProvider*(
              _: typedesc[`typeIdent`],
              brokerCtx: BrokerContext,
              `removeHandleCtxSym`: `providerHandleIdent`,
          ) =
            if `removeHandleCtxSym`.id == 0'u64:
              return
            let broker = `accessProcIdent`()
            if broker.isNil():
              return
            let bucketIdx = `findBucketIdxIdent`(broker, brokerCtx)
            if bucketIdx < 0:
              return
            if `removeHandleCtxSym`.kind != `zeroKindIdent`:
              return
            let idx = int(`removeHandleCtxSym`.id) - 1
            if idx >= 0 and idx < broker.buckets[bucketIdx].`zeroArgFieldName`.len:
              broker.buckets[bucketIdx].`zeroArgFieldName`[idx] = nil
            if brokerCtx != DefaultBrokerContext:
              var hasAny = false
              for p in broker.buckets[bucketIdx].`zeroArgFieldName`:
                if not p.isNil():
                  hasAny = true
                  break
              if not hasAny:
                broker.buckets.delete(bucketIdx)

          proc removeProvider*(
              _: typedesc[`typeIdent`], `removeHandleDefaultSym`: `providerHandleIdent`
          ) =
            removeProvider(`typeIdent`, DefaultBrokerContext, `removeHandleDefaultSym`)

      )
    else:
      result.add(
        quote do:
          proc clearProviders*(_: typedesc[`typeIdent`], brokerCtx: BrokerContext) =
            let broker = `accessProcIdent`()
            if broker.isNil():
              return
            let bucketIdx = `findBucketIdxIdent`(broker, brokerCtx)
            if bucketIdx < 0:
              return
            broker.buckets[bucketIdx].`argFieldName`.setLen(0)
            if brokerCtx != DefaultBrokerContext:
              broker.buckets.delete(bucketIdx)

          proc clearProviders*(_: typedesc[`typeIdent`]) =
            clearProviders(`typeIdent`, DefaultBrokerContext)

          proc removeProvider*(
              _: typedesc[`typeIdent`],
              brokerCtx: BrokerContext,
              `removeHandleCtxSym`: `providerHandleIdent`,
          ) =
            if `removeHandleCtxSym`.id == 0'u64:
              return
            let broker = `accessProcIdent`()
            if broker.isNil():
              return
            let bucketIdx = `findBucketIdxIdent`(broker, brokerCtx)
            if bucketIdx < 0:
              return
            if `removeHandleCtxSym`.kind != `argKindIdent`:
              return
            let idx = int(`removeHandleCtxSym`.id) - 1
            if idx >= 0 and idx < broker.buckets[bucketIdx].`argFieldName`.len:
              broker.buckets[bucketIdx].`argFieldName`[idx] = nil
            if brokerCtx != DefaultBrokerContext:
              var hasAny = false
              for p in broker.buckets[bucketIdx].`argFieldName`:
                if not p.isNil():
                  hasAny = true
                  break
              if not hasAny:
                broker.buckets.delete(bucketIdx)

          proc removeProvider*(
              _: typedesc[`typeIdent`], `removeHandleDefaultSym`: `providerHandleIdent`
          ) =
            removeProvider(`typeIdent`, DefaultBrokerContext, `removeHandleDefaultSym`)

      )

  when defined(requestBrokerDebug):
    echo result.repr

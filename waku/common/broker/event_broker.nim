## EventBroker
## -------------------
## EventBroker represents a reactive decoupling pattern, that
## allows event-driven development without
## need for direct dependencies in between emitters and listeners.
## Worth considering using it in a single or many emitters to many listeners scenario.
##
## Generates a standalone, type-safe event broker for the declared type.
## The macro exports the value type itself plus a broker companion that manages
## listeners via thread-local storage.
##
## Type definitions:
## - Inline `object` / `ref object` definitions are supported.
## - Native types, aliases, and externally-defined types are also supported.
##   In that case, EventBroker will automatically wrap the declared RHS type in
##   `distinct` unless you already used `distinct`.
##   This keeps event types unique even when multiple brokers share the same
##   underlying base type.
##
## Default vs. context aware use:
## Every generated broker is a thread-local global instance. This means EventBroker
## enables decoupled event exchange threadwise.
##
## Sometimes we use brokers inside a context (e.g. within a component that has many
## modules or subsystems). If you instantiate multiple such components in a single
## thread, and each component must have its own listener set for the same EventBroker
## type, you can use context-aware EventBroker.
##
## Context awareness is supported through the `BrokerContext` argument for
## `listen`, `emit`, `dropListener`, and `dropAllListeners`.
## Listener stores are kept separate per broker context.
##
## Default broker context is defined as `DefaultBrokerContext`. If you don't need
## context awareness, you can keep using the interfaces without the context
## argument, which operate on `DefaultBrokerContext`.
##
## Usage:
## Declare your desired event type inside an `EventBroker` macro, add any number of fields.:
## ```nim
## EventBroker:
##   type TypeName = object
##     field1*: FieldType
##     field2*: AnotherFieldType
## ```
##
## After this, you can register async listeners anywhere in your code with
## `TypeName.listen(...)`, which returns a handle to the registered listener.
## Listeners are async procs or lambdas that take a single argument of the event type.
## Any number of listeners can be registered in different modules.
##
## Events can be emitted from anywhere with no direct dependency on the listeners by
## calling `TypeName.emit(...)` with an instance of the event type.
## This will asynchronously notify all registered listeners with the emitted event.
##
## Whenever you no longer need a listener (or your object instance that listen to the event goes out of scope),
## you can remove it from the broker with the handle returned by `listen`.
## This is done by calling `TypeName.dropListener(handle)`.
## Alternatively, you can remove all registered listeners through `TypeName.dropAllListeners()`.
##
##
## Example:
## ```nim
## EventBroker:
##   type GreetingEvent = object
##     text*: string
##
## let handle = GreetingEvent.listen(
##   proc(evt: GreetingEvent): Future[void] {.async.} =
##     echo evt.text
## )
## GreetingEvent.emit(text= "hi")
## GreetingEvent.dropListener(handle)
## ```

## Example (non-object event type):
## ```nim
## EventBroker:
##   type CounterEvent = int  # exported as: `distinct int`
##
## discard CounterEvent.listen(
##   proc(evt: CounterEvent): Future[void] {.async.} =
##     echo int(evt)
## )
## CounterEvent.emit(CounterEvent(42))
## ```

import std/[macros, tables]
import chronos, chronicles, results
import ./helper/broker_utils, broker_context

export chronicles, results, chronos, broker_context

macro EventBroker*(body: untyped): untyped =
  when defined(eventBrokerDebug):
    echo body.treeRepr
  let parsed = parseSingleTypeDef(body, "EventBroker", collectFieldInfo = true)
  let typeIdent = parsed.typeIdent
  let objectDef = parsed.objectDef
  let fieldNames = parsed.fieldNames
  let fieldTypes = parsed.fieldTypes
  let hasInlineFields = parsed.hasInlineFields

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let sanitized = sanitizeIdentName(typeIdent)
  let typeNameLit = newLit($typeIdent)
  let handlerProcIdent = ident(sanitized & "ListenerProc")
  let listenerHandleIdent = ident(sanitized & "Listener")
  let brokerTypeIdent = ident(sanitized & "Broker")
  let exportedHandlerProcIdent = postfix(copyNimTree(handlerProcIdent), "*")
  let exportedListenerHandleIdent = postfix(copyNimTree(listenerHandleIdent), "*")
  let exportedBrokerTypeIdent = postfix(copyNimTree(brokerTypeIdent), "*")
  let bucketTypeIdent = ident(sanitized & "CtxBucket")
  let findBucketIdxIdent = ident(sanitized & "FindBucketIdx")
  let getOrCreateBucketIdxIdent = ident(sanitized & "GetOrCreateBucketIdx")
  let accessProcIdent = ident("access" & sanitized & "Broker")
  let globalVarIdent = ident("g" & sanitized & "Broker")
  let listenImplIdent = ident("register" & sanitized & "Listener")
  let dropListenerImplIdent = ident("drop" & sanitized & "Listener")
  let dropAllListenersImplIdent = ident("dropAll" & sanitized & "Listeners")
  let emitImplIdent = ident("emit" & sanitized & "Value")
  let listenerTaskIdent = ident("notify" & sanitized & "Listener")

  result = newStmtList()

  result.add(
    quote do:
      type
        `exportedTypeIdent` = `objectDef`
        `exportedListenerHandleIdent` = object
          id*: uint64

        `exportedHandlerProcIdent` =
          proc(event: `typeIdent`): Future[void] {.async: (raises: []), gcsafe.}
        `bucketTypeIdent` = object
          brokerCtx: BrokerContext
          listeners: Table[uint64, `handlerProcIdent`]
          nextId: uint64

        `exportedBrokerTypeIdent` = ref object
          buckets: seq[`bucketTypeIdent`]

  )

  result.add(
    quote do:
      var `globalVarIdent` {.threadvar.}: `brokerTypeIdent`
  )

  result.add(
    quote do:
      proc `accessProcIdent`(): `brokerTypeIdent` =
        if `globalVarIdent`.isNil():
          new(`globalVarIdent`)
          `globalVarIdent`.buckets =
            @[
              `bucketTypeIdent`(
                brokerCtx: DefaultBrokerContext,
                listeners: initTable[uint64, `handlerProcIdent`](),
                nextId: 1'u64,
              )
            ]
        `globalVarIdent`

  )

  result.add(
    quote do:
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
        broker.buckets.add(
          `bucketTypeIdent`(
            brokerCtx: brokerCtx,
            listeners: initTable[uint64, `handlerProcIdent`](),
            nextId: 1'u64,
          )
        )
        return broker.buckets.high

      proc `listenImplIdent`(
          brokerCtx: BrokerContext, handler: `handlerProcIdent`
      ): Result[`listenerHandleIdent`, string] =
        if handler.isNil():
          return err("Must provide a non-nil event handler")
        var broker = `accessProcIdent`()

        let bucketIdx = `getOrCreateBucketIdxIdent`(broker, brokerCtx)
        if broker.buckets[bucketIdx].nextId == 0'u64:
          broker.buckets[bucketIdx].nextId = 1'u64

        if broker.buckets[bucketIdx].nextId == high(uint64):
          error "Cannot add more listeners: ID space exhausted",
            nextId = $broker.buckets[bucketIdx].nextId
          return err("Cannot add more listeners, listener ID space exhausted")

        let newId = broker.buckets[bucketIdx].nextId
        inc broker.buckets[bucketIdx].nextId
        broker.buckets[bucketIdx].listeners[newId] = handler
        return ok(`listenerHandleIdent`(id: newId))

  )

  result.add(
    quote do:
      proc `dropListenerImplIdent`(
          brokerCtx: BrokerContext, handle: `listenerHandleIdent`
      ) =
        if handle.id == 0'u64:
          return
        var broker = `accessProcIdent`()

        let bucketIdx = `findBucketIdxIdent`(broker, brokerCtx)
        if bucketIdx < 0:
          return

        if broker.buckets[bucketIdx].listeners.len == 0:
          return
        broker.buckets[bucketIdx].listeners.del(handle.id)
        if brokerCtx != DefaultBrokerContext and
            broker.buckets[bucketIdx].listeners.len == 0:
          broker.buckets.delete(bucketIdx)

  )

  result.add(
    quote do:
      proc `dropAllListenersImplIdent`(brokerCtx: BrokerContext) =
        var broker = `accessProcIdent`()

        let bucketIdx = `findBucketIdxIdent`(broker, brokerCtx)
        if bucketIdx < 0:
          return
        if broker.buckets[bucketIdx].listeners.len > 0:
          broker.buckets[bucketIdx].listeners.clear()
        if brokerCtx != DefaultBrokerContext:
          broker.buckets.delete(bucketIdx)

  )

  result.add(
    quote do:
      proc listen*(
          _: typedesc[`typeIdent`], handler: `handlerProcIdent`
      ): Result[`listenerHandleIdent`, string] =
        return `listenImplIdent`(DefaultBrokerContext, handler)

      proc listen*(
          _: typedesc[`typeIdent`],
          brokerCtx: BrokerContext,
          handler: `handlerProcIdent`,
      ): Result[`listenerHandleIdent`, string] =
        return `listenImplIdent`(brokerCtx, handler)

  )

  result.add(
    quote do:
      proc dropListener*(_: typedesc[`typeIdent`], handle: `listenerHandleIdent`) =
        `dropListenerImplIdent`(DefaultBrokerContext, handle)

      proc dropListener*(
          _: typedesc[`typeIdent`],
          brokerCtx: BrokerContext,
          handle: `listenerHandleIdent`,
      ) =
        `dropListenerImplIdent`(brokerCtx, handle)

      proc dropAllListeners*(_: typedesc[`typeIdent`]) =
        `dropAllListenersImplIdent`(DefaultBrokerContext)

      proc dropAllListeners*(_: typedesc[`typeIdent`], brokerCtx: BrokerContext) =
        `dropAllListenersImplIdent`(brokerCtx)

  )

  result.add(
    quote do:
      proc `listenerTaskIdent`(
          callback: `handlerProcIdent`, event: `typeIdent`
      ) {.async: (raises: []), gcsafe.} =
        if callback.isNil():
          return
        try:
          await callback(event)
        except Exception:
          error "Failed to execute event listener", error = getCurrentExceptionMsg()

      proc `emitImplIdent`(
          brokerCtx: BrokerContext, event: `typeIdent`
      ): Future[void] {.async: (raises: []), gcsafe.} =
        when compiles(event.isNil()):
          if event.isNil():
            error "Cannot emit uninitialized event object", eventType = `typeNameLit`
            return
        let broker = `accessProcIdent`()
        let bucketIdx = `findBucketIdxIdent`(broker, brokerCtx)
        if bucketIdx < 0:
          # nothing to do as nobody is listening
          return
        if broker.buckets[bucketIdx].listeners.len == 0:
          return
        var callbacks: seq[`handlerProcIdent`] = @[]
        for cb in broker.buckets[bucketIdx].listeners.values:
          callbacks.add(cb)
        for cb in callbacks:
          asyncSpawn `listenerTaskIdent`(cb, event)

      proc emit*(event: `typeIdent`) =
        asyncSpawn `emitImplIdent`(DefaultBrokerContext, event)

      proc emit*(_: typedesc[`typeIdent`], event: `typeIdent`) =
        asyncSpawn `emitImplIdent`(DefaultBrokerContext, event)

      proc emit*(
          _: typedesc[`typeIdent`], brokerCtx: BrokerContext, event: `typeIdent`
      ) =
        asyncSpawn `emitImplIdent`(brokerCtx, event)

  )

  if hasInlineFields:
    # Typedesc emit constructor overloads for inline object/ref object types.
    var emitCtorParams = newTree(nnkFormalParams, newEmptyNode())
    let typedescParamType =
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent))
    emitCtorParams.add(
      newTree(nnkIdentDefs, ident("_"), typedescParamType, newEmptyNode())
    )
    for i in 0 ..< fieldNames.len:
      emitCtorParams.add(
        newTree(
          nnkIdentDefs,
          copyNimTree(fieldNames[i]),
          copyNimTree(fieldTypes[i]),
          newEmptyNode(),
        )
      )

    var emitCtorExpr = newTree(nnkObjConstr, copyNimTree(typeIdent))
    for i in 0 ..< fieldNames.len:
      emitCtorExpr.add(
        newTree(
          nnkExprColonExpr, copyNimTree(fieldNames[i]), copyNimTree(fieldNames[i])
        )
      )

    let emitCtorCallDefault =
      newCall(copyNimTree(emitImplIdent), ident("DefaultBrokerContext"), emitCtorExpr)
    let emitCtorBodyDefault = quote:
      asyncSpawn `emitCtorCallDefault`

    let typedescEmitProcDefault = newTree(
      nnkProcDef,
      postfix(ident("emit"), "*"),
      newEmptyNode(),
      newEmptyNode(),
      emitCtorParams,
      newEmptyNode(),
      newEmptyNode(),
      emitCtorBodyDefault,
    )
    result.add(typedescEmitProcDefault)

    var emitCtorParamsCtx = newTree(nnkFormalParams, newEmptyNode())
    emitCtorParamsCtx.add(
      newTree(nnkIdentDefs, ident("_"), typedescParamType, newEmptyNode())
    )
    emitCtorParamsCtx.add(
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
    )
    for i in 0 ..< fieldNames.len:
      emitCtorParamsCtx.add(
        newTree(
          nnkIdentDefs,
          copyNimTree(fieldNames[i]),
          copyNimTree(fieldTypes[i]),
          newEmptyNode(),
        )
      )

    let emitCtorCallCtx =
      newCall(copyNimTree(emitImplIdent), ident("brokerCtx"), copyNimTree(emitCtorExpr))
    let emitCtorBodyCtx = quote:
      asyncSpawn `emitCtorCallCtx`

    let typedescEmitProcCtx = newTree(
      nnkProcDef,
      postfix(ident("emit"), "*"),
      newEmptyNode(),
      newEmptyNode(),
      emitCtorParamsCtx,
      newEmptyNode(),
      newEmptyNode(),
      emitCtorBodyCtx,
    )
    result.add(typedescEmitProcCtx)

  when defined(eventBrokerDebug):
    echo result.repr

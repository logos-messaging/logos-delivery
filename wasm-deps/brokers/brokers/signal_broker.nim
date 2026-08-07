## SignalBroker
## -------------------
## SignalBroker is a fire-and-forget, single-handler, no-response decoupling
## pattern. Semantically it is EventBroker's dispatch shape (a synchronous call
## site that `asyncSpawn`s the handler, with no reply path) combined with
## RequestBroker's single-registry model and a `Result[void, string]`
## acceptance check.
##
## Use it when exactly one consumer should react to a one-way notification and
## the producer wants a cheap, best-effort *acceptance* signal (was a handler
## installed? did the queue have room?) — but does NOT need to know whether the
## handler ran or what it produced.
##
## `signal(...)` is a plain (non-async) proc returning `Result[void, string]`:
## - `ok()` means **accepted** (spawned / enqueued) — a best-effort snapshot,
##   never "handled".
## - `err` means **definitely not delivered**, with two distinguishable
##   messages: `"no signal handler installed"` and (multi-thread only)
##   `"queue full"`, so bursty callers can throttle on the latter.
##
## Handler errors are never surfaced — there is no reply path; handler
## exceptions are swallowed with a chronicles warn, exactly like EventBroker
## listener tasks.
##
## **`ok()` is not "handled".** If you need delivery confirmation, use
## `RequestBroker` with a `void` response instead.
##
## Registration:
## - `TypeName.onSignal(handler)` installs the single handler; it returns `err`
##   if a handler is already installed (mirrors `RequestBroker.setProvider`).
## - `TypeName.dropSignalHandler()` removes it (async `Future[void]`, uniform
##   shape with EventBroker's `dropListener`; the body is suspension-free).
## - Mock/replace trio for tests and dynamic feature toggles:
##   `replaceSignalHandler` (replace-or-insert, never errors on an existing
##   entry; `default(...)` clears), `getCurrentSignalHandler`, and the scoped
##   `withMockSignalHandler(t, ctx, mock): body` (capture → mock → restore).
##
## Context awareness works exactly like the other brokers: pass a
## `BrokerContext` to any interface to scope an independent handler; omit it to
## operate on `DefaultBrokerContext`.
##
## Type definitions mirror EventBroker:
## - inline `object` / `ref object` (fields auto-exported; `signal` gains
##   inline-field overloads like `emit`'s constructor overloads),
## - non-object types / aliases (wrapped in `distinct` unless already distinct),
## - `void` — a payload-less "pulse" signal (`TypeName.signal()`).
##
## Example:
## ```nim
## SignalBroker:
##   type IngestSample = object
##     deviceId*: string
##     value*: float64
##
## discard IngestSample.onSignal(
##   proc(s: IngestSample): Future[void] {.async: (raises: []).} =
##     echo s.deviceId, " = ", s.value
## )
## let r = IngestSample.signal(deviceId = "d1", value = 0.5)
## if r.isErr():
##   echo "not delivered: ", r.error
## await IngestSample.dropSignalHandler()
## ```

import std/[macros, strutils, options]
import chronos, chronicles, results
import ./internal/helper/broker_utils, ./broker_context
import ./internal/broker_debug

when compileOption("threads"):
  import ./internal/mt_config, ./internal/mt_signal_broker
  export mt_config, mt_signal_broker

when compileOption("threads") and defined(BrokerFfiApi):
  import ./internal/api_signal_broker_cbor
  export api_signal_broker_cbor

export chronicles, results, chronos, broker_context, options

type SignalBrokerMode = enum
  sbDefault
  sbMultiThread
  sbApi

proc parseSignalBrokerMode(modeNode: NimNode): SignalBrokerMode =
  ## Parses the mode selector for the multi-argument macro overload.
  ## Follows the RequestBroker parser precedent: a single generic diagnostic
  ## for any unrecognized mode (no special-cased `(multi)`/`(sync)` message).
  let raw = ($modeNode).strip().toLowerAscii()
  case raw
  of "mt":
    sbMultiThread
  of "api":
    sbApi
  else:
    error("SignalBroker mode must be `mt` or `API`", modeNode)

proc generateSignalBroker(body: NimNode): NimNode =
  when defined(brokerDebug):
    echo body.treeRepr
  let parsed = parseSingleTypeDef(body, "SignalBroker", collectFieldInfo = true)
  let typeIdent = parsed.typeIdent
  let objectDef = parsed.objectDef
  let fieldNames = parsed.fieldNames
  let fieldTypes = parsed.fieldTypes
  let hasInlineFields = parsed.hasInlineFields
  let isVoid = parsed.isVoid

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let sanitized = sanitizeIdentName(typeIdent)
  let typeNameLit = newLit($typeIdent)
  # Distinct `Signal`-flavored ident prefix (caveat 5): avoids clashing with the
  # `providerSignal` / `ThreadSignalPtr` / `BrokerSignalShared` names that
  # pervade the MT internals.
  let handlerProcIdent = ident(sanitized & "SignalHandler")
  let brokerTypeIdent = ident(sanitized & "SignalBroker")
  let exportedHandlerProcIdent = postfix(copyNimTree(handlerProcIdent), "*")
  let accessProcIdent = ident("access" & sanitized & "SignalBroker")
  let globalVarIdent = ident("g" & sanitized & "SignalBroker")
  let findHandlerIdent = ident("find" & sanitized & "SignalHandler")
  let signalTaskIdent = ident("notify" & sanitized & "Signal")

  result = newStmtList()

  let handlerProcTy =
    if isVoid:
      quote:
        proc(): Future[void] {.async: (raises: []), gcsafe.}
    else:
      quote:
        proc(signalValue: `typeIdent`): Future[void] {.async: (raises: []), gcsafe.}

  # ── Types: value type, handler proc type, broker storage ───────────────
  var brokerRecList = newTree(nnkRecList)
  let handlersTupleTy = newTree(
    nnkTupleTy,
    newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode()),
    newTree(
      nnkIdentDefs, ident("handler"), copyNimTree(handlerProcIdent), newEmptyNode()
    ),
  )
  let handlersSeqTy = newTree(nnkBracketExpr, ident("seq"), handlersTupleTy)
  brokerRecList.add(
    newTree(nnkIdentDefs, ident("handlers"), handlersSeqTy, newEmptyNode())
  )
  result.add(
    newTree(
      nnkTypeSection,
      newTree(nnkTypeDef, exportedTypeIdent, newEmptyNode(), objectDef),
      newTree(nnkTypeDef, exportedHandlerProcIdent, newEmptyNode(), handlerProcTy),
      newTree(
        nnkTypeDef,
        brokerTypeIdent,
        newEmptyNode(),
        newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), brokerRecList),
      ),
    )
  )

  # ── Storage: thread-local global + lazy init + ctx lookup ──────────────
  result.add(
    quote do:
      var `globalVarIdent` {.threadvar.}: `brokerTypeIdent`

      proc new(_: type `brokerTypeIdent`): `brokerTypeIdent` =
        result = `brokerTypeIdent`()
        result.handlers =
          @[(brokerCtx: DefaultBrokerContext, handler: default(`handlerProcIdent`))]

      proc `accessProcIdent`(): var `brokerTypeIdent` =
        if `globalVarIdent`.handlers.len == 0:
          `globalVarIdent` = `brokerTypeIdent`.new()
        `globalVarIdent`

      proc `findHandlerIdent`(
          broker: `brokerTypeIdent`, brokerCtx: BrokerContext
      ): `handlerProcIdent` =
        if brokerCtx == DefaultBrokerContext:
          return broker.handlers[0].handler
        for entry in broker.handlers:
          if entry.brokerCtx == brokerCtx:
            return entry.handler
        default(`handlerProcIdent`)

  )

  # ── Dispatch task: swallow handler exceptions with a chronicles warn ───
  if isVoid:
    result.add(
      quote do:
        proc `signalTaskIdent`(
            callback: `handlerProcIdent`
        ) {.async: (raises: []), gcsafe.} =
          if callback.isNil():
            return
          try:
            await callback()
          except Exception:
            warn "SignalBroker handler raised",
              signalType = `typeNameLit`, error = getCurrentExceptionMsg()

    )
  else:
    result.add(
      quote do:
        proc `signalTaskIdent`(
            callback: `handlerProcIdent`, signalValue: `typeIdent`
        ) {.async: (raises: []), gcsafe.} =
          if callback.isNil():
            return
          try:
            await callback(signalValue)
          except Exception:
            warn "SignalBroker handler raised",
              signalType = `typeNameLit`, error = getCurrentExceptionMsg()

    )

  # ── onSignal (register, duplicate-guarded) ─────────────────────────────
  result.add(
    quote do:
      proc onSignal*(
          _: typedesc[`typeIdent`], handler: `handlerProcIdent`
      ): Result[void, string] =
        if handler.isNil():
          return err("SignalBroker(" & `typeNameLit` & "): handler must be non-nil")
        if not `accessProcIdent`().handlers[0].handler.isNil():
          return err("SignalBroker(" & `typeNameLit` & "): handler already set")
        `accessProcIdent`().handlers[0].handler = handler
        ok()

      proc onSignal*(
          _: typedesc[`typeIdent`],
          brokerCtx: BrokerContext,
          handler: `handlerProcIdent`,
      ): Result[void, string] =
        if handler.isNil():
          return err("SignalBroker(" & `typeNameLit` & "): handler must be non-nil")
        if brokerCtx == DefaultBrokerContext:
          return onSignal(`typeIdent`, handler)
        for entry in `accessProcIdent`().handlers:
          if entry.brokerCtx == brokerCtx:
            return err(
              "SignalBroker(" & `typeNameLit` &
                "): handler already set for broker context " & $brokerCtx
            )
        `accessProcIdent`().handlers.add((brokerCtx: brokerCtx, handler: handler))
        ok()

  )

  # ── signal (accept-and-spawn) ──────────────────────────────────────────
  if isVoid:
    result.add(
      quote do:
        proc signal*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): Result[void, string] =
          let handler = `findHandlerIdent`(`accessProcIdent`(), brokerCtx)
          if handler.isNil():
            return err("no signal handler installed")
          asyncSpawn `signalTaskIdent`(handler)
          ok()

        proc signal*(_: typedesc[`typeIdent`]): Result[void, string] =
          signal(`typeIdent`, DefaultBrokerContext)

    )
  else:
    result.add(
      quote do:
        proc signal*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext, signalValue: `typeIdent`
        ): Result[void, string] =
          when compiles(signalValue.isNil()):
            if signalValue.isNil():
              return
                err("SignalBroker(" & `typeNameLit` & "): cannot signal a nil value")
          let handler = `findHandlerIdent`(`accessProcIdent`(), brokerCtx)
          if handler.isNil():
            return err("no signal handler installed")
          asyncSpawn `signalTaskIdent`(handler, signalValue)
          ok()

        proc signal*(
            _: typedesc[`typeIdent`], signalValue: `typeIdent`
        ): Result[void, string] =
          signal(`typeIdent`, DefaultBrokerContext, signalValue)

        proc signal*(signalValue: `typeIdent`): Result[void, string] =
          signal(`typeIdent`, DefaultBrokerContext, signalValue)

    )

  # ── dropSignalHandler (async, suspension-free body) ────────────────────
  result.add(
    quote do:
      proc dropSignalHandler*(
          _: typedesc[`typeIdent`], brokerCtx: BrokerContext
      ): Future[void] {.async: (raises: []).} =
        if brokerCtx == DefaultBrokerContext:
          `accessProcIdent`().handlers[0].handler = default(`handlerProcIdent`)
        else:
          var i = 0
          while i < `accessProcIdent`().handlers.len:
            if `accessProcIdent`().handlers[i].brokerCtx == brokerCtx:
              `accessProcIdent`().handlers.delete(i)
            else:
              inc i

      proc dropSignalHandler*(
          _: typedesc[`typeIdent`]
      ): Future[void] {.async: (raises: []).} =
        await dropSignalHandler(`typeIdent`, DefaultBrokerContext)

  )

  # ── hasSignalHandler ───────────────────────────────────────────────────
  result.add(
    quote do:
      proc hasSignalHandler*(_: typedesc[`typeIdent`], brokerCtx: BrokerContext): bool =
        not `findHandlerIdent`(`accessProcIdent`(), brokerCtx).isNil()

      proc hasSignalHandler*(_: typedesc[`typeIdent`]): bool =
        hasSignalHandler(`typeIdent`, DefaultBrokerContext)

  )

  # ── Mock/replace trio (replaceSignalHandler / getCurrentSignalHandler /
  #    withMockSignalHandler) ─────────────────────────────────────────────
  result.add(
    quote do:
      proc getCurrentSignalHandler*(
          _: typedesc[`typeIdent`], brokerCtx: BrokerContext
      ): Option[`handlerProcIdent`] =
        let handler = `findHandlerIdent`(`accessProcIdent`(), brokerCtx)
        if handler.isNil():
          none(`handlerProcIdent`)
        else:
          some(handler)

      proc replaceSignalHandler*(
          _: typedesc[`typeIdent`],
          brokerCtx: BrokerContext,
          handler: `handlerProcIdent`,
      ): Result[void, string] =
        ## Replace-or-insert; unlike onSignal it never errors on an existing
        ## entry. `default(handler-type)` clears the slot.
        if brokerCtx == DefaultBrokerContext:
          `accessProcIdent`().handlers[0].handler = handler
          return ok()
        for i in 0 ..< `accessProcIdent`().handlers.len:
          if `accessProcIdent`().handlers[i].brokerCtx == brokerCtx:
            `accessProcIdent`().handlers[i].handler = handler
            return ok()
        `accessProcIdent`().handlers.add((brokerCtx: brokerCtx, handler: handler))
        ok()

      template withMockSignalHandler*(
          t: typedesc[`typeIdent`],
          brokerCtx: BrokerContext,
          mock: `handlerProcIdent`,
          body: untyped,
      ): untyped =
        ## Install `mock` for the duration of `body`, then restore the captured
        ## handler (or drop it if none was set). Scoped, exception-safe. The
        ## restore-or-drop `finally` relies on `dropSignalHandler`'s
        ## suspension-free body — a discarded Future still clears eagerly.
        let savedMockSignalHandler = getCurrentSignalHandler(t, brokerCtx)
        discard replaceSignalHandler(t, brokerCtx, mock)
        try:
          body
        finally:
          if savedMockSignalHandler.isSome:
            discard replaceSignalHandler(t, brokerCtx, savedMockSignalHandler.get)
          else:
            discard dropSignalHandler(t, brokerCtx)

  )

  # ── Inline-field overloads of `signal` (like emit's ctor overloads) ────
  if hasInlineFields:
    var emitCtorExpr = newTree(nnkObjConstr, copyNimTree(typeIdent))
    for i in 0 ..< fieldNames.len:
      emitCtorExpr.add(
        newTree(
          nnkExprColonExpr, copyNimTree(fieldNames[i]), copyNimTree(fieldNames[i])
        )
      )

    let resultType = quote:
      Result[void, string]

    # Default-context overload: `X.signal(field1 = .., field2 = ..)`
    block:
      var params = newTree(nnkFormalParams, copyNimTree(resultType))
      params.add(
        newTree(
          nnkIdentDefs,
          ident("_"),
          newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
          newEmptyNode(),
        )
      )
      for i in 0 ..< fieldNames.len:
        params.add(
          newTree(
            nnkIdentDefs,
            copyNimTree(fieldNames[i]),
            copyNimTree(fieldTypes[i]),
            newEmptyNode(),
          )
        )
      let callDefault = newCall(
        ident("signal"),
        copyNimTree(typeIdent),
        ident("DefaultBrokerContext"),
        copyNimTree(emitCtorExpr),
      )
      result.add(
        newTree(
          nnkProcDef,
          postfix(ident("signal"), "*"),
          newEmptyNode(),
          newEmptyNode(),
          params,
          newEmptyNode(),
          newEmptyNode(),
          newStmtList(callDefault),
        )
      )

    # Context-aware overload: `X.signal(ctx, field1 = .., field2 = ..)`
    block:
      var params = newTree(nnkFormalParams, copyNimTree(resultType))
      params.add(
        newTree(
          nnkIdentDefs,
          ident("_"),
          newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
          newEmptyNode(),
        )
      )
      params.add(
        newTree(
          nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode()
        )
      )
      for i in 0 ..< fieldNames.len:
        params.add(
          newTree(
            nnkIdentDefs,
            copyNimTree(fieldNames[i]),
            copyNimTree(fieldTypes[i]),
            newEmptyNode(),
          )
        )
      let callCtx = newCall(
        ident("signal"),
        copyNimTree(typeIdent),
        ident("brokerCtx"),
        copyNimTree(emitCtorExpr),
      )
      result.add(
        newTree(
          nnkProcDef,
          postfix(ident("signal"), "*"),
          newEmptyNode(),
          newEmptyNode(),
          params,
          newEmptyNode(),
          newEmptyNode(),
          newStmtList(callCtx),
        )
      )

  # ── bind / rebind signal-handler sugar (issue #42) ────────────────
  # `bindSignalHandler` = sugar for `onSignal`, `rebindSignalHandler` = sugar for
  # `replaceSignalHandler`. Single handler slot; the trampoline carries the
  # handler proc type's pragma and forwards the signal value (or nothing, void).
  block:
    var slot = BindSlot(returnType: futureVoidTy(), pragma: procTyPragma(handlerProcTy))
    if isVoid:
      slot.params = @[]
    else:
      slot.params = @[
        newTree(
          nnkIdentDefs, ident("signalValue"), copyNimTree(typeIdent), newEmptyNode()
        )
      ]
    result.add(
      buildBindTemplates(
        typeIdent, "onSignal", "bindSignalHandler", @[slot], awaitCall = true
      )
    )
    result.add(
      buildBindTemplates(
        typeIdent,
        "replaceSignalHandler",
        "rebindSignalHandler",
        @[slot],
        awaitCall = true,
      )
    )

  when defined(brokerDebug):
    writeBrokerDebug("SignalBroker", sanitized, result)
    when defined(brokerDebugStdout):
      echo result.repr

macro SignalBroker*(args: varargs[untyped]): untyped =
  ## Fire-and-forget, single-handler, no-response broker.
  ##
  ## Examples:
  ##   SignalBroker:
  ##     type IngestSample = object
  ##       deviceId*: string
  ##       value*: float64
  ##
  ##   SignalBroker(mt):
  ##     type IngestSample = object
  ##       value*: float64
  ##
  ##   SignalBroker(mt, queueDepth = 1024, slabCapacity = 4096):
  ##     type IngestSample = object
  ##       value*: float64
  if args.len == 0:
    macros.error("SignalBroker requires a body block")
  if args.len == 1:
    return generateSignalBroker(args[0])
  let mode = args[0]
  let body = args[^1]
  if body.kind notin {nnkStmtList, nnkTypeDef, nnkTypeSection}:
    error(
      "SignalBroker(" & mode.repr &
        ") body must be a `:` block of type definitions (got " & $body.kind & ")",
      body,
    )
  var kwargs: seq[NimNode]
  for i in 1 ..< args.len - 1:
    kwargs.add(args[i])
  let m = parseSignalBrokerMode(mode)
  case m
  of sbMultiThread:
    when not compileOption("threads"):
      macros.error(
          "SignalBroker(mt) requires --threads:on. " &
          "Compile with `--threads:on` to use multi-thread SignalBroker."
      )
    else:
      let cfg = parseMtSigKwargs(kwargs)
      generateMtSignalBroker(body, cfg)
  of sbApi:
    when not compileOption("threads"):
      macros.error(
          "SignalBroker(API) requires --threads:on. " &
          "Compile with `--threads:on` to use API SignalBroker."
      )
    else:
      when defined(BrokerFfiApi):
        discard parseMtSigKwargs(kwargs)
        generateApiCborSignalBroker(body, kwargs)
      else:
        let cfg = parseMtSigKwargs(kwargs)
        generateMtSignalBroker(body, cfg)
  of sbDefault:
    if kwargs.len > 0:
      error("SignalBroker does not accept kwargs in default mode", kwargs[0])
    generateSignalBroker(body)

# ── onSignalIt body sugar ────────────────────────────────────────────
# Generic over every SignalBroker lane (single-thread / mt / API): forwards to
# whatever `onSignal` overload is in scope at the call site. Purely syntactic —
# identical codegen to the hand-written handler lambda, no new refc/ORC
# exposure. Extra params stay `untyped` (see `bindTemplateDef`).

template onSignalIt*(T: typedesc, brokerCtx: untyped, body: untyped): untyped =
  ## Sugar over `onSignal(T, brokerCtx, handler)`: the block is the handler's
  ## real proc body with the signal value injected as `it` (nothing is
  ## injected for `void` signal types). `await` is allowed; `raises: []` is
  ## enforced exactly as for a hand-written handler. Returns `onSignal`'s
  ## Result.
  mixin onSignal
  when compiles(
    onSignal(
      T,
      brokerCtx,
      proc(): Future[void] {.async: (raises: []), gcsafe.} =
        discard,
    )
  ):
    onSignal(
      T,
      brokerCtx,
      proc(): Future[void] {.async: (raises: []), gcsafe.} =
        body,
    )
  else:
    onSignal(
      T,
      brokerCtx,
      proc(brokerSignal: T): Future[void] {.async: (raises: []), gcsafe.} =
        template it(): T {.inject, used.} =
          brokerSignal

        body,
    )

template onSignalIt*(T: typedesc, body: untyped): untyped =
  ## `onSignalIt` on the default broker context.
  onSignalIt(T, DefaultBrokerContext, body)

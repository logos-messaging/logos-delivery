## BrokerImplement — derived implementation of a BrokerInterface
## (doc/design/HIERARCHICAL_BROKERS_PLAN.md, phase P4).
##
##   type MyServiceImpl = ref object of IMyService
##     db: Database
##
##   BrokerImplement MyServiceImpl of IMyService:
##     proc new(T: typedesc[MyServiceImpl], db: Database): MyServiceImpl =
##       MyServiceImpl(db: db)        ## natural ctor: build + return a bare
##                                    ## instance (no ctx, no providers)
##     method getHealth(self: MyServiceImpl): Future[Result[GetHealth, string]] =
##       ok(GetHealth(...))           ## raw method body for each request verb
##
## An optional `proc init(self: MyServiceImpl)` hook may also be declared; it
## runs AFTER `self.brokerCtx` is bound and BEFORE providers are wired, so it can
## derive per-instance state from `self.brokerCtx` (which the bare `new` cannot).
##
## Generates:
##   * `MyServiceImpl.create(db = ...)` — allocate a fresh instance brokerCtx,
##     call the user `new`, and wire per-instance provider closures;
##   * `MyServiceImpl.createUnderContext(ctx, db = ...)` — same, but ADOPT an
##     externally-supplied `ctx` (the FFI library ctx, or a parent's sub-ctx);
##   * `close(self)` — clears those providers, breaking the instance<->closure
##     cycle (mandatory under --mm:refc) and freeing the instance ctx for reuse.
##
## Each request provider closure dispatches to the raw `<verb>Impl` body
## (capturing `self`). The public call surface is the interface's tunneling proc
## (`<Broker>.request(self.brokerCtx, …)`), so direct/base-typed calls route
## through the broker rather than a direct vtable call. The user `new` returns a
## bare, unwired instance — call `create` / `createUnderContext` to get a working
## one.

import std/[macros, strutils, atomics]
import chronos, results
import ./broker_context
import ./request_broker, ./event_broker, ./signal_broker
import ./internal/helper/broker_utils
import ./internal/broker_debug

export chronos, results, broker_context, request_broker, event_broker, signal_broker

proc canonPragma(async: bool): NimNode {.compileTime.} =
  ## Canonical override pragma matching the BrokerInterface abstract base
  ## (byte-identical async/raises/gcsafe is required for method dispatch).
  let src =
    if async:
      "proc d() {.async: (raises: []), gcsafe.} = discard"
    else:
      "proc d() {.gcsafe, raises: [].} = discard"
  parseStmt(src)[0][4]

proc isAsyncRet(ret: NimNode): bool {.compileTime.} =
  ret.kind == nnkBracketExpr and ret.len >= 1 and ret[0].kind == nnkIdent and
    ret[0].eqIdent("Future")

proc isFutureVoid(ret: NimNode): bool {.compileTime.} =
  ## `Future[void]` — the shape of a SignalBroker handler override (no reply
  ## path), as opposed to a request method's `Future[Result[T, string]]`.
  ret.kind == nnkBracketExpr and ret.len == 2 and ret[0].eqIdent("Future") and
    ret[1].kind == nnkIdent and ret[1].eqIdent("void")

proc baseName(n: NimNode): NimNode {.compileTime.} =
  if n.kind == nnkPostfix:
    n[1]
  else:
    n

proc copyLineInfoRec(n, info: NimNode) {.compileTime.} =
  ## Recursively stamp `info`'s source location onto every node of `n`.
  ## `parseStmt`-generated procs carry synthetic line info; for an `{.async.}`
  ## proc that ALSO has a `typedesc` parameter (implicitly generic) that breaks
  ## the chronos async transform with a compiler-level OSError. Re-stamping a
  ## real location before emitting sidesteps it.
  n.copyLineInfo(info)
  for c in n:
    copyLineInfoRec(c, info)

macro BrokerImplement*(args: varargs[untyped]): untyped =
  ## See module docs. Invoked as `BrokerImplement Impl of IFace: <body>`.
  if args.len < 2:
    macros.error("BrokerImplement requires `Impl of IFace:` and a body")
  let body = args[^1]
  if body.kind != nnkStmtList:
    macros.error("BrokerImplement body must be a `:` block")
  let infix = args[0]
  if infix.kind != nnkInfix or not infix[0].eqIdent("of"):
    macros.error(
      "BrokerImplement must be written `BrokerImplement Impl of IFace:`", infix
    )
  let implName = infix[1]
  let implStr = $implName
  let ifaceStr = $infix[2]

  result = newStmtList()

  var ctorParams: seq[NimNode] = @[] # user `new` params after the `T: typedesc`
  var userNew: NimNode = nil # the user-authored `proc new`, re-emitted verbatim
  var initBody: NimNode = nil # optional `proc init(self: Impl)` post-context body
  let postInitName = ident(implStr & "PostInit")
  # (verb, brokerName, argParams, payloadRepr, async)
  var methods: seq[(string, string, seq[NimNode], string, bool)] = @[]
  # (handlerName, signalTypeName, isVoid) — SignalBroker handler overrides.
  var signalMethods: seq[(string, string, bool)] = @[]

  # Signals this interface declares: (typeName, isVoid). A signal handler in the
  # body binds to one of these by NAME — method name `<Signal>` or `on<Signal>`
  # (the same name-based binding a RequestBroker verb uses), never by param type.
  let ifaceSignals = interfaceSignals(ifaceStr)

  for stmt in body:
    case stmt.kind
    of nnkProcDef:
      if baseName(stmt[0]).eqIdent("new"):
        if userNew != nil:
          macros.error("BrokerImplement: duplicate `new` ctor", stmt)
        let p = stmt.params
        # params: [returnType, T: typedesc[Impl], ...ctorArgs]; the user `new`
        # allocates and RETURNS a bare instance — no ctx, no providers.
        if p.len < 2:
          macros.error(
            "BrokerImplement `new` must take `T: typedesc[" & implStr &
              "]` as its first parameter",
            stmt,
          )
        for i in 2 ..< p.len: # skip return type (0) and the typedesc dispatcher (1)
          ctorParams.add(copyNimTree(p[i]))
        userNew = copyNimTree(stmt)
      elif baseName(stmt[0]).eqIdent("init"):
        # Optional post-context hook: runs AFTER `self.brokerCtx` is bound and
        # BEFORE providers are wired, so it may derive per-instance state from
        # `self.brokerCtx`. Written `proc init(self: Impl) = …` (explicit self).
        if initBody != nil:
          macros.error("BrokerImplement: duplicate `init` hook", stmt)
        let p = stmt.params
        if p.len != 2 or p[1].len != 3 or not p[1][1].eqIdent(implStr):
          macros.error(
            "BrokerImplement `init` must be `proc init(self: " & implStr & ")`", stmt
          )
        initBody = copyNimTree(stmt.body)
      else:
        macros.error(
          "BrokerImplement only allows `new` / `init` procs and `method` overrides",
          stmt,
        )
    of nnkMethodDef:
      let verb = $baseName(stmt[0])
      let p = stmt.params
      let ret = p[0]
      let async = isAsyncRet(ret)
      # SignalBroker handler: `Future[void]` return. Bound to a declared signal
      # by NAME — exactly like a RequestBroker verb binds to its `method`: the
      # method name must be the signal broker name `<Signal>` (exact) or
      # `on<Signal>`. NOT bound by parameter type. Emit a private `<name>Impl`
      # raw body (canonical signal-handler pragma) and record it for onSignal
      # wiring; the request path below is skipped.
      if isFutureVoid(ret):
        var sigTypeName = ""
        var sigVoid = false
        for (name, isVoidSig) in ifaceSignals:
          if verb == name or verb == "on" & name:
            sigTypeName = name
            sigVoid = isVoidSig
            break
        if sigTypeName.len == 0:
          macros.error(
            "signal handler `" & verb &
              "` (returns Future[void]) does not name any SignalBroker declared in " &
              ifaceStr & " — name it `<Signal>` or `on<Signal>`",
            stmt,
          )
        # Shape must match the signal's payload kind: a void (pulse) signal takes
        # no payload; a payload signal takes exactly one arg of the signal type.
        if sigVoid:
          if p.len != 2:
            macros.error(
              "signal handler `" & verb & "` for void (pulse) signal `" & sigTypeName &
                "` must take no payload: `method " & verb & "(self: " & implStr &
                "): Future[void]`",
              stmt,
            )
        else:
          if p.len != 3:
            macros.error(
              "signal handler `" & verb & "` for signal `" & sigTypeName &
                "` must take the payload: `method " & verb & "(self: " & implStr &
                ", s: " & sigTypeName & "): Future[void]`",
              stmt,
            )
          let paramType = p[2][^2].repr.strip()
          if paramType != sigTypeName:
            macros.error(
              "signal handler `" & verb & "` for signal `" & sigTypeName &
                "` must take a `" & sigTypeName & "` payload (got `" & paramType & "`)",
              stmt,
            )
        let sigImpl = nnkProcDef.newTree(
          ident(verb & "Impl"),
          newEmptyNode(),
          newEmptyNode(),
          copyNimTree(stmt.params),
          canonPragma(true), # {.async: (raises: []), gcsafe.}
          newEmptyNode(),
          copyNimTree(stmt.body),
        )
        result.add(sigImpl)
        for (_, existingSigType, _) in signalMethods:
          if existingSigType == sigTypeName:
            macros.error(
              "duplicate signal handler for '" & sigTypeName &
                "' (choose either `<Signal>` or `on<Signal>`)",
              stmt,
            )
        signalMethods.add((verb, sigTypeName, sigVoid))
        continue
      let payload = extractResultOk(ret, async)
      if payload.isNil:
        macros.error(
          "method `" & verb & "` must return " &
            (if async: "Future[Result[T, string]]" else: "Result[T, string]"),
          stmt,
        )
      # Emit the user's method body as a PRIVATE `<verb>Impl` proc — NOT a
      # virtual `method` override. The public entry point is the interface's
      # tunneling proc (`<Broker>.request(self.brokerCtx, …)`); the provider
      # closure below calls this raw `<verb>Impl` on the owning thread. This is
      # the only call site of the raw body, so a direct `instance.verb(…)` (or
      # `IFace(instance).verb(…)`) routes through the broker — honoring mocks,
      # MT cross-thread tunneling, and thread affinity — instead of bypassing it.
      let implProc = nnkProcDef.newTree(
        ident(verb & "Impl"), # private (unexported): broker-internal raw body
        newEmptyNode(),
        newEmptyNode(),
        copyNimTree(stmt.params),
        canonPragma(async),
        newEmptyNode(),
        copyNimTree(stmt.body),
      )
      result.add(implProc)
      var margs: seq[NimNode] = @[]
      for i in 2 ..< p.len: # skip return (0) and self (1)
        margs.add(copyNimTree(p[i]))
      methods.add((verb, capitalizeAscii(verb), margs, payload.repr.strip(), async))
    of nnkEmpty, nnkCommentStmt:
      discard
    else:
      macros.error(
        "BrokerImplement only allows `new` / `init` procs and `method` overrides", stmt
      )

  # Compile-time fulfillment check: every request verb declared in the
  # interface must have a corresponding method override in the implementation.
  let ifaceVerbs = interfaceRequestVerbs(ifaceStr)
  for (verb, typeName) in ifaceVerbs:
    var found = false
    for m in methods:
      if m[0] == verb:
        found = true
        break
    if not found:
      macros.error(
        "BrokerImplement " & implStr & ": missing method override for '" & verb &
          "' (request type " & typeName & ") declared in " & ifaceStr
      )

  # Same fulfillment check for signals: every SignalBroker declared in the
  # interface must have a `Future[void]` handler override (matched above).
  for (sig, isVoidSig) in ifaceSignals:
    var found = false
    for (handlerName, sigType, hVoid) in signalMethods:
      if sigType == sig:
        found = true
        break
    if not found:
      let hint =
        if isVoidSig:
          "method on" & sig & "(self: " & implStr & "): Future[void]"
        else:
          "method on" & sig & "(self: " & implStr & ", s: " & sig & "): Future[void]"
      macros.error(
        "BrokerImplement " & implStr & ": missing signal handler override for '" & sig &
          "' declared in " & ifaceStr & " (add `" & hint &
          " {.async: (raises: []), gcsafe.}`)"
      )

  let setupName = ident(implStr & "SetupProviders")

  # setupProviders — register a per-instance provider closure per request that
  # dispatches to the raw `<verb>Impl` body (capturing `self`). This is the only
  # call site of the raw body; the public entry point is the interface's
  # tunneling proc, so all calls route through the broker.
  var setupSrc = "proc " & $setupName & "(self: " & implStr & ") {.gcsafe.} =\n"
  if methods.len == 0 and signalMethods.len == 0:
    setupSrc.add("  discard\n")
  # Signal handlers: install the single per-instance handler that dispatches to
  # the raw `<name>Impl` body. The closure pragma matches the SignalBroker's
  # generated handler proc type (`{.async: (raises: []), gcsafe.}`). A void
  # (pulse) signal has a zero-arg handler; a payload signal takes `signalValue`.
  for (handlerName, sigType, isVoidSig) in signalMethods:
    if isVoidSig:
      setupSrc.add(
        "  discard " & sigType & ".onSignal(self.brokerCtx, proc(): Future[void] " &
          "{.async: (raises: []), gcsafe.} =\n    await self." & handlerName &
          "Impl())\n"
      )
    else:
      setupSrc.add(
        "  discard " & sigType & ".onSignal(self.brokerCtx, proc(signalValue: " & sigType &
          "): Future[void] {.async: (raises: []), gcsafe.} =\n    await self." &
          handlerName & "Impl(signalValue))\n"
      )
  for (verb, brokerName, margs, payload, async) in methods:
    var paramDecls = ""
    var argNames = ""
    for a in margs:
      paramDecls.add((if paramDecls.len > 0: ", " else: "") & a.repr.strip())
      for j in 0 ..< a.len - 2:
        argNames.add((if argNames.len > 0: ", " else: "") & $baseName(a[j]))
    let ret =
      if async:
        "Future[Result[" & payload & ", string]]"
      else:
        "Result[" & payload & ", string]"
    # Pragma must match the broker's generated provider proc type
    # (request_broker `makeProcType`): plain `{.async.}` for async,
    # `{.gcsafe, raises: [CatchableError].}` for sync.
    let prag = if async: "{.async.}" else: "{.gcsafe, raises: [CatchableError].}"
    let call = (if async: "await " else: "") & "self." & verb & "Impl(" & argNames & ")"
    setupSrc.add(
      "  discard " & brokerName & ".setProvider(self.brokerCtx, proc(" & paramDecls &
        "): " & ret & " " & prag & " =\n    " & call & ")\n"
    )
  result.add(parseStmt(setupSrc))

  # Constructor surface (the user authors a natural `proc new` that allocates +
  # returns a BARE instance; our generated wrappers decorate it with ctx binding
  # + provider wiring):
  #   * `Impl.new(args)`              — user-authored, re-emitted verbatim;
  #                                     bare instance, no ctx, no providers.
  #   * `Impl.createUnderContext(ctx, args)` — adopt an externally-supplied ctx
  #                                     (the FFI lib ctx, or a parent's sub-ctx).
  #   * `Impl.create(args)`           — allocate a fresh instance ctx, then
  #                                     decorate via createUnderContext.
  # If the user omits `new`, synthesize a zero-arg default.
  if userNew != nil:
    result.add(userNew)
  else:
    result.add(
      parseStmt(
        "proc new*(T: typedesc[" & implStr & "]): " & implStr & " = " & implStr & "()"
      )
    )

  # Optional post-context init hook, emitted as a private gcsafe proc invoked by
  # createUnderContext after `brokerCtx` is bound (so it may read self.brokerCtx).
  if initBody != nil:
    result.add(
      nnkProcDef.newTree(
        postInitName,
        newEmptyNode(),
        newEmptyNode(),
        nnkFormalParams.newTree(
          newEmptyNode(), newIdentDefs(ident("self"), copyNimTree(implName))
        ),
        nnkPragma.newTree(ident("gcsafe")),
        newEmptyNode(),
        initBody,
      )
    )

  # Forwarded ctor params: ", a: A, b: B" for signatures; "a, b" for the call.
  var ctorParamDecls = ""
  var ctorArgNames = ""
  for a in ctorParams:
    ctorParamDecls.add(", " & a.repr.strip())
    for j in 0 ..< a.len - 2:
      ctorArgNames.add((if ctorArgNames.len > 0: ", " else: "") & $baseName(a[j]))
  let newCallArgs = "(" & ctorArgNames & ")"
  let fwdArgs =
    if ctorArgNames.len > 0:
      ", " & ctorArgNames
    else:
      ""

  # createUnderContext() / create() MIRROR the user `new` constructor's result
  # shape, so a natural constructor of any of these four forms decorates
  # transparently (the wrapper unwraps `new` into a bare `self: T`, binds the
  # ctx, runs the optional PostInit hook, then wires providers via
  # SetupProviders — which never sees the Future/Result wrapper):
  #   proc new(...): T                              -> wrapper: T {.gcsafe.}
  #   proc new(...): Future[T] {.async.}            -> wrapper: Future[T] {.async.}
  #   proc new(...): Result[T, string]             -> wrapper: Result[T, string]
  #   proc new(...): Future[Result[T, string]] ...  -> Future[Result[T,string]] {.async.}
  # Sync forms stay `{.gcsafe.}` (the create-instance FFI path constructs
  # sub-instances inside a gcsafe request method body); async forms are
  # `{.async.}` (in-process). The sync-bare form is byte-identical to the legacy
  # codegen, so existing implementations are unaffected.
  let retNew =
    if userNew != nil:
      userNew.params[0]
    else:
      copyNimTree(implName)
  let newIsAsync = isAsyncRet(retNew)
  let newIsResult = not extractResultOk(retNew, newIsAsync).isNil
  # Real source location to stamp onto the async wrappers (see copyLineInfoRec).
  let ctorInfoSrc = if userNew != nil: userNew else: implName

  let wrapRet =
    if newIsAsync and newIsResult:
      "Future[Result[" & implStr & ", string]]"
    elif newIsAsync:
      "Future[" & implStr & "]"
    elif newIsResult:
      "Result[" & implStr & ", string]"
    else:
      implStr
  let wrapPrag = if newIsAsync: "{.async.}" else: "{.gcsafe.}"

  # Acquire the bare instance from `new`, unwrapping per shape into `self: T`.
  let acquireSelf =
    if newIsAsync and newIsResult:
      "  let self = (await T.new" & newCallArgs & ").valueOr:\n    return err(error)\n"
    elif newIsAsync:
      "  let self = await T.new" & newCallArgs & "\n"
    elif newIsResult:
      "  let self = T.new" & newCallArgs & ".valueOr:\n    return err(error)\n"
    else:
      "  let self = T.new" & newCallArgs & "\n"
  # Finish: yield the wired instance in the wrapper's result shape.
  let finishSelf =
    if newIsResult:
      "  return ok(self)\n"
    elif newIsAsync:
      "  return self\n"
    else:
      "  self\n"

  var cucSrc =
    "proc createUnderContext*(T: typedesc[" & implStr & "], ctx: BrokerContext" &
    ctorParamDecls & "): " & wrapRet & " " & wrapPrag & " =\n"
  cucSrc.add(acquireSelf)
  cucSrc.add("  self.brokerCtx = ctx\n")
  if initBody != nil:
    cucSrc.add("  " & $postInitName & "(self)\n")
  cucSrc.add("  " & $setupName & "(self)\n")
  cucSrc.add(finishSelf)
  let cucNode = parseStmt(cucSrc)
  if newIsAsync:
    copyLineInfoRec(cucNode, ctorInfoSrc)
  result.add(cucNode)

  # create() — allocate a per-instance ctx UNDER the ambient global scope, then
  # decorate. The classCtx is adopted from the current `globalBrokerContext()`
  # (read at call time), so a create'd instance lives in the same global scope
  # as the bare brokers / the locked test context — intentionally connecting
  # decoupled instances and bare brokers under one classCtx. The instanceCtx
  # comes from `newInstanceCtx`'s PROCESS-GLOBAL counter, so it stays unique
  # across all impl classes that share a classCtx (a per-class counter would
  # collide once the classCtx is shared). For an explicit/foreign scope, call
  # `createUnderContext(ctx, …)` directly.
  let cucCall =
    "T.createUnderContext(newInstanceCtx(globalBrokerContext())" & fwdArgs & ")"
  var createSrc =
    "proc create*(T: typedesc[" & implStr & "]" & ctorParamDecls & "): " & wrapRet & " " &
    wrapPrag & " =\n"
  createSrc.add((if newIsAsync: "  return await " else: "  ") & cucCall & "\n")
  let createNode = parseStmt(createSrc)
  if newIsAsync:
    copyLineInfoRec(createNode, ctorInfoSrc)
  result.add(createNode)

  # close() — clear this instance's providers (breaks the refc cycle) and free
  # its ctx. Idempotent.
  var closeSrc = "proc close*(self: " & implStr & ") =\n"
  closeSrc.add("  if self.brokerCtx == DefaultBrokerContext: return\n")
  for (verb, brokerName, margs, payload, async) in methods:
    closeSrc.add("  " & brokerName & ".clearProvider(self.brokerCtx)\n")
  # Drop this instance's signal handlers. dropSignalHandler is async but its body
  # is suspension-free, so a discarded Future still clears eagerly (mirrors the
  # event dropAllListeners handling below).
  for (handlerName, sigType, isVoidSig) in signalMethods:
    closeSrc.add("  discard " & sigType & ".dropSignalHandler(self.brokerCtx)\n")
  # B2: also drop this instance's event listeners. The interface published its
  # event types via the compile-time registry; guard with `when compiles` so it
  # works whether the event broker is single-thread / mt / API.
  for ev in interfaceEvents(ifaceStr):
    # dropAllListeners clears the listener table synchronously (before its first
    # await), so discarding the Future from sync close() still removes listeners;
    # only the in-flight-cancel await is abandoned (matches teardown semantics).
    closeSrc.add("  when compiles(" & ev & ".dropAllListeners(self.brokerCtx)):\n")
    closeSrc.add(
      "    when typeof(" & ev & ".dropAllListeners(self.brokerCtx)) is void:\n"
    )
    closeSrc.add("      " & ev & ".dropAllListeners(self.brokerCtx)\n")
    closeSrc.add("    else:\n")
    closeSrc.add("      discard " & ev & ".dropAllListeners(self.brokerCtx)\n")
  closeSrc.add("  self.brokerCtx = DefaultBrokerContext\n")
  result.add(parseStmt(closeSrc))

  when defined(brokerDebug):
    writeBrokerDebug("BrokerImplement", implStr, result, header = "of " & ifaceStr)
    when defined(brokerDebugStdout):
      echo result.repr

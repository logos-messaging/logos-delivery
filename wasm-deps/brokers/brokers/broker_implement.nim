## BrokerImplement — derived implementation of a BrokerInterface
## (doc/HIERARCHICAL_BROKERS_PLAN.md, phase P4).
##
##   type MyServiceImpl = ref object of IMyService
##     db: Database
##
##   BrokerImplement MyServiceImpl of IMyService:
##     proc init(db: Database) =      ## optional; `self` is the new instance
##       self.db = db
##     method getHealth(self: MyServiceImpl): Future[Result[GetHealth, string]] =
##       ok(GetHealth(...))           ## raw method overrides of the abstract base
##
## Generates: `MyServiceImpl.new(db = ...)` (allocates an instance brokerCtx and
## runs `init`), per-instance provider closures that dispatch each request to
## the overriding method (capturing `self`), and `close(self)` which clears
## those providers — breaking the instance<->closure cycle (mandatory under
## --mm:refc) and freeing the instance ctx for reuse.

import std/[macros, strutils, atomics]
import chronos, results
import ./broker_context
import ./request_broker, ./event_broker
import ./internal/helper/broker_utils

export chronos, results, broker_context, request_broker, event_broker

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

proc baseName(n: NimNode): NimNode {.compileTime.} =
  if n.kind == nnkPostfix:
    n[1]
  else:
    n

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

  var initParams: seq[NimNode] = @[] # extra new() params (after the typedesc)
  var initBody = newStmtList()
  # (verb, brokerName, argParams, payloadRepr, async)
  var methods: seq[(string, string, seq[NimNode], string, bool)] = @[]

  for stmt in body:
    case stmt.kind
    of nnkProcDef:
      if not baseName(stmt[0]).eqIdent("init"):
        macros.error(
          "BrokerImplement only allows an `init` proc and `method` overrides", stmt
        )
      let p = stmt.params
      for i in 1 ..< p.len: # skip return type
        initParams.add(copyNimTree(p[i]))
      initBody = copyNimTree(stmt.body)
    of nnkMethodDef:
      let verb = $baseName(stmt[0])
      let p = stmt.params
      let ret = p[0]
      let async = isAsyncRet(ret)
      let payload = extractResultOk(ret, async)
      if payload.isNil:
        macros.error(
          "method `" & verb & "` must return " &
            (if async: "Future[Result[T, string]]" else: "Result[T, string]"),
          stmt,
        )
      # Stamp the canonical override pragma and emit the method verbatim.
      var m = copyNimTree(stmt)
      m[4] = canonPragma(async)
      result.add(m)
      var margs: seq[NimNode] = @[]
      for i in 2 ..< p.len: # skip return (0) and self (1)
        margs.add(copyNimTree(p[i]))
      methods.add((verb, capitalizeAscii(verb), margs, payload.repr.strip(), async))
    of nnkEmpty, nnkCommentStmt:
      discard
    else:
      macros.error(
        "BrokerImplement only allows an `init` proc and `method` overrides", stmt
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

  # Per-class context allocation state.
  let classCtxVar = ident(implStr & "BrokerClassCtx")
  let instCounter = ident(implStr & "BrokerInstCounter")
  let setupName = ident(implStr & "SetupProviders")
  result.add(
    quote do:
      # classCtx allocated once at module init (immutable -> race-free and
      # gcsafe to read); per-instance instanceCtx from an atomic counter.
      let `classCtxVar` = newClassCtx()
      var `instCounter` {.global.}: Atomic[uint16]
  )

  # setupProviders — register a per-instance provider closure per request that
  # dispatches to the overriding method (capturing `self`).
  var setupSrc = "proc " & $setupName & "(self: " & implStr & ") {.gcsafe.} =\n"
  if methods.len == 0:
    setupSrc.add("  discard\n")
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
    let call = (if async: "await " else: "") & "self." & verb & "(" & argNames & ")"
    setupSrc.add(
      "  discard " & brokerName & ".setProvider(self.brokerCtx, proc(" & paramDecls &
        "): " & ret & " " & prag & " =\n    " & call & ")\n"
    )
  result.add(parseStmt(setupSrc))

  # new() — allocate the instance, its brokerCtx, run init, wire providers.
  var newFormal = nnkFormalParams.newTree(copyNimTree(implName))
  newFormal.add(
    newIdentDefs(
      ident("T"), nnkBracketExpr.newTree(ident("typedesc"), copyNimTree(implName))
    )
  )
  for p in initParams:
    newFormal.add(copyNimTree(p))
  # Build new()'s body as ONE flat scope so `self` is visible to the spliced
  # init body. `self` is interpolated as an explicit ident (quote would gensym
  # a literal `let self`, breaking the user's `self.field` references).
  let selfId = ident("self")
  var newBody = newStmtList()
  let pre = quote:
    let `selfId` = `implName`()
    `selfId`.brokerCtx =
      makeBrokerContext(`classCtxVar`, `instCounter`.fetchAdd(1'u16, moRelaxed) + 1'u16)
  for s in pre:
    newBody.add(s)
  for s in initBody:
    newBody.add(copyNimTree(s))
  let post = quote:
    `setupName`(`selfId`)
    `selfId`
  for s in post:
    newBody.add(copyNimTree(s))
  # A0: new() is gcsafe — the create-instance FFI path constructs sub-instances
  # in a gcsafe request method body (classCtx is an immutable `let`, instanceCtx
  # an atomic, setupProviders is gcsafe). Requires the impl's `init` body to be
  # gcsafe (trivial field writes always are). If a real in-process user needs a
  # non-gcsafe init, add a separate non-gcsafe constructor rather than relaxing
  # this.
  result.add(
    nnkProcDef.newTree(
      postfix(ident("new"), "*"),
      newEmptyNode(),
      newEmptyNode(),
      newFormal,
      nnkPragma.newTree(ident("gcsafe")),
      newEmptyNode(),
      newBody,
    )
  )

  # bindToContext() — construct an instance that ADOPTS an externally-supplied
  # brokerCtx (the FFI library context allocated by `<lib>_createContext`)
  # instead of allocating its own. Lets a BrokerInterface(API) impl serve as the
  # provider set for registerBrokerLibrary's `setupProviders(ctx)` (runs on the
  # processing thread → gcsafe). Wires providers keyed by `ctx`.
  var bindFormal = nnkFormalParams.newTree(copyNimTree(implName))
  bindFormal.add(
    newIdentDefs(
      ident("T"), nnkBracketExpr.newTree(ident("typedesc"), copyNimTree(implName))
    )
  )
  bindFormal.add(newIdentDefs(ident("ctx"), ident("BrokerContext")))
  for p in initParams:
    bindFormal.add(copyNimTree(p))
  var bindBody = newStmtList()
  let bindPre = quote:
    let `selfId` = `implName`()
    `selfId`.brokerCtx = ctx
  for s in bindPre:
    bindBody.add(s)
  for s in initBody:
    bindBody.add(copyNimTree(s))
  for s in post:
    bindBody.add(copyNimTree(s))
  result.add(
    nnkProcDef.newTree(
      postfix(ident("bindToContext"), "*"),
      newEmptyNode(),
      newEmptyNode(),
      bindFormal,
      nnkPragma.newTree(ident("gcsafe")),
      newEmptyNode(),
      bindBody,
    )
  )

  # close() — clear this instance's providers (breaks the refc cycle) and free
  # its ctx. Idempotent.
  var closeSrc = "proc close*(self: " & implStr & ") =\n"
  closeSrc.add("  if self.brokerCtx == DefaultBrokerContext: return\n")
  for (verb, brokerName, margs, payload, async) in methods:
    closeSrc.add("  " & brokerName & ".clearProvider(self.brokerCtx)\n")
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
    echo result.repr

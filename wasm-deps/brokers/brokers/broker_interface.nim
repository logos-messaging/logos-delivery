## BrokerInterface — an abstract, OOP-style facade over a group of Event /
## Request brokers (see doc/HIERARCHICAL_BROKERS_PLAN.md, phase P3).
##
## A `BrokerInterface` block declares the *contract*: the events it can emit
## and the requests it answers. It generates:
##   * a `ref object of RootObj` interface type carrying a hidden `brokerCtx`;
##   * the underlying Event/Request brokers (re-emitted verbatim, or lowered to
##     their `(API)` variants when the interface is declared `(API)`);
##   * one abstract `{.base.}` `method` per request (pure-virtual — raises
##     until a `BrokerImplement` derived type overrides it);
##   * a generic instance-scoped event facade (`self.emit` / `self.listen` /
##     `self.dropListener`) that injects `self.brokerCtx`.
##
## Invocation forms (note: `BrokerInterface(API) IFace:` does NOT parse in Nim —
## the `(API)` binds as a call; use the comma form instead):
##   BrokerInterface IFace:            ## or BrokerInterface(IFace):
##     EventBroker: ...
##     RequestBroker: ...
##   BrokerInterface(API, IFace):      ## (API) propagates to every sub-broker
##     EventBroker: ...
##     RequestBroker: ...
##
## Requests inside an interface use the proc-sugar form (a lowercase verb proc);
## the verb becomes the abstract method name a `BrokerImplement` overrides.

import std/[macros, strutils]
import chronos, results
import ./broker_context
import ./request_broker, ./event_broker
import ./internal/helper/broker_utils

export chronos, results, broker_context, request_broker, event_broker

proc isApiArg(n: NimNode): bool =
  n.kind == nnkIdent and n.eqIdent("API")

proc brokerHeadName(stmt: NimNode): string =
  ## The macro name a sub-block invokes (EventBroker / RequestBroker), or "".
  if stmt.kind notin {nnkCall, nnkCommand}:
    return ""
  let head = stmt[0]
  if head.kind == nnkIdent:
    return $head
  ""

proc renderAbstractMethod(
    ifaceName, verb, payloadRepr: string, argParams: seq[NimNode], async: bool
): string =
  ## Render an abstract base method as Nim source (parsed back via parseStmt —
  ## sidesteps fiddly pragma-AST construction for `async: (raises: [])`).
  var params = "self: " & ifaceName
  for p in argParams:
    params.add(", " & p.repr.strip())
  let ret =
    if async:
      "Future[Result[" & payloadRepr & ", string]]"
    else:
      "Result[" & payloadRepr & ", string]"
  let pragma =
    if async:
      "{.base, async: (raises: []), gcsafe.}"
    else:
      "{.base, gcsafe, raises: [].}"
  result =
    "method " & verb & "*(" & params & "): " & ret & " " & pragma & " =\n" &
    "  raiseAssert(\"" & ifaceName & "." & verb & " has no implementation\")\n"

macro BrokerInterface*(args: varargs[untyped]): untyped =
  ## See module docs. `args` is `[<API>?, <IFaceName>, <body>]` in any order for
  ## the leading idents, with the `:` block as the final argument.
  if args.len < 2:
    macros.error("BrokerInterface requires an interface name and a `:` body block")
  let body = args[^1]
  if body.kind != nnkStmtList:
    macros.error("BrokerInterface body must be a `:` block")

  var ifaceName: NimNode = nil
  var isApi = false
  for i in 0 ..< args.len - 1:
    if isApiArg(args[i]):
      isApi = true
    elif args[i].kind == nnkIdent:
      if ifaceName != nil:
        macros.error(
          "BrokerInterface: unexpected extra name `" & $args[i] & "`", args[i]
        )
      ifaceName = args[i]
    else:
      macros.error("BrokerInterface: unexpected argument", args[i])
  if ifaceName.isNil:
    macros.error("BrokerInterface requires an interface name", body)

  let ifaceNameStr = $ifaceName
  result = newStmtList()

  # 1. Interface ref type with the hidden context.
  result.add(
    quote do:
      type `ifaceName`* = ref object of RootObj
        brokerCtx*: BrokerContext

  )

  # 2. Walk the sub-blocks: re-emit each broker (lowered to `(API)` when the
  #    interface is `(API)`), and generate abstract methods for requests.
  var eventNames: seq[string] = @[]
  var requestTypes: seq[string] = @[] # sanitized request broker type names (A1)
  var requestVerbs: seq[(string, string)] = @[] # (verb, sanitized type name)
  for stmt in body:
    let headName = brokerHeadName(stmt)
    if headName notin ["EventBroker", "RequestBroker"]:
      macros.error(
        "BrokerInterface body may only contain `EventBroker:` / `RequestBroker:` blocks",
        stmt,
      )
    let innerBody = stmt[^1]
    if innerBody.kind != nnkStmtList:
      macros.error(
        headName & " inside BrokerInterface must have a `:` body block", stmt
      )
    let hasMode = stmt.len == 3 # nnkCall(Head, mode, body)

    # Re-emit the underlying broker.
    if isApi:
      if hasMode:
        macros.error(
          "BrokerInterface(API): sub-brokers must be plain `" & headName &
            ":` (the API mode is applied automatically)",
          stmt,
        )
      result.add(newCall(ident(headName), ident("API"), copyNimTree(innerBody)))
    else:
      result.add(copyNimTree(stmt))

    # Requests → abstract methods.
    if headName == "RequestBroker":
      let async = isApi or not (hasMode and stmt[1].eqIdent("sync"))
      let sg = parseRequestSugar(innerBody, "BrokerInterface RequestBroker", async)
      let payloadRepr = sg.payloadType.repr.strip()
      # Record the request broker type name (matches CborRequestEntry.
      # responseTypeName) so codegen can attribute the flat entry to this iface.
      requestTypes.add(sanitizeIdentName(sg.typeIdent))
      requestVerbs.add((sg.verb, sanitizeIdentName(sg.typeIdent)))
      if not sg.zeroArgProc.isNil:
        result.add(
          parseStmt(
            renderAbstractMethod(ifaceNameStr, sg.verb, payloadRepr, @[], async)
          )
        )
      if not sg.argProc.isNil:
        result.add(
          parseStmt(
            renderAbstractMethod(
              ifaceNameStr, sg.verb, payloadRepr, sg.argParams, async
            )
          )
        )
    elif headName == "EventBroker":
      # Record the event type so BrokerImplement.close() can drop listeners.
      let evParsed = parseSingleTypeDef(innerBody, "BrokerInterface EventBroker")
      eventNames.add($evParsed.typeIdent)

  # Publish this interface's event types for BrokerImplement teardown (B2).
  registerInterfaceEvents(ifaceNameStr, eventNames)

  # Publish this interface's request verbs for BrokerImplement fulfillment check.
  registerInterfaceVerbs(ifaceNameStr, requestVerbs)

  # A1: publish (API) interfaces to the compile-time registry so
  # registerBrokerLibrary can designate a main class and partition the per-
  # interface wrapper surface. Plain (non-API) interfaces are not FFI-exposed.
  if isApi:
    registerApiInterface(ifaceNameStr, requestTypes, eventNames)

  # 3. Generic instance-scoped event facade — forwards any event typedesc to
  #    the underlying ctx-based broker API using `self.brokerCtx`.
  result.add(
    quote do:
      template emit*(self: `ifaceName`, t: typedesc, args: varargs[untyped]): untyped =
        t.emit(self.brokerCtx, args)

      template listen*(self: `ifaceName`, t: typedesc, handler: untyped): untyped =
        t.listen(self.brokerCtx, handler)

      template dropListener*(self: `ifaceName`, t: typedesc, handle: untyped): untyped =
        t.dropListener(self.brokerCtx, handle)

  )

  # 4. Factory / dependency-injection. A consumer depends only on the interface
  #    module; an implementer installs a constructor via `provideFactory`
  #    (last wins) and the consumer obtains an instance via `create`. The
  #    factory may close over outer config, or take a typed config at call
  #    time. In-process the factory returns the real impl (direct virtual
  #    dispatch); the cross-runtime proxy variant is wired in P6.
  #    NOTE (P6): factory storage is a process-global here; cross-thread FFI use
  #    will harden it (lock + shared) when registerBrokerLibrary lands.
  let ifaceNameLit = newLit(ifaceNameStr)
  let facVar = ident(ifaceNameStr & "BrokerFactory")
  let facCfgVar = ident(ifaceNameStr & "BrokerFactoryCfg")
  result.add(
    quote do:
      var `facVar` {.global.}:
        proc(cfg: pointer): Result[`ifaceName`, string] {.raises: [].}
      var `facCfgVar` {.global.}: string

      proc provideFactory*(
          _: typedesc[`ifaceName`], f: proc(): Result[`ifaceName`, string]
      ) =
        `facCfgVar` = ""
        `facVar` = proc(cfg: pointer): Result[`ifaceName`, string] {.raises: [].} =
          try:
            f()
          except Exception as e:
            err(`ifaceNameLit` & " factory raised: " & e.msg)

      proc provideFactory*[A](
          _: typedesc[`ifaceName`], f: proc(cfg: A): Result[`ifaceName`, string]
      ) =
        `facCfgVar` = $A
        `facVar` = proc(cfg: pointer): Result[`ifaceName`, string] {.raises: [].} =
          try:
            f(cast[ptr A](cfg)[])
          except Exception as e:
            err(`ifaceNameLit` & " factory raised: " & e.msg)

      proc create*(_: typedesc[`ifaceName`]): Result[`ifaceName`, string] =
        if `facVar`.isNil:
          return err("no factory provided for " & `ifaceNameLit`)
        `facVar`(nil)

      proc create*[A](_: typedesc[`ifaceName`], cfg: A): Result[`ifaceName`, string] =
        if `facVar`.isNil:
          return err("no factory provided for " & `ifaceNameLit`)
        if `facCfgVar` != $A:
          return err(
            `ifaceNameLit` & " factory config type mismatch (got " & $A & ", expected " &
              `facCfgVar` & ")"
          )
        var c = cfg
        `facVar`(addr c)

  )

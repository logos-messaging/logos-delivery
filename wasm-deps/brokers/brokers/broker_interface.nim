## BrokerInterface — an abstract, OOP-style facade over a group of Event /
## Request brokers (see doc/design/HIERARCHICAL_BROKERS_PLAN.md, phase P3).
##
## A `BrokerInterface` block declares the *contract*: the events it can emit
## and the requests it answers. It generates:
##   * a `ref object of RootObj` interface type carrying a hidden `brokerCtx`;
##   * the underlying Event/Request brokers (re-emitted verbatim, or lowered to
##     their `(API)` variants when the interface is declared `(API)`);
##   * one public request `proc` per request verb that *tunnels* through the
##     broker (`<Broker>.request(self.brokerCtx, …)`) — so every call routes via
##     the broker dispatch path (provider interception / MT cross-thread
##     tunneling / thread affinity). The raw body is supplied by a
##     `BrokerImplement` derived type and runs only inside the provider closure;
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
## the verb becomes the public tunneling proc whose raw body a `BrokerImplement`
## supplies (as a private `<verb>Impl` proc invoked by the provider closure).

import std/[macros, strutils]
import chronos, results
import ./broker_context
import ./request_broker, ./event_broker, ./signal_broker
import ./internal/helper/broker_utils
import ./internal/broker_debug

export chronos, results, broker_context, request_broker, event_broker, signal_broker

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

proc renderRequestMethod(
    ifaceName, verb, payloadRepr: string, argParams: seq[NimNode], async: bool
): string =
  ## Render the interface's public request entry point as a plain proc that
  ## *tunnels* through the broker dispatch path:
  ## `<Broker>.request(self.brokerCtx, …)`. Routing is by ctx, so virtual
  ## dispatch is unnecessary — making this a proc (not a `{.base.}` method)
  ## keeps it cheap and, crucially, ensures provider interception (mocks),
  ## MT cross-thread tunneling, and thread affinity all apply uniformly. The
  ## raw implementation body runs only inside the provider closure (registered
  ## by BrokerImplement on the owning thread), never via a direct vtable call.
  ## (Rendered as source + parseStmt — sidesteps fiddly pragma-AST construction
  ## for `async: (raises: [])`.)
  let brokerName = capitalizeAscii(verb) # broker handle == capitalizeAscii(verb)
  var params = "self: " & ifaceName
  var argNames = ""
  for p in argParams:
    params.add(", " & p.repr.strip())
    for j in 0 ..< p.len - 2: # names are p[0 ..< len-2]; type/default trail
      argNames.add((if argNames.len > 0: ", " else: "") & $p[j])
  let ret =
    if async:
      "Future[Result[" & payloadRepr & ", string]]"
    else:
      "Result[" & payloadRepr & ", string]"
  let pragma =
    if async: "{.async: (raises: []), gcsafe.}" else: "{.gcsafe, raises: [].}"
  let callArgs =
    if argNames.len > 0:
      "self.brokerCtx, " & argNames
    else:
      "self.brokerCtx"
  let call = brokerName & ".request(" & callArgs & ")"
  result =
    "proc " & verb & "*(" & params & "): " & ret & " " & pragma & " =\n" &
    (if async: "  await " & call & "\n" else: "  " & call & "\n")

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
  var signalNames: seq[(string, bool)] = @[] # (SignalBroker type name, isVoid)
  var signalApiTypes: seq[string] = @[] # sanitized signal type names (A1, FFI)
  var requestTypes: seq[string] = @[] # sanitized request broker type names (A1)
  var requestVerbs: seq[(string, string)] = @[] # (verb, sanitized type name)
  for stmt in body:
    let headName = brokerHeadName(stmt)
    if headName notin ["EventBroker", "RequestBroker", "SignalBroker"]:
      macros.error(
        "BrokerInterface body may only contain `EventBroker:` / `RequestBroker:` / " &
          "`SignalBroker:` blocks",
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

    # Requests → public tunneling procs (raw body supplied by BrokerImplement).
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
          parseStmt(renderRequestMethod(ifaceNameStr, sg.verb, payloadRepr, @[], async))
        )
      if not sg.argProc.isNil:
        result.add(
          parseStmt(
            renderRequestMethod(ifaceNameStr, sg.verb, payloadRepr, sg.argParams, async)
          )
        )
    elif headName == "EventBroker":
      # Record the event type so BrokerImplement.close() can drop listeners.
      let evParsed = parseSingleTypeDef(innerBody, "BrokerInterface EventBroker")
      eventNames.add($evParsed.typeIdent)
    elif headName == "SignalBroker":
      # Record the signal type (+ void-ness) so BrokerImplement can install/drop
      # its handler with the right (zero-arg vs payload) shape.
      let sigParsed = parseSingleTypeDef(innerBody, "BrokerInterface SignalBroker")
      signalNames.add(($sigParsed.typeIdent, sigParsed.isVoid))
      # Sanitized name matches CborSignalEntry.typeName, so FFI wrapper codegen
      # can partition signals per interface (sub-interface signals -> sub class).
      signalApiTypes.add(sanitizeIdentName(sigParsed.typeIdent))

  # Publish this interface's event types for BrokerImplement teardown (B2).
  registerInterfaceEvents(ifaceNameStr, eventNames)

  # Publish this interface's signal types for BrokerImplement handler wiring.
  registerInterfaceSignals(ifaceNameStr, signalNames)

  # Publish this interface's request verbs for BrokerImplement fulfillment check.
  registerInterfaceVerbs(ifaceNameStr, requestVerbs)

  # A1: publish (API) interfaces to the compile-time registry so
  # registerBrokerLibrary can designate a main class and partition the per-
  # interface wrapper surface. Plain (non-API) interfaces are not FFI-exposed.
  if isApi:
    registerApiInterface(ifaceNameStr, requestTypes, eventNames, signalApiTypes)

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

  # Per-signal-type producer facade `self.signal(SigType, …)`. Generated one per
  # declared signal (not a generic template) so a void pulse gets a zero-arg
  # overload and a payload signal a varargs overload without the two colliding on
  # an empty argument list.
  for (sigName, sigVoid) in signalNames:
    if sigVoid:
      result.add(
        parseStmt(
          "template signal*(self: " & ifaceNameStr & ", _: typedesc[" & sigName &
            "]): untyped =\n  " & sigName & ".signal(self.brokerCtx)\n"
        )
      )
    else:
      result.add(
        parseStmt(
          "template signal*(self: " & ifaceNameStr & ", _: typedesc[" & sigName &
            "], args: varargs[untyped]): untyped =\n  " & sigName &
            ".signal(self.brokerCtx, args)\n"
        )
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

  when defined(brokerDebug):
    writeBrokerDebug("BrokerInterface", ifaceNameStr, result)
    when defined(brokerDebugStdout):
      echo result.repr

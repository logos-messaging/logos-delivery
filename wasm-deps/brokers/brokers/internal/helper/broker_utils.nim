import std/[macros, strutils]

type ParsedBrokerType* = object
  ## Result of parsing the single `type` definition inside a broker macro body.
  ##
  ## - `typeIdent`: base identifier for the declared type name
  ## - `objectDef`: exported type definition RHS (inline object fields exported;
  ##   non-object types wrapped in `distinct` unless already distinct)
  ## - `isRefObject`: true only for inline `ref object` definitions
  ## - `hasInlineFields`: true for inline `object` / `ref object`
  ## - `fieldNames`/`fieldTypes`: populated only when `collectFieldInfo = true`
  typeIdent*: NimNode
  objectDef*: NimNode
  isRefObject*: bool
  hasInlineFields*: bool
  isVoid*: bool ## true when the declared RHS is the bare `void` type
  fieldNames*: seq[NimNode]
  fieldTypes*: seq[NimNode]

proc toSnakeCase*(name: string): string {.compileTime.} =
  ## Converts PascalCase / camelCase to snake_case. Shared between the
  ## CBOR codegen surface and any kept compile-time helper that needs to
  ## derive a wire name from a Nim identifier.
  result = ""
  for i, ch in name:
    if ch in {'A' .. 'Z'}:
      if i > 0 and name[i - 1] notin {'A' .. 'Z', '_'}:
        result.add('_')
      result.add(chr(ord(ch) + 32))
    else:
      result.add(ch)

proc sanitizeIdentName*(node: NimNode): string =
  var raw = $node
  var sanitizedName = newStringOfCap(raw.len)
  for ch in raw:
    case ch
    of 'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_':
      sanitizedName.add(ch)
    else:
      sanitizedName.add('_')
  sanitizedName

proc ensureFieldDef*(node: NimNode) =
  if node.kind != nnkIdentDefs or node.len < 3:
    error("Expected field definition of the form `name: Type`", node)
  let typeSlot = node.len - 2
  if node[typeSlot].kind == nnkEmpty:
    error("Field `" & $node[0] & "` must declare a type", node)

proc exportIdentNode*(node: NimNode): NimNode =
  case node.kind
  of nnkIdent:
    postfix(copyNimTree(node), "*")
  of nnkPostfix:
    node
  else:
    error("Unsupported identifier form in field definition", node)

proc baseTypeIdent*(defName: NimNode): NimNode =
  case defName.kind
  of nnkIdent:
    defName
  of nnkAccQuoted:
    if defName.len != 1:
      error("Unsupported quoted identifier", defName)
    defName[0]
  of nnkPostfix:
    baseTypeIdent(defName[1])
  of nnkPragmaExpr:
    baseTypeIdent(defName[0])
  else:
    error("Unsupported type name in broker definition", defName)

proc ensureDistinctType*(rhs: NimNode): NimNode =
  ## For PODs / aliases / externally-defined types, wrap in `distinct` unless
  ## it's already distinct.
  if rhs.kind == nnkDistinctTy:
    return copyNimTree(rhs)
  newTree(nnkDistinctTy, copyNimTree(rhs))

proc cloneParams*(params: seq[NimNode]): seq[NimNode] =
  ## Deep copy parameter definitions so they can be inserted in multiple places.
  result = @[]
  for param in params:
    result.add(copyNimTree(param))

proc collectParamNames*(params: seq[NimNode]): seq[NimNode] =
  ## Extract all identifier symbols declared across IdentDefs nodes.
  result = @[]
  for param in params:
    assert param.kind == nnkIdentDefs
    for i in 0 ..< param.len - 2:
      let nameNode = param[i]
      if nameNode.kind == nnkEmpty:
        continue
      result.add(ident($nameNode))

proc parseOneTypeDef(
    def: NimNode,
    macroName: string,
    allowRefToNonObject = false,
    collectFieldInfo = false,
): ParsedBrokerType =
  ## Parse a single nnkTypeDef node into a ParsedBrokerType.
  ## Internal helper used by both parseSingleTypeDef and parseTypeDefs.
  var fieldNames: seq[NimNode] = @[]
  var fieldTypes: seq[NimNode] = @[]

  let typeIdent = baseTypeIdent(def[0])
  let rhs = def[2]
  var objectDef: NimNode
  var isRefObject = false
  var hasInlineFields = false
  var isVoid = false

  case rhs.kind
  of nnkObjectTy:
    let recList = rhs[2]
    if recList.kind != nnkRecList:
      error(macroName & " object must declare a standard field list", rhs)
    var exportedRecList = newTree(nnkRecList)
    for field in recList:
      case field.kind
      of nnkIdentDefs:
        ensureFieldDef(field)
        if collectFieldInfo:
          let fieldTypeNode = field[field.len - 2]
          for i in 0 ..< field.len - 2:
            let baseFieldIdent = baseTypeIdent(field[i])
            fieldNames.add(copyNimTree(baseFieldIdent))
            fieldTypes.add(copyNimTree(fieldTypeNode))
        var cloned = copyNimTree(field)
        for i in 0 ..< cloned.len - 2:
          cloned[i] = exportIdentNode(cloned[i])
        exportedRecList.add(cloned)
      of nnkEmpty:
        discard
      else:
        error(
          macroName & " object definition only supports simple field declarations",
          field,
        )
    objectDef =
      newTree(nnkObjectTy, copyNimTree(rhs[0]), copyNimTree(rhs[1]), exportedRecList)
    isRefObject = false
    hasInlineFields = true
  of nnkRefTy:
    if rhs.len != 1:
      error(macroName & " ref type must have a single base", rhs)
    if rhs[0].kind == nnkObjectTy:
      let obj = rhs[0]
      let recList = obj[2]
      if recList.kind != nnkRecList:
        error(macroName & " object must declare a standard field list", obj)
      var exportedRecList = newTree(nnkRecList)
      for field in recList:
        case field.kind
        of nnkIdentDefs:
          ensureFieldDef(field)
          if collectFieldInfo:
            let fieldTypeNode = field[field.len - 2]
            for i in 0 ..< field.len - 2:
              let baseFieldIdent = baseTypeIdent(field[i])
              fieldNames.add(copyNimTree(baseFieldIdent))
              fieldTypes.add(copyNimTree(fieldTypeNode))
          var cloned = copyNimTree(field)
          for i in 0 ..< cloned.len - 2:
            cloned[i] = exportIdentNode(cloned[i])
          exportedRecList.add(cloned)
        of nnkEmpty:
          discard
        else:
          error(
            macroName & " object definition only supports simple field declarations",
            field,
          )
      let exportedObjectType =
        newTree(nnkObjectTy, copyNimTree(obj[0]), copyNimTree(obj[1]), exportedRecList)
      objectDef = newTree(nnkRefTy, exportedObjectType)
      isRefObject = true
      hasInlineFields = true
    elif allowRefToNonObject:
      ## `ref SomeType` (SomeType can be defined elsewhere)
      objectDef = ensureDistinctType(rhs)
      isRefObject = false
      hasInlineFields = false
    else:
      error(macroName & " ref object must wrap a concrete object definition", rhs)
  elif rhs.kind == nnkIdent and rhs.eqIdent("void"):
    ## `void` — a payload-less broker. The bare `void` type cannot name a
    ## broker (every `void` broker would share `typedesc[void]`, colliding
    ## the generated `request` / `setProvider` / `emit` overloads). It is
    ## therefore lowered to a *unique* empty `object` — a unit type — so
    ## each broker keeps a distinct identity. `isVoid` lets broker macros
    ## drop the now-meaningless value parameter from handler / emit
    ## signatures; the request payload is simply the zero-field object.
    objectDef =
      newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), newTree(nnkRecList))
    isRefObject = false
    hasInlineFields = false
    isVoid = true
  else:
    ## Non-object type / alias.
    objectDef = ensureDistinctType(rhs)
    isRefObject = false
    hasInlineFields = false

  result = ParsedBrokerType(
    typeIdent: typeIdent,
    objectDef: objectDef,
    isRefObject: isRefObject,
    hasInlineFields: hasInlineFields,
    isVoid: isVoid,
    fieldNames: fieldNames,
    fieldTypes: fieldTypes,
  )

proc parseTypeDefs*(
    body: NimNode,
    macroName: string,
    allowRefToNonObject = false,
    collectFieldInfo = false,
): seq[ParsedBrokerType] =
  ## Parses all `type` definitions from a broker macro body.
  ## Returns them in declaration order. Supports multiple types in a single
  ## broker block (e.g. supporting types + primary type).
  ##
  ## Callers are responsible for identifying which entry is the "primary" type
  ## (typically the last one, or the one referenced in the signature return type).
  result = @[]
  for stmt in body:
    if stmt.kind != nnkTypeSection:
      continue
    for def in stmt:
      if def.kind != nnkTypeDef:
        continue
      result.add(parseOneTypeDef(def, macroName, allowRefToNonObject, collectFieldInfo))

  if result.len == 0:
    error(macroName & " body must declare at least one type", body)

proc parseSingleTypeDef*(
    body: NimNode,
    macroName: string,
    allowRefToNonObject = false,
    collectFieldInfo = false,
): ParsedBrokerType =
  ## Parses exactly one `type` definition from a broker macro body.
  ## Backward-compatible wrapper around parseTypeDefs that enforces a single type.
  ##
  ## Supported RHS:
  ## - inline `object` / `ref object` (fields are auto-exported)
  ## - non-object types / aliases / externally-defined types (wrapped in `distinct`)
  ## - optionally: `ref SomeType` when `allowRefToNonObject = true`
  let defs = parseTypeDefs(body, macroName, allowRefToNonObject, collectFieldInfo)
  if defs.len > 1:
    error("Only one type may be declared inside " & macroName, body)
  result = defs[0]

# ---------------------------------------------------------------------------
# RequestBroker proc-style sugar (option B — payload decoupled from the
# dispatch tag). Shared by the single-thread, multi-thread, and API
# RequestBroker generators so the surface stays identical across flavors.
# ---------------------------------------------------------------------------

type ParsedRequestSugar* = object
  ## Result of parsing the new proc-style RequestBroker sugar.
  ## - `typeIdent`  : the dispatch-tag type (broker name).
  ## - `objectDef`  : RHS to declare for the tag (the object for the object
  ##                  form, `distinct payload` for the POD form).
  ## - `payloadType`: the value type returned by `request` (decoupled — raw
  ##                  payload for POD, == typeIdent for the object form).
  ## - `fieldTypes` : object field types (object form) for MT auto-config;
  ##                  empty for POD.
  ## - `zeroArgProc`/`argProc`: the parsed signature proc defs (nil if absent).
  ## - `argParams`  : IdentDefs of the arg-based signature.
  typeIdent*: NimNode
  objectDef*: NimNode
  payloadType*: NimNode
  fieldTypes*: seq[NimNode]
  zeroArgProc*: NimNode
  argProc*: NimNode
  argParams*: seq[NimNode]
  verb*: string
    ## The (lowercase) signature verb — the BrokerInterface method name that
    ## `BrokerImplement` overrides (e.g. `getHealth`).
  parsed*: ParsedBrokerType
    ## Full parse of the dispatch tag over the payload — drives the API/CBOR
    ## schema registration identically to the legacy `type X = ...` path.

proc extractResultOk*(returnType: NimNode, async: bool): NimNode =
  ## Ok payload type T from `Future[Result[T, string]]` (async) or
  ## `Result[T, string]` (sync). Returns nil if the shape is invalid (error
  ## type must be `string`). FFI/in-process errors are pinned to `string`.
  if async:
    if returnType.kind != nnkBracketExpr or returnType.len != 2:
      return nil
    if returnType[0].kind != nnkIdent or not returnType[0].eqIdent("Future"):
      return nil
    let inner = returnType[1]
    if inner.kind != nnkBracketExpr or inner.len != 3:
      return nil
    if inner[0].kind != nnkIdent or not inner[0].eqIdent("Result"):
      return nil
    if not (inner[2].kind == nnkIdent and inner[2].eqIdent("string")):
      return nil
    return inner[1]
  else:
    if returnType.kind != nnkBracketExpr or returnType.len != 3:
      return nil
    if returnType[0].kind != nnkIdent or not returnType[0].eqIdent("Result"):
      return nil
    if not (returnType[2].kind == nnkIdent and returnType[2].eqIdent("string")):
      return nil
    return returnType[1]

proc sugarVerbIdent(p: NimNode): NimNode =
  let nm = p[0]
  if nm.kind == nnkPostfix:
    nm[1]
  else:
    nm

proc parseRequestSugar*(
    body: NimNode, macroName: string, async: bool
): ParsedRequestSugar =
  ## Parse the proc-style sugar form of a RequestBroker body (one broker per
  ## block, two signature slots, payload decoupled from the dispatch tag).
  var typeDecl: NimNode = nil
  var procs: seq[NimNode] = @[]
  for stmt in body:
    case stmt.kind
    of nnkProcDef:
      procs.add(stmt)
    of nnkTypeSection:
      for d in stmt:
        if d.kind == nnkTypeDef:
          if typeDecl != nil:
            error(macroName & " sugar allows a single payload type", d)
          typeDecl = d
    of nnkEmpty:
      discard
    else:
      error("Unsupported statement inside " & macroName & " definition", stmt)
  if procs.len == 0:
    error(macroName & " requires at least one signature proc", body)

  var verb = ""
  for p in procs:
    if verb.len == 0:
      verb = $sugarVerbIdent(p)
    elif not sugarVerbIdent(p).eqIdent(verb):
      error("All signatures in one " & macroName & " block must share the proc name", p)
  let brokerName = capitalizeAscii(verb)
  result.verb = verb

  if typeDecl != nil:
    let parsedT = parseSingleTypeDef(
      newTree(nnkStmtList, newTree(nnkTypeSection, typeDecl)),
      macroName,
      allowRefToNonObject = true,
      collectFieldInfo = true,
    )
    result.typeIdent = parsedT.typeIdent
    result.objectDef = parsedT.objectDef
    result.fieldTypes = parsedT.fieldTypes
    result.parsed = parsedT
    if not result.typeIdent.eqIdent(brokerName):
      error(
        "Signature `" & verb & "` must pair with type `" & brokerName & "` (got `" &
          $result.typeIdent & "`)",
        typeDecl,
      )
    result.payloadType = copyNimTree(result.typeIdent)
  else:
    # POD form: the broker name is derived solely from the proc verb and is
    # always Capitalized (it is a Nim type / dispatch tag). Warn when we had to
    # capitalize a lowercase verb so the `Broker.request(...)` handle name is
    # not a surprise; writing the proc Capitalized (`proc GetConfig(...)`) is
    # accepted and silences this.
    if verb.len > 0 and verb[0] in {'a' .. 'z'}:
      warning(
        "RequestBroker: broker name is `" & brokerName & "` (capitalized from proc `" &
          verb & "`); call it as `" & brokerName & ".request(...)`. Write `proc " &
          brokerName & "(...)` to name it explicitly and silence this warning.",
        procs[0],
      )
    result.typeIdent = ident(brokerName)

  for p in procs:
    let params = p.params
    if params.len == 0:
      error("Signature must declare a return type", p)
    let pl = extractResultOk(params[0], async)
    if pl.isNil:
      error(
        "Signature must return " &
          (if async: "Future[Result[T, string]]" else: "Result[T, string]"),
        p,
      )
    if result.payloadType.isNil:
      result.payloadType = copyNimTree(pl)
    elif result.payloadType.repr != pl.repr:
      error(
        "All signatures of broker `" & brokerName & "` must return the same payload type",
        p,
      )
    let paramCount = params.len - 1
    if paramCount == 0:
      if not result.zeroArgProc.isNil:
        error("Only one zero-argument signature is allowed", p)
      result.zeroArgProc = p
    else:
      if not result.argProc.isNil:
        error("Only one argument-based signature is allowed", p)
      result.argProc = p
      result.argParams = @[]
      for idx in 1 ..< params.len:
        let pd = params[idx]
        if pd.kind != nnkIdentDefs:
          error("Signature parameter must be a standard identifier declaration", pd)
        if pd[pd.len - 2].kind == nnkEmpty:
          error("Signature parameter must declare a type", pd)
        result.argParams.add(copyNimTree(pd))

  if typeDecl == nil:
    # POD: synthesize `type <tag> = <payload>` and parse it through the normal
    # path so the dispatch-tag classification (primitive / void / distinct) and
    # the API/CBOR schema registration match the legacy `type X = ...` form.
    let synth = newTree(
      nnkStmtList,
      newTree(
        nnkTypeSection,
        newTree(
          nnkTypeDef,
          copyNimTree(result.typeIdent),
          newEmptyNode(),
          copyNimTree(result.payloadType),
        ),
      ),
    )
    result.parsed = parseSingleTypeDef(
      synth, macroName, allowRefToNonObject = true, collectFieldInfo = true
    )
    result.objectDef = result.parsed.objectDef

# ---------------------------------------------------------------------------
# Compile-time interface -> event-type registry. BrokerInterface records the
# event types it declares; BrokerImplement reads them so the generated
# `close()` can drop the instance's event listeners (the impl macro otherwise
# doesn't know the interface's events).
# ---------------------------------------------------------------------------

var gInterfaceEvents {.compileTime.}: seq[(string, seq[string])] = @[]

proc registerInterfaceEvents*(iface: string, events: seq[string]) {.compileTime.} =
  for i in 0 ..< gInterfaceEvents.len:
    if gInterfaceEvents[i][0] == iface:
      gInterfaceEvents[i][1] = events
      return
  gInterfaceEvents.add((iface, events))

proc interfaceEvents*(iface: string): seq[string] {.compileTime.} =
  for it in gInterfaceEvents:
    if it[0] == iface:
      return it[1]
  @[]

# ---------------------------------------------------------------------------
# Compile-time registry of interface request verbs.
# Records, per interface, the verb name and the associated request type name.
# Used by BrokerImplement to validate that all declared requests are overridden.
# ---------------------------------------------------------------------------

var gInterfaceVerbs {.compileTime.}: seq[(string, seq[(string, string)])] = @[]

proc registerInterfaceVerbs*(
    iface: string, verbs: seq[(string, string)]
) {.compileTime.} =
  for i in 0 ..< gInterfaceVerbs.len:
    if gInterfaceVerbs[i][0] == iface:
      gInterfaceVerbs[i] = (iface, verbs)
      return
  gInterfaceVerbs.add((iface, verbs))

proc interfaceRequestVerbs*(iface: string): seq[(string, string)] {.compileTime.} =
  for it in gInterfaceVerbs:
    if it[0] == iface:
      return it[1]
  @[]

# ---------------------------------------------------------------------------
# Compile-time registry of `BrokerInterface(API)` interfaces (reduced-A, A1).
# Records, per interface, the sanitized request *type* names and event *type*
# names it owns. The flat CBOR request/event entry registries store these same
# type names (CborRequestEntry.responseTypeName / CborEventEntry.typeName), so
# wrapper codegen can partition the flat entry lists per interface by matching
# on type name — no need to replicate the snake/suffix apiName derivation here.
# ---------------------------------------------------------------------------

type ApiInterfaceEntry* = object
  name*: string
  requestTypes*: seq[string] ## sanitized request broker type names
  eventTypes*: seq[string] ## event payload type names

var gApiInterfaces {.compileTime.}: seq[ApiInterfaceEntry] = @[]

proc registerApiInterface*(
    name: string, requestTypes, eventTypes: seq[string]
) {.compileTime.} =
  for i in 0 ..< gApiInterfaces.len:
    if gApiInterfaces[i].name == name:
      gApiInterfaces[i].requestTypes = requestTypes
      gApiInterfaces[i].eventTypes = eventTypes
      return
  gApiInterfaces.add(
    ApiInterfaceEntry(name: name, requestTypes: requestTypes, eventTypes: eventTypes)
  )

proc apiInterfaces*(): seq[ApiInterfaceEntry] {.compileTime.} =
  gApiInterfaces

proc isApiInterface*(name: string): bool {.compileTime.} =
  for it in gApiInterfaces:
    if it.name == name:
      return true
  false

proc interfaceOwningRequestType*(typeName: string): string {.compileTime.} =
  ## Comma-joined names of every interface that declared the request broker
  ## `typeName` (more than one when two interfaces reuse the same type name —
  ## itself the most common apiName collision), or "" if none.
  var owners: seq[string] = @[]
  for it in gApiInterfaces:
    for rt in it.requestTypes:
      if rt == typeName:
        owners.add(it.name)
  owners.join(", ")

proc interfaceOwningEventType*(typeName: string): string {.compileTime.} =
  var owners: seq[string] = @[]
  for it in gApiInterfaces:
    for et in it.eventTypes:
      if et == typeName:
        owners.add(it.name)
  owners.join(", ")

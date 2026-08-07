## api_type_resolver
## -----------------
## Two-phase external type introspection for FFI API broker macros.
##
## When a broker macro encounters a reference to an external type (e.g.
## `seq[DeviceInfo]` where `DeviceInfo` is a plain Nim type defined outside
## the macro body), this module resolves its fields at compile time and
## registers it in the API schema.
##
## ## Mechanism
##
## Phase 1 (called from an `untyped` broker macro):
##   `discoverExternalTypes(body)` scans the raw AST for type identifiers
##   that are not Nim primitives. Returns ident nodes.
##
## Phase 2 (typed macro expansion):
##   `autoRegisterApiType(T: typed)` receives a resolved type symbol,
##   calls `getTypeImpl()` to extract its fields, recursively resolves
##   nested object types, and registers everything in `gApiTypeRegistry`.
##
## ## Supported type kinds
##
## - `object` types — field introspection and CItem generation
## - `enum` types — value extraction and C enum generation
## - `distinct` types — base type resolution and C typedef generation
## - Type aliases — base type resolution and C typedef generation

{.push raises: [].}

import std/[macros, strutils]
import ./api_schema

export api_schema

# ---------------------------------------------------------------------------
# Phase 2: Typed macro that resolves a single external type
# ---------------------------------------------------------------------------

proc resolveActualSym(T: NimNode): NimNode {.compileTime.} =
  ## Get the actual type symbol regardless of how T was passed.
  ## Handles both typedesc[X] (from typed parameter) and direct symbols
  ## (from recursive calls within the typed phase).
  let impl = getTypeImpl(T)
  case impl.kind
  of nnkBracketExpr:
    # `typedesc[X]` (from a typed parameter) -> return X. But a bracket can also
    # be an array/seq/Option type the symbol resolves to (`type Hash = array[32,
    # byte]`): its `[1]` is a range/element, NOT a type symbol — `T` itself is the
    # symbol to register, so don't unwrap.
    if impl.len >= 2 and impl[0].kind == nnkSym and $impl[0] == "typeDesc":
      impl[1]
    else:
      T
  of nnkObjectTy:
    # Already resolved; T itself is the symbol
    T
  of nnkEnumTy:
    T
  of nnkDistinctTy:
    T
  of nnkSym:
    T
  else:
    nil

proc extractFieldsFromSym(sym: NimNode): seq[(string, string)] {.compileTime.} =
  ## Extract (fieldName, fieldTypeName) from a type symbol.
  ##
  ## Prefer the AS-WRITTEN definition (`getImpl`) so field types keep their
  ## source spelling — `Option[Timestamp]`, `seq[WakuMessageHash]` — and the
  ## codegen can resolve those registered alias names. `getTypeImpl` returns the
  ## structurally-resolved object, whose `repr` leaks `Option[CompiledIntTypes]`
  ## for an int-alias inside `Option`, and renames structurally-identical array
  ## aliases (`Option[WakuMessageHash]` -> `Option[Curve25519Key]`). Fall back to
  ## `getTypeImpl` when no impl AST is available.
  var obj: NimNode = nil
  let implNode = getImpl(sym)
  if implNode != nil and implNode.kind == nnkTypeDef and implNode.len == 3:
    let rhs = implNode[2]
    if rhs.kind == nnkObjectTy:
      obj = rhs
  if obj.isNil:
    let typeImpl = getTypeImpl(sym)
    obj =
      if typeImpl.kind == nnkObjectTy:
        typeImpl
      elif typeImpl.kind == nnkBracketExpr and typeImpl.len >= 2:
        getTypeImpl(typeImpl[1])
      else:
        nil

  if obj.isNil or obj.kind != nnkObjectTy:
    return @[]

  let recList = obj[2]
  if recList.kind != nnkRecList:
    return @[]

  for field in recList:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[field.len - 2]
    if fieldType.kind == nnkEmpty:
      continue
    for i in 0 ..< field.len - 2:
      # `getImpl` keeps the as-written field name, so an exported field arrives
      # as `nnkPostfix(*, ident)` and a pragma-annotated one as `nnkPragmaExpr`;
      # unwrap to the bare identifier. `getTypeImpl` yielded a plain sym, so this
      # is a no-op on the fallback path.
      var nameNode = field[i]
      if nameNode.kind == nnkPragmaExpr and nameNode.len >= 1:
        nameNode = nameNode[0]
      if nameNode.kind == nnkPostfix and nameNode.len == 2:
        nameNode = nameNode[1]
      if nameNode.kind == nnkEmpty:
        continue
      result.add(($nameNode, repr(fieldType)))

proc extractEnumValues(sym: NimNode): seq[(string, int)] {.compileTime.} =
  ## Walk nnkEnumTy children to get (name, ordinal) pairs.
  let typeImpl = getTypeImpl(sym)
  let enumTy =
    if typeImpl.kind == nnkEnumTy:
      typeImpl
    elif typeImpl.kind == nnkBracketExpr and typeImpl.len >= 2:
      getTypeImpl(typeImpl[1])
    else:
      nil

  if enumTy.isNil or enumTy.kind != nnkEnumTy:
    return @[]

  var ordinal = 0
  for i in 1 ..< enumTy.len: # skip first child (empty node)
    let child = enumTy[i]
    case child.kind
    of nnkSym:
      result.add(($child, ordinal))
      inc ordinal
    of nnkEnumFieldDef:
      let fieldName = $child[0]
      let fieldVal = int(child[1].intVal)
      result.add((fieldName, fieldVal))
      ordinal = fieldVal + 1
    else:
      discard

const tuplePositionalNames* =
  ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"]
  ## Synthesised field names for unnamed positional tuple elements.
  ## Tuples with more than 9 positional elements are rejected by the FFI
  ## generator — wrap them in a named `object` instead.

proc extractFieldsFromTupleSym(sym: NimNode): seq[(string, string)] {.compileTime.} =
  ## Extract `(fieldName, fieldTypeName)` pairs from a resolved tuple type
  ## symbol. Named tuples like `tuple[key: Key, payload: seq[byte]]` use the
  ## declared field names verbatim. Unnamed positional tuples up to 9
  ## elements receive synthesised names from `tuplePositionalNames`.
  let typeImpl = getTypeImpl(sym)
  let tupleTy = if typeImpl.kind == nnkTupleTy: typeImpl else: nil
  if tupleTy.isNil:
    return @[]

  var posIdx = 0
  for child in tupleTy:
    if child.kind == nnkIdentDefs:
      let typeNode = child[child.len - 2]
      for i in 0 ..< child.len - 2:
        let rawName = $child[i]
        result.add((rawName, typeNode.repr.strip()))
    else:
      if posIdx >= tuplePositionalNames.len:
        error(
          "FFI tuple support is limited to 9 positional fields; got element " &
            $(posIdx + 1) & " of tuple " & $sym & ". Wrap in a named object instead.",
          sym,
        )
      result.add((tuplePositionalNames[posIdx], child.repr.strip()))
      inc posIdx

proc collectNestedTypeNodesFromTuple(sym: NimNode): seq[NimNode] {.compileTime.} =
  ## Tuple-shaped analogue of `collectNestedTypeNodes` — walks a resolved
  ## tuple type's fields and returns NimNodes for any nested custom types
  ## (object / enum / distinct / alias / seq[Custom] / array[N, Custom])
  ## that need recursive registration.
  let typeImpl = getTypeImpl(sym)
  let tupleTy = if typeImpl.kind == nnkTupleTy: typeImpl else: nil
  if tupleTy.isNil:
    return @[]

  proc handleFieldType(fieldType: NimNode, acc: var seq[NimNode]) =
    if fieldType.kind == nnkSym and not isNimPrimitive($fieldType):
      let innerImpl = getTypeImpl(fieldType)
      if innerImpl.kind in {nnkObjectTy, nnkEnumTy, nnkDistinctTy, nnkTupleTy}:
        acc.add(fieldType)
      else:
        let instName = $getTypeInst(fieldType)
        if instName != $fieldType and not isNimPrimitive(instName):
          acc.add(fieldType)
    elif fieldType.kind == nnkBracketExpr and fieldType.len >= 2 and
        $fieldType[0] == "seq":
      let elemSym = fieldType[1]
      if elemSym.kind == nnkSym and not isNimPrimitive($elemSym):
        let elemImpl = getTypeImpl(elemSym)
        if elemImpl.kind in {nnkObjectTy, nnkEnumTy, nnkTupleTy, nnkDistinctTy}:
          acc.add(elemSym)
    elif fieldType.kind == nnkBracketExpr and fieldType.len == 3 and
        $fieldType[0] == "array":
      let elemSym = fieldType[2]
      if elemSym.kind == nnkSym and not isNimPrimitive($elemSym):
        let elemImpl = getTypeImpl(elemSym)
        if elemImpl.kind in {nnkObjectTy, nnkEnumTy, nnkTupleTy, nnkDistinctTy}:
          acc.add(elemSym)

  for child in tupleTy:
    if child.kind == nnkIdentDefs:
      let typeNode = child[child.len - 2]
      handleFieldType(typeNode, result)
    else:
      handleFieldType(child, result)

proc resolveAliasBase(sym: NimNode): string {.compileTime.} =
  ## Follows alias/distinct chains to the underlying primitive name.
  let typeImpl = getTypeImpl(sym)
  if typeImpl.kind == nnkDistinctTy:
    let base = typeImpl[0]
    # `$` panics on non-symbol nodes (e.g. nnkBracketExpr for
    # `distinct seq[byte]`); `repr` accepts any AST shape and yields
    # the same printable form for symbols.
    return base.repr.strip()
  # For aliases, getTypeInst gives us the target
  let typeInst = getTypeInst(sym)
  if typeInst.kind == nnkBracketExpr and typeInst.len >= 2:
    return typeInst[1].repr.strip()
  if typeInst.kind == nnkSym:
    return $typeInst
  return sym.repr.strip()

proc validateTableKey(keySym: NimNode, fieldName, ownerName: string) {.compileTime.} =
  ## Reject Table key types that cannot round-trip across the FFI text-key
  ## wire. Allowed: string / int8..64 / char (primitives), enum, and
  ## distinct whose base resolves to one of those. Everything else
  ## (plain int/uint, bool, float, object, tuple, seq, ...) is a hard error.
  let where = "field '" & fieldName & "' of '" & ownerName & "'"
  if keySym.kind != nnkSym:
    error(
      "Table key in " & where & " must be a scalar type; got composite '" &
        keySym.repr.strip() & "'. Supported keys: string, int8/16/32/64, char, " &
        "enum, or a distinct of those.",
      keySym,
    )
  let keyName = $keySym
  if isNimPrimitive(keyName):
    if not isAllowedTableKeyPrimitive(keyName):
      error(
        "Table key type '" & keyName & "' in " & where & " is not supported. " &
          "Use string, int8/16/32/64, char, enum, or a distinct of those " &
          "(plain int/uint, bool and float are excluded — see " &
          "doc/design/ASSOC_CONTAINERS_PLAN.md).",
        keySym,
      )
    return
  let impl = getTypeImpl(keySym)
  case impl.kind
  of nnkEnumTy:
    discard # enum keys travel as symbol names
  of nnkDistinctTy:
    let base = resolveAliasBase(keySym)
    if not isAllowedTableKeyPrimitive(base):
      let baseImpl = getTypeImpl(impl[0])
      if baseImpl.kind != nnkEnumTy:
        error(
          "Table key '" & keyName & "' in " & where & " is a distinct of '" & base &
            "', which is not a supported key scalar. Supported bases: " &
            "string, int8/16/32/64, char, enum.",
          keySym,
        )
  else:
    error(
      "Table key type '" & keyName & "' in " & where &
        "' is not a supported scalar/enum/distinct key.",
      keySym,
    )

proc collectIfCustom(node: NimNode, acc: var seq[NimNode]) {.compileTime.} =
  ## Collect `node` (and, for containers, its element) for recursive
  ## registration when it's a non-primitive type the codegen needs a schema
  ## entry for: an object/enum/distinct/tuple, a primitive- or array-alias, or a
  ## `seq[T]` / `array[N, T]` / `Option[T]` whose element is one of those.
  if node.kind == nnkSym and not isNimPrimitive($node):
    let impl = getTypeImpl(node)
    case impl.kind
    of nnkObjectTy, nnkEnumTy, nnkTupleTy, nnkDistinctTy:
      acc.add(node)
    of nnkSym:
      # Alias to a primitive / another named type (`ContentTopic = string`,
      # `Epoch = int64`). Register when the resolved base differs from the name.
      if impl.repr.strip() != $node:
        acc.add(node)
    of nnkBracketExpr:
      # Alias to a container, esp. `array[N, byte]` (`WakuMessageHash`,
      # `Curve25519Key`). Register so seq[X]/Option[X] resolve through it.
      acc.add(node)
    else:
      discard
  elif node.kind == nnkBracketExpr and node.len >= 2:
    let head = $node[0]
    if head == "seq" or head == "Option":
      collectIfCustom(node[^1], acc)
    elif head == "array" and node.len == 3:
      collectIfCustom(node[2], acc)

proc collectNestedTypeNodes(sym: NimNode): seq[NimNode] {.compileTime.} =
  ## Walk the fields of a type symbol and return NimNodes for any nested custom
  ## types (incl. `seq`/`array`/`Option` elements) that need recursive
  ## registration. Uses `getImpl` (as-written field types) to stay consistent
  ## with `extractFieldsFromSym`, so the names collected here match the field
  ## type strings the codegen later resolves.
  var obj: NimNode = nil
  let implNode = getImpl(sym)
  if implNode != nil and implNode.kind == nnkTypeDef and implNode.len == 3 and
      implNode[2].kind == nnkObjectTy:
    obj = implNode[2]
  if obj.isNil:
    let typeImpl = getTypeImpl(sym)
    obj =
      if typeImpl.kind == nnkObjectTy:
        typeImpl
      elif typeImpl.kind == nnkBracketExpr and typeImpl.len >= 2:
        getTypeImpl(typeImpl[1])
      else:
        nil

  if obj.isNil or obj.kind != nnkObjectTy:
    return @[]

  let recList = obj[2]
  if recList.kind != nnkRecList:
    return @[]

  for field in recList:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[field.len - 2]
    if fieldType.kind == nnkEmpty:
      continue

    # Table[K, V] — validate the key first, then collect K and V.
    if fieldType.kind == nnkBracketExpr and fieldType.len == 3 and
        $fieldType[0] == "Table":
      let ownerName = $sym
      var nameNode = field[0]
      if nameNode.kind == nnkPostfix and nameNode.len == 2:
        nameNode = nameNode[1]
      let fieldName = (if nameNode.kind in {nnkSym, nnkIdent}: $nameNode
      else: "?")
      validateTableKey(fieldType[1], fieldName, ownerName)
      collectIfCustom(fieldType[1], result)
      collectIfCustom(fieldType[2], result)
    else:
      collectIfCustom(fieldType, result)

macro autoRegisterApiType*(T: typed): untyped =
  ## Phase 2: Receives a resolved type symbol, extracts fields,
  ## recursively processes nested types, registers in the schema,
  ## and generates CItem type + encode proc + C/C++/Python codegen.
  ##
  ## Handles object types (full CItem generation), enum types (C enum
  ## generation), and alias/distinct types (C typedef generation).
  result = newStmtList()

  let actualSym = resolveActualSym(T)
  if actualSym.isNil:
    return result

  let typeName = $actualSym
  if isTypeRegistered(typeName) or isNimPrimitive(typeName):
    return result

  let typeImpl = getTypeImpl(actualSym)

  # Check for enum types
  block checkEnum:
    let enumTy =
      if typeImpl.kind == nnkEnumTy:
        typeImpl
      elif typeImpl.kind == nnkBracketExpr and typeImpl.len >= 2:
        let inner = getTypeImpl(typeImpl[1])
        if inner.kind == nnkEnumTy: inner else: nil
      else:
        nil
    if not enumTy.isNil:
      let values = extractEnumValues(actualSym)
      var apiValues: seq[ApiEnumValue] = @[]
      for (name, ordinal) in values:
        apiValues.add(ApiEnumValue(name: name, ordinal: ordinal))
      registerTypeEntry(makeEnumEntry(typeName, apiValues))
      return result

  # Check for distinct types
  if typeImpl.kind == nnkDistinctTy:
    let baseName = resolveAliasBase(actualSym)
    registerTypeEntry(makeAliasEntry(typeName, baseName, atkDistinct))
    return result

  # Check for alias types (sym that resolves to another sym/primitive)
  block checkAlias:
    let typeInst = getTypeInst(actualSym)
    if typeInst.kind == nnkBracketExpr and typeInst.len >= 2:
      let targetName = $typeInst[1]
      if targetName != typeName:
        registerTypeEntry(makeAliasEntry(typeName, targetName, atkAlias))
        return result

  # Simple alias to a primitive or another named type: `type ContentTopic =
  # string`, `type Timestamp = int64`, including alias-of-alias chains.
  # `getTypeImpl` resolves fully through the chain to the underlying symbol
  # (`getTypeInst` only echoes the alias's own name, so it cannot be used here).
  if typeImpl.kind == nnkSym:
    let baseName = typeImpl.repr.strip()
    if baseName != typeName:
      registerTypeEntry(makeAliasEntry(typeName, baseName, atkAlias))
    return result

  # Array alias: `type WakuMessageHash = array[32, byte]` (also Curve25519Key,
  # Hash32). `getTypeImpl` yields the `array[lo..hi, T]` bracket; register it as
  # an alias whose underlying is the as-written `array[N, T]` (via `getImpl`) so
  # the per-language mapper resolves `seq[X]` / `Option[X]` through it.
  if typeImpl.kind == nnkBracketExpr and typeImpl.len >= 1 and typeImpl[0].kind == nnkSym and
      $typeImpl[0] == "array":
    let impl = getImpl(actualSym)
    let underlying =
      if impl != nil and impl.kind == nnkTypeDef and impl.len == 3:
        impl[2].repr.strip()
      else:
        typeImpl.repr.strip()
    registerTypeEntry(makeAliasEntry(typeName, underlying, atkAlias))
    return result

  # Tuple types — register as a synthesised object so the CBOR codegen
  # modules (which iterate `gApiTypeRegistry` for `atkObject` entries)
  # pick the tuple up and emit struct definitions. Named tuples keep
  # their declared field names; unnamed positional tuples up to 9
  # elements receive `first`..`ninth`.
  #
  # Note: we deliberately DO NOT call `generateApiType` here. That path
  # emits a fixed-layout `<Name>CItem` for the native ABI which has no
  # count-companion field for `seq[T]` members — so a tuple like
  # `tuple[a: Key, b: seq[byte]]` cannot fit. Native-ABI tuple support
  # belongs to a follow-up task; for now the CBOR-mode codegen runs off
  # the schema entry alone, and the native codegen sees an object with
  # a missing CItem and falls back to its own TODO emission for
  # downstream wrappers (which is what existing native-uncovered shapes
  # like `seq[Object<seq>]` already do).
  if typeImpl.kind == nnkTupleTy:
    let tupleFields = extractFieldsFromTupleSym(actualSym)
    if tupleFields.len == 0:
      return result
    let nestedNodesT = collectNestedTypeNodesFromTuple(actualSym)
    for nestedSym in nestedNodesT:
      let nestedName = $nestedSym
      if not isTypeRegistered(nestedName) and not isNimPrimitive(nestedName):
        result.add(newCall(ident("autoRegisterApiType"), nestedSym))
    registerFromFieldTuples(typeName, tupleFields)
    # Bind a map-shaped CBOR encoder/decoder so the wire matches the
    # named struct that wrappers emit for the same tuple type. The
    # default `write[T: tuple]` in cbor_serialization writes positional
    # CBOR arrays which decode wrappers reject as "expected map".
    result.add(newCall(ident("bindCborTupleMap"), actualSym))
    return result

  # Object types — existing behavior
  let fields = extractFieldsFromSym(actualSym)
  if fields.len == 0:
    return result

  # Emit recursive calls for nested types (depth-first: dependencies first)
  let nestedNodes = collectNestedTypeNodes(actualSym)
  for nestedSym in nestedNodes:
    let nestedName = $nestedSym
    if not isTypeRegistered(nestedName) and not isNimPrimitive(nestedName):
      result.add(newCall(ident("autoRegisterApiType"), nestedSym))

  # Register this type in the schema; CBOR codegen reads gApiTypeRegistry.
  registerFromFieldTuples(typeName, fields)

# ---------------------------------------------------------------------------
# Phase 1: Scan untyped AST for external type references
# ---------------------------------------------------------------------------

proc scanTypeNode(ft: NimNode, result: var seq[NimNode]) {.compileTime.} =
  ## Check a single type node for external type references.
  ## Adds ident nodes for `seq[T]` / `array[N, T]` / `Option[T]` / `Table[K, V]`
  ## elements (recursively) and plain custom types.
  if ft.kind == nnkEmpty:
    return
  # seq[T] / Option[T] — recurse into the element so `Option[Alias]`,
  # `seq[Option[T]]`, `seq[seq[T]]` all surface their custom element.
  if ft.kind == nnkBracketExpr and ft.len >= 2 and
      ($ft[0] == "seq" or $ft[0] == "Option"):
    scanTypeNode(ft[^1], result)
  # array[N, T]
  elif ft.kind == nnkBracketExpr and ft.len == 3 and $ft[0] == "array":
    scanTypeNode(ft[2], result)
  # Table[K, V] — scan both key and value so enum/distinct keys and custom
  # value types (including seq[Custom]/array[N, Custom]) get registered.
  elif ft.kind == nnkBracketExpr and ft.len == 3 and $ft[0] == "Table":
    scanTypeNode(ft[1], result)
    scanTypeNode(ft[2], result)
  # Plain custom type
  elif ft.kind in {nnkIdent, nnkSym} and not isNimPrimitive($ft):
    result.add(ft)

proc discoverExternalTypes*(body: NimNode): seq[NimNode] {.compileTime.} =
  ## Scan an untyped macro body for references to external types.
  ## Returns ident nodes for each type that needs resolution.
  ##
  ## Detects:
  ## - `seq[T]` fields in type definitions where T is not a primitive
  ## - `array[N, T]` fields where T is not a primitive
  ## - Plain custom type fields (`field: CustomType`)
  ## - Type aliases (`type MyEvent = ExternalType`)
  ## - `seq[T]` and custom types in proc signature parameters
  var seen: seq[string] = @[]

  # Types DEFINED in this body (a coupled broker's own `type X = object`). The
  # return-type scan must skip them: the broker's own type is registered by
  # registerCborObjectType, and emitting an autoRegisterApiType for it here would
  # reference the symbol before it is declared in the expansion.
  var localTypes: seq[string] = @[]
  for stmt in body:
    if stmt.kind == nnkTypeSection:
      for def in stmt:
        if def.kind != nnkTypeDef:
          continue
        var nameNode = def[0]
        if nameNode.kind == nnkPragmaExpr and nameNode.len >= 1:
          nameNode = nameNode[0]
        if nameNode.kind == nnkPostfix and nameNode.len == 2:
          nameNode = nameNode[1]
        if nameNode.kind in {nnkIdent, nnkSym}:
          localTypes.add($nameNode)

  for stmt in body:
    if stmt.kind == nnkTypeSection:
      for def in stmt:
        if def.kind != nnkTypeDef:
          continue
        let rhs = def[2]

        if rhs.kind == nnkObjectTy:
          # Inline object: scan fields
          let recList = rhs[2]
          if recList.kind != nnkRecList:
            continue
          for field in recList:
            if field.kind != nnkIdentDefs:
              continue
            let ft = field[field.len - 2]
            scanTypeNode(ft, result)
        elif rhs.kind == nnkIdent:
          # Type alias: `type MyEvent = ExternalType`
          let aliasTarget = $rhs
          if not isNimPrimitive(aliasTarget):
            result.add(rhs)
    elif stmt.kind == nnkProcDef:
      let params = stmt.params
      # params[0] is the RETURN type. For a proc-sugar broker the response
      # payload lives there (`Future[Result[StoreQueryResponse, string]]`), so it
      # must be scanned too — otherwise an object returned only via proc-sugar
      # never registers. Unwrap Future[...] then Result[T, E] and scan T.
      if params.len > 0:
        var ret = params[0]
        if ret.kind == nnkBracketExpr and ret.len >= 2 and $ret[0] == "Future":
          ret = ret[1]
        if ret.kind == nnkBracketExpr and ret.len >= 2 and $ret[0] == "Result":
          let payload = ret[1]
          # Skip the broker's own coupled type (registered elsewhere); scan only
          # an external payload (the proc-sugar case).
          if not (payload.kind in {nnkIdent, nnkSym} and $payload in localTypes):
            scanTypeNode(payload, result)
      # Scan proc signature parameters for external types.
      for i in 1 ..< params.len:
        let paramDef = params[i]
        if paramDef.kind == nnkIdentDefs:
          let ft = paramDef[paramDef.len - 2]
          scanTypeNode(ft, result)

  # Deduplicate (keep first occurrence)
  var deduped: seq[NimNode] = @[]
  for node in result:
    let name = $node
    if name notin seen:
      seen.add(name)
      deduped.add(node)
  result = deduped

proc emitAutoRegistrations*(externalIdents: seq[NimNode]): NimNode {.compileTime.} =
  ## Generate `autoRegisterApiType(Ident)` calls for discovered external types.
  ## These compile as typed macro invocations, triggering Phase 2 resolution.
  result = newStmtList()
  for typeIdent in externalIdents:
    result.add(newCall(ident("autoRegisterApiType"), typeIdent))

{.pop.}

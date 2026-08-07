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
    # typedesc[X] -> return X
    if impl.len >= 2:
      impl[1]
    else:
      nil
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
  ## Extract (fieldName, fieldTypeName) from a resolved type symbol.
  let typeImpl = getTypeImpl(sym)
  let obj =
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
      if field[i].kind == nnkEmpty:
        continue
      result.add(($field[i], repr(fieldType)))

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

proc collectNestedTypeNodes(sym: NimNode): seq[NimNode] {.compileTime.} =
  ## Walk the fields of a resolved type symbol and return NimNodes for
  ## any nested custom object types or seq[T] element types that need
  ## recursive registration.
  let typeImpl = getTypeImpl(sym)
  let obj =
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

    # Direct custom object field (e.g. `address: Address`)
    if fieldType.kind == nnkSym and not isNimPrimitive($fieldType):
      let innerImpl = getTypeImpl(fieldType)
      if innerImpl.kind == nnkObjectTy:
        result.add(fieldType)
      elif innerImpl.kind == nnkEnumTy:
        result.add(fieldType)
      elif innerImpl.kind == nnkDistinctTy:
        result.add(fieldType)
      elif innerImpl.kind == nnkTupleTy:
        result.add(fieldType)
      else:
        # Could be an alias — check if it resolves to something different
        let instName = $getTypeInst(fieldType)
        if instName != $fieldType and not isNimPrimitive(instName):
          result.add(fieldType)

    # seq[T] where T is a custom type (e.g. `devices: seq[DeviceInfo]`)
    elif fieldType.kind == nnkBracketExpr and fieldType.len >= 2 and
        $fieldType[0] == "seq":
      let elemSym = fieldType[1]
      if elemSym.kind == nnkSym and not isNimPrimitive($elemSym):
        let elemImpl = getTypeImpl(elemSym)
        if elemImpl.kind in {nnkObjectTy, nnkEnumTy, nnkTupleTy, nnkDistinctTy}:
          result.add(elemSym)

    # array[N, T] where T is a custom type
    elif fieldType.kind == nnkBracketExpr and fieldType.len == 3 and
        $fieldType[0] == "array":
      let elemSym = fieldType[2]
      if elemSym.kind == nnkSym and not isNimPrimitive($elemSym):
        let elemImpl = getTypeImpl(elemSym)
        if elemImpl.kind in {nnkObjectTy, nnkEnumTy, nnkTupleTy, nnkDistinctTy}:
          result.add(elemSym)

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
  ## Adds ident nodes for `seq[T]`, `array[N, T]`, and plain custom types.
  if ft.kind == nnkEmpty:
    return
  # seq[T]
  if ft.kind == nnkBracketExpr and ft.len >= 2 and $ft[0] == "seq":
    let elemName = $ft[1]
    if not isNimPrimitive(elemName):
      result.add(ft[1])
  # array[N, T]
  elif ft.kind == nnkBracketExpr and ft.len == 3 and $ft[0] == "array":
    let elemName = $ft[2]
    if not isNimPrimitive(elemName):
      result.add(ft[2])
  # Plain custom type
  elif ft.kind == nnkIdent and not isNimPrimitive($ft):
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
      # Scan proc signature parameters for external types
      let params = stmt.params
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

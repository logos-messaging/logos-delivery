## api_schema
## ----------
## Compile-time type registry for FFI API code generation.
##
## This module provides a language-neutral schema that broker macros populate
## and codegen modules consume. It supports objects, enums, type aliases,
## and distinct types as first-class citizens.
##
## The registry stores type information for types used across the FFI boundary,
## needed for encoding/decoding, C/C++ header generation, and nested type
## marshalling.

{.push raises: [].}

import std/[macros, strutils]

type
  ApiTypeKind* = enum ## Discriminator for registered types.
    atkObject ## Plain or ref object with fields
    atkEnum ## Nim enum type
    atkAlias ## Type alias (e.g. `type Timestamp = int64`)
    atkDistinct ## Distinct type (e.g. `type MyId = distinct int32`)

  ApiEnumValue* = object ## A single value in an enum type.
    name*: string
    ordinal*: int

  ApiFieldDef* = object ## A single field in a type definition.
    name*: string
    nimType*: string ## "int64", "string", "bool", "seq[DeviceInfo]", etc.
    isSeq*: bool ## true when nimType starts with "seq["
    seqElementType*: string ## e.g. "DeviceInfo" when isSeq
    isArray*: bool ## true when nimType is "array[N, T]"
    arraySize*: int ## e.g. 3 for array[3, int32]
    arrayElementType*: string ## e.g. "int32" for array[3, int32]
    isCustomObject*: bool ## true when type resolves to an object (not primitive)

  ApiTypeEntry* = object ## A registered type in the FFI schema.
    name*: string ## "DeviceInfo"
    kind*: ApiTypeKind ## What kind of type this is
    fields*: seq[ApiFieldDef] ## field definitions (for atkObject)
    enumValues*: seq[ApiEnumValue] ## enum values (for atkEnum)
    underlyingType*: string ## base type (for atkAlias/atkDistinct)

# ---------------------------------------------------------------------------
# Compile-time type registry
# ---------------------------------------------------------------------------

var gApiTypeRegistry* {.compileTime.}: seq[ApiTypeEntry] = @[]
  ## All types registered for FFI code generation.
  ## Populated by auto-resolution (api_type_resolver) or legacy ApiType macro.
  ## Consumed by codegen modules when processing seq[T] fields.

# ---------------------------------------------------------------------------
# Primitive type detection
# ---------------------------------------------------------------------------

const nimPrimitiveTypes* = [
  "string", "cstring", "char", "bool", "int", "int8", "int16", "int32", "int64", "uint",
  "uint8", "uint16", "uint32", "uint64", "float", "float32", "float64", "byte",
]

proc isNimPrimitive*(typeName: string): bool {.compileTime.} =
  ## Returns true if `typeName` is a built-in Nim primitive type.
  typeName.toLowerAscii() in nimPrimitiveTypes

# ---------------------------------------------------------------------------
# Registry operations
# ---------------------------------------------------------------------------

proc isTypeRegistered*(name: string): bool {.compileTime.} =
  ## Check if a type is already in the registry.
  for entry in gApiTypeRegistry:
    if entry.name == name:
      return true
  false

proc lookupTypeEntry*(name: string): ApiTypeEntry {.compileTime.} =
  ## Lookup a type entry by name. Returns the entry or triggers a compile error.
  for entry in gApiTypeRegistry:
    if entry.name == name:
      return entry
  error(
    "Type '" & name & "' not registered in FFI schema. " &
      "Define it as a plain Nim type before using it in a broker macro, " &
      "or declare it with `ApiType:` for explicit registration."
  )

proc lookupTypeFields*(name: string): seq[(string, string)] {.compileTime.} =
  ## Backward-compatible lookup returning (fieldName, nimTypeName) tuples.
  ## This is the drop-in replacement for the old `lookupFfiStruct()`.
  let entry = lookupTypeEntry(name)
  for field in entry.fields:
    result.add((field.name, field.nimType))

proc registerTypeEntry*(entry: ApiTypeEntry) {.compileTime.} =
  ## Register a type in the schema. Skips if already registered.
  if not isTypeRegistered(entry.name):
    gApiTypeRegistry.add(entry)

# ---------------------------------------------------------------------------
# Query helpers for type kinds
# ---------------------------------------------------------------------------

proc isEnumRegistered*(name: string): bool {.compileTime.} =
  ## Returns true if the name is registered as an enum type.
  for entry in gApiTypeRegistry:
    if entry.name == name and entry.kind == atkEnum:
      return true
  false

proc isAliasOrDistinctRegistered*(name: string): bool {.compileTime.} =
  ## Returns true if the name is registered as an alias or distinct type.
  for entry in gApiTypeRegistry:
    if entry.name == name and entry.kind in {atkAlias, atkDistinct}:
      return true
  false

proc resolveUnderlyingType*(name: string): string {.compileTime.} =
  ## Follows alias/distinct chains to the final underlying type name.
  ## Returns the name itself if not registered as alias/distinct.
  var current = name
  var depth = 0
  while depth < 20: # safety limit
    var found = false
    for entry in gApiTypeRegistry:
      if entry.name == current and entry.kind in {atkAlias, atkDistinct}:
        current = entry.underlyingType
        found = true
        break
    if not found:
      break
    inc depth
  current

# ---------------------------------------------------------------------------
# Type node inspection helpers
# ---------------------------------------------------------------------------

proc isSeqOfPrimitive*(nimType: NimNode): bool {.compileTime.} =
  ## Returns true when nimType is `seq[T]` and T is a primitive type.
  if nimType.kind == nnkBracketExpr and nimType.len == 2 and
      ($nimType[0]).toLowerAscii() == "seq":
    let elemName = $nimType[1]
    return isNimPrimitive(elemName)
  false

proc isArrayType*(nimType: NimNode): bool {.compileTime.} =
  ## Returns true if the type node represents `array[N, T]`.
  nimType.kind == nnkBracketExpr and nimType.len == 3 and
    ($nimType[0]).toLowerAscii() == "array"

proc arraySize*(nimType: NimNode): int {.compileTime.} =
  ## Extracts N from `array[N, T]`. Expects an int literal.
  assert isArrayType(nimType)
  if nimType[1].kind == nnkIntLit:
    int(nimType[1].intVal)
  else:
    error("array size must be an integer literal for FFI codegen", nimType[1])

proc arrayElemTypeName*(nimType: NimNode): string {.compileTime.} =
  ## Extracts the element type name from `array[N, T]`.
  assert isArrayType(nimType)
  $nimType[2]

# ---------------------------------------------------------------------------
# Field construction helpers
# ---------------------------------------------------------------------------

proc makeFieldDef*(name, nimType: string): ApiFieldDef {.compileTime.} =
  ## Construct an ApiFieldDef from name and type strings.
  result.name = name
  result.nimType = nimType
  let lower = nimType.toLowerAscii()
  if lower.startsWith("seq[") and lower.endsWith("]"):
    result.isSeq = true
    result.seqElementType = nimType[4 ..^ 2] # strip "seq[" and "]"
  elif lower.startsWith("array["):
    # Parse "array[N, T]" format
    let inner = nimType[6 ..^ 2] # strip "array[" and "]"
    let commaPos = inner.find(',')
    if commaPos >= 0:
      result.isArray = true
      try:
        result.arraySize = parseInt(inner[0 ..< commaPos].strip())
      except ValueError:
        result.arraySize = 0
      result.arrayElementType = inner[commaPos + 1 .. ^1].strip()
  if not isNimPrimitive(nimType) and not result.isSeq and not result.isArray:
    result.isCustomObject = true

proc makeTypeEntry*(
    name: string, fields: seq[ApiFieldDef], kind: ApiTypeKind = atkObject
): ApiTypeEntry {.compileTime.} =
  ## Construct an ApiTypeEntry for an object type.
  result.name = name
  result.kind = kind
  result.fields = fields

proc makeEnumEntry*(
    name: string, values: seq[ApiEnumValue]
): ApiTypeEntry {.compileTime.} =
  ## Construct an ApiTypeEntry for an enum type.
  result.name = name
  result.kind = atkEnum
  result.enumValues = values

proc makeAliasEntry*(
    name: string, underlyingType: string, kind: ApiTypeKind = atkAlias
): ApiTypeEntry {.compileTime.} =
  ## Construct an ApiTypeEntry for an alias or distinct type.
  result.name = name
  result.kind = kind
  result.underlyingType = underlyingType

# ---------------------------------------------------------------------------
# Backward compatibility: bridge to old registration format
# ---------------------------------------------------------------------------

proc registerFromFieldTuples*(
    typeName: string, fields: seq[(string, string)]
) {.compileTime.} =
  ## Register a type from (fieldName, nimTypeName) tuples.
  ## Used by the legacy ApiType macro and during migration.
  if isTypeRegistered(typeName):
    return
  var fieldDefs: seq[ApiFieldDef] = @[]
  for (fname, ftype) in fields:
    fieldDefs.add(makeFieldDef(fname, ftype))
  registerTypeEntry(makeTypeEntry(typeName, fieldDefs))

{.pop.}

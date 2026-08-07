## api_cbor_tables
## ---------------
## Self-contained CBOR codec for `Table[K, V]` / `OrderedTable[K, V]` that
## needs **no change** to the `cbor_serialization` dependency.
##
## `cbor_serialization` derives a type's wire format from user-defined
## `write` / `read` hooks discovered via `mixin`. This module provides those
## hooks for Table using only the library's PUBLIC `reader` / `writer` API, so
## the dependency stays at its upstream release. It deliberately replaces the
## library's own `cbor_serialization/std/tables` binding (which we do NOT
## import) — that binding only knows how to convert int/float/string keys.
##
## Keys travel as CBOR text strings (major type 3):
##   - string  -> itself
##   - int8..64 -> decimal text (range-checked on read)
##   - char    -> 1-character text
##   - enum    -> its ordinal as text (matches the int-backed enum repr that
##                foreign wrappers use)
##   - distinct of any of the above -> the base scalar's text form
##
## Plain platform-width `int` and `float` keys are intentionally NOT exposed
## across the FFI surface (platform-dependent width / non-hashable in Rust);
## see doc/design/ASSOC_CONTAINERS_PLAN.md. They are rejected earlier, at the
## schema layer (api_type_resolver.validateTableKey).

{.push raises: [], gcsafe.}

import std/[strutils, typetraits]
import stew/shims/tables
import cbor_serialization/[reader, writer]

export tables

type TableType = OrderedTable | Table

func keyToStr[K](key: K): string =
  ## Render a Table key as the CBOR map's text key.
  when K is distinct:
    keyToStr(distinctBase(key, recursive = true))
  elif K is enum:
    $(ord(key))
  else:
    $key

proc writeImpl(writer: var CborWriter, value: TableType) {.raises: [IOError].} =
  writer.beginObject()
  for key, val in value:
    writer.writeField keyToStr(key), val
  writer.endObject()

func parseIntBounded[T: SomeSignedInt](a: string): T {.raises: [ValueError].} =
  let v = parseBiggestInt(a)
  when T isnot int64:
    if v < T.low.BiggestInt or v > T.high.BiggestInt:
      raise newException(ValueError, "value out of range for " & $T & ": " & a)
  T(v)

func parseCharKey(a: string): char {.raises: [ValueError].} =
  if a.len != 1:
    raise newException(ValueError, "char key must be exactly one character: " & a)
  a[0]

# `toKey(textKey, KeyType)` rebuilds the declared key type from the CBOR text
# key. The catch-all errors at compile time for unsupported key types.
template toKey(a: string, b: typed): untyped =
  {.error: "Table key type not supported: " & $type(b).}

template toKey(a: string, b: type int8): int8 =
  parseIntBounded[int8](a)

template toKey(a: string, b: type int16): int16 =
  parseIntBounded[int16](a)

template toKey(a: string, b: type int32): int32 =
  parseIntBounded[int32](a)

template toKey(a: string, b: type int64): int64 =
  parseIntBounded[int64](a)

template toKey(a: string, b: type char): char =
  parseCharKey(a)

template toKey(a: string, b: type string): string =
  a

proc toKey[T: enum](a: string, b: type T): T {.raises: [ValueError].} =
  ## Enum keys travel as their ordinal; validate against the actual values so
  ## holey enums and corrupt input raise a catchable ValueError.
  let v = parseInt(a)
  for e in T:
    if ord(e) == v:
      return e
  raise newException(ValueError, "invalid ordinal for enum " & $T & ": " & a)

proc toKey[T: distinct](a: string, b: type T): T {.raises: [ValueError].} =
  T(toKey(a, distinctBase(T, recursive = true)))

proc readImpl(
    reader: var CborReader, value: var TableType
) {.raises: [IOError, SerializationError].} =
  try:
    type KeyType = type(value.keys)
    type ValueType = type(value.values)
    value = init TableType
    for key, val in readObject(reader, string, ValueType):
      value[toKey(key, KeyType)] = val
  except ValueError as ex:
    reader.raiseUnexpectedValue("Table: " & ex.msg)

template write*(writer: var CborWriter, value: OrderedTable) =
  writeImpl(writer, value)

template write*(writer: var CborWriter, value: Table) =
  writeImpl(writer, value)

template read*(reader: var CborReader, value: var OrderedTable) =
  readImpl(reader, value)

template read*(reader: var CborReader, value: var Table) =
  readImpl(reader, value)

{.pop.}

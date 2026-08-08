## Per-context registry of live `{.ffiHandle.}` objects; only the `uint64` id crosses the
## boundary. Ids are monotonic, never recycled (0 = null). FFI-thread-only, so no locking.

import std/tables
import results
import ./cbor_serial

type
  FFIHandleRoot* = ref object of RootObj ## Base of every `{.ffiHandle.}` type.

  FFIHandleEntry = object
    obj: FFIHandleRoot
    typeName: string

  FFIHandleRegistry* = object
    nextId*: uint64
    byHandle*: Table[uint64, FFIHandleEntry]

proc initHandleRegistry*(reg: var FFIHandleRegistry) =
  reg.nextId = 0'u64
  reg.byHandle = initTable[uint64, FFIHandleEntry]()

proc deinitHandleRegistry*(reg: var FFIHandleRegistry) =
  reg.byHandle = default(Table[uint64, FFIHandleEntry])
  reg.nextId = 0'u64

proc register*(
    reg: var FFIHandleRegistry, obj: FFIHandleRoot, typeName: string
): uint64 =
  reg.nextId.inc()
  reg.byHandle[reg.nextId] = FFIHandleEntry(obj: obj, typeName: typeName)
  reg.nextId

proc lookup*(
    reg: var FFIHandleRegistry, handle: uint64, typeName: string
): Result[FFIHandleRoot, string] =
  ## Live ref for `handle`; err if absent or registered under another type.
  let entry = reg.byHandle.getOrDefault(handle)
  if entry.obj.isNil():
    return err("no ffiHandle with id " & $handle)
  if entry.typeName != typeName:
    return err(
      "ffiHandle " & $handle & " has type '" & entry.typeName & "', expected '" &
        typeName & "'"
    )
  ok(entry.obj)

proc release*(reg: var FFIHandleRegistry, handle: uint64): bool {.discardable.} =
  if not reg.byHandle.hasKey(handle):
    return false
  reg.byHandle.del(handle)
  return true

proc releaseAll*(reg: var FFIHandleRegistry) =
  ## Must run on the FFI thread that allocated the refs.
  reg.byHandle.clear()

proc encodeHandle*(id: uint64): seq[byte] =
  ## Single ABI seam for the handle-id wire format.
  cborEncode(id)

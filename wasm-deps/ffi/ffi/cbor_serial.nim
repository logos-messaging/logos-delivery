## `cbor_serialization` wrapper adapting its exception API to `Result[T, string]` for the FFI layer.
## `.ffi.` payloads (plain `object` and `ref T`) cross as value copies; raw `pointer`/`ptr T` are
## rejected at macro-expansion time (see `rejectRawPtrType`).

import system/ansi_c
import cbor_serialization, cbor_serialization/std/options, results

export cbor_serialization, options, results

const CborNullByte*: byte = 0xf6'u8
  ## CBOR `null` — wire sentinel for empty OK payloads.

proc cborEncode*[T](x: T): seq[byte] =
  return Cbor.encode(x)

proc cborEncodeShared*[T](x: T): tuple[data: ptr UncheckedArray[byte], len: int] =
  ## Encodes `x` into a caller-owned `c_malloc` buffer (free via `cborFreeShared`).
  ## Empty payloads return `(nil, 0)` without allocating.
  let bytes = Cbor.encode(x)
  if bytes.len == 0:
    return (nil, 0)
  let buf = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(bytes.len)))
  copyMem(buf, unsafeAddr bytes[0], bytes.len)
  return (buf, bytes.len)

proc cborFreeShared*(data: var ptr UncheckedArray[byte]) =
  ## Frees a `cborEncodeShared` buffer and nils the pointer. Nil-safe.
  if not data.isNil():
    c_free(data)
    data = nil

proc cborDecode*[T](data: openArray[byte], _: typedesc[T]): Result[T, string] =
  ## Decode `data` into a `T`, mapping any exception to `Result.err`.
  try:
    let v = Cbor.decode(data, T)
    return ok(v)
  except CatchableError as exc:
    return err(exc.msg)

proc cborDecodePtr*[T](
    data: ptr UncheckedArray[byte], dataLen: int, _: typedesc[T]
): Result[T, string] =
  ## Convenience for ptr+len buffers.
  if dataLen <= 0:
    return cborDecode(default(seq[byte]), T)
  cborDecode(toOpenArray(data, 0, dataLen - 1), T)

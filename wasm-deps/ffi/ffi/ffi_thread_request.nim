## Request blob passed main→FFI thread. Uses libc malloc/free (not Nim
## allocShared) so a producer thread exiting before the FFI thread frees can't
## dangle into reclaimed per-thread ORC TLS.

import system/ansi_c
import results
import chronos
import ./ffi_types, ./alloc, ./cbor_serial

const EmptyErrorMarker = "unknown error"
  ## RET_ERR fallback message; keeps the callback msg ptr non-nil.

const MaxScalarArgs* = 8
  ## Inline scalar fast-path capacity; more params can't use it (compile-time checked).

type FFIThreadRequest* = object
  callback*: FFICallBack
  userData*: pointer
  reqId*: cstring ## Req type name used to look up the handler.
  data*: ptr UncheckedArray[byte]
    ## Owned request payload: CBOR-encoded, or a packed `_CWire` struct on the
    ## `abi = c` path. Nil on the scalar fast path.
  dataLen*: int
  rawReply*: bool
    ## CBOR-free request (scalar fast path or `abi = c`): the reply is raw bytes,
    ## so a 0-length one is a real empty string, not a CBOR "no value".
  scalarArgs*: array[MaxScalarArgs, uint64]
    ## Inlined scalar args (no per-call c_malloc); a plain array keeps
    ## `deleteRequest` unaliased.
  next*: ptr FFIThreadRequest
    ## Intrusive queue link; request doubles as its own node so enqueue needs no
    ## ORC-heap alloc.
  responded*: bool
    ## De-dupes the callback across timeout/completion; both on FFI thread, no race.

func ffiPackScalar*[T](x: T): uint64 =
  ## Bit-cast one scalar into a uint64 request slot. Reverse with `ffiUnpackScalar`.
  when T is SomeFloat:
    cast[uint64](float64(x))
  elif T is bool:
    uint64(ord(x))
  elif T is SomeSignedInt:
    cast[uint64](int64(x))
  else:
    uint64(x)

func ffiUnpackScalar*[T](u: uint64, _: typedesc[T]): T =
  ## Inverse of `ffiPackScalar`.
  when T is SomeFloat:
    T(cast[float64](u))
  elif T is bool:
    u != 0'u64
  elif T is SomeSignedInt:
    T(cast[int64](u))
  else:
    T(u)

proc allocBaseRequest(
    callback: FFICallBack, userData: pointer, reqId: cstring
): ptr FFIThreadRequest =
  ## c_malloc the envelope and set routing fields; payload set by a helper below.
  var ret = cast[ptr FFIThreadRequest](c_malloc(csize_t(sizeof(FFIThreadRequest))))
  ret[].callback = callback
  ret[].userData = userData
  ret[].reqId = reqId.alloc()
  ret[].data = nil
  ret[].dataLen = 0
  ret[].rawReply = false
  ret[].next = nil
  ret[].responded = false
  return ret

proc copySharedPayload(req: ptr FFIThreadRequest, data: ptr byte, dataLen: int) =
  ## c_malloc a fresh buffer and copy `dataLen` bytes in; empty payload is a no-op.
  if dataLen > 0 and not data.isNil():
    req[].data = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(dataLen)))
    copyMem(req[].data, data, dataLen)
    req[].dataLen = dataLen

proc adoptOwnedSharedPayload(
    req: ptr FFIThreadRequest, data: ptr UncheckedArray[byte], dataLen: int
) =
  ## Embed an already-c_malloc'd buffer without copying; frees a zero-length
  ## non-nil buffer so it doesn't leak.
  if dataLen > 0 and not data.isNil():
    req[].data = data
    req[].dataLen = dataLen
  elif not data.isNil():
    c_free(data)

proc initFromPtr*(
    T: typedesc[FFIThreadRequest],
    callback: FFICallBack,
    userData: pointer,
    reqId: cstring,
    data: ptr byte,
    dataLen: int,
): ptr type T =
  ## Copies raw ptr+len into a fresh buffer owned by the returned request.
  var ret = allocBaseRequest(callback, userData, reqId)
  copySharedPayload(ret, data, dataLen)
  return ret

proc init*(
    T: typedesc[FFIThreadRequest],
    callback: FFICallBack,
    userData: pointer,
    reqId: cstring,
    data: openArray[byte],
): ptr type T =
  ## Like `initFromPtr` but from a Nim openArray.
  let dataPtr =
    if data.len > 0:
      cast[ptr byte](unsafeAddr data[0])
    else:
      nil
  initFromPtr(T, callback, userData, reqId, dataPtr, data.len)

proc initFromOwnedShared*(
    T: typedesc[FFIThreadRequest],
    callback: FFICallBack,
    userData: pointer,
    reqId: cstring,
    data: ptr UncheckedArray[byte],
    dataLen: int,
    rawReply: bool = false,
): ptr type T =
  ## Adopts an already-c_malloc'd buffer (no copy); `deleteRequest` c_frees it.
  ## Pass `(nil, 0)` for an empty payload. Set `rawReply` when the handler answers
  ## with raw (non-CBOR) bytes, so an empty reply reads as a real empty value.
  var ret = allocBaseRequest(callback, userData, reqId)
  adoptOwnedSharedPayload(ret, data, dataLen)
  ret[].rawReply = rawReply
  return ret

proc initScalar*(
    T: typedesc[FFIThreadRequest],
    callback: FFICallBack,
    userData: pointer,
    reqId: cstring,
    args: varargs[uint64],
): ptr type T =
  ## Scalar-fast-path request: packed args ride inline, no payload c_malloc.
  doAssert args.len <= MaxScalarArgs,
    "initScalar: " & $args.len & " scalar args exceed MaxScalarArgs (" & $MaxScalarArgs &
      ")"
  var ret = allocBaseRequest(callback, userData, reqId)
  ret[].rawReply = true
  for i in 0 ..< args.len:
    ret[].scalarArgs[i] = args[i]
  ret

func ffiRawRetBytes*[T](x: T): seq[byte] =
  ## CBOR-free handler result as raw bytes: string/cstring ride as UTF-8, other
  ## scalars as the 8-byte native image of `ffiPackScalar(x)`.
  when T is string:
    var b = newSeq[byte](x.len)
    if x.len > 0:
      copyMem(addr b[0], unsafeAddr x[0], x.len)
    b
  elif T is cstring:
    let n = x.len
    var b = newSeq[byte](n)
    if n > 0:
      copyMem(addr b[0], cast[pointer](x), n)
    b
  else:
    let u = ffiPackScalar(x)
    var b = newSeq[byte](sizeof(uint64))
    copyMem(addr b[0], unsafeAddr u, sizeof(uint64))
    b

proc deleteRequest*(request: ptr FFIThreadRequest) =
  if not request[].data.isNil:
    c_free(request[].data)
  if not request[].reqId.isNil:
    c_free(cast[pointer](request[].reqId))
  c_free(request)

proc fireCallback*(res: Result[seq[byte], string], request: ptr FFIThreadRequest) =
  ## Answers the foreign callback at most once (timeout and completion both call
  ## it). Does NOT free the request; `handleRes` does.
  if request[].responded:
    return
  request[].responded = true
  if res.isErr():
    foreignThreadGc:
      let msg = if res.error.len > 0: res.error else: EmptyErrorMarker
      request[].callback(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), request[].userData
      )
    return

  foreignThreadGc:
    let bytes = res.get()
    if bytes.len > 0:
      request[].callback(
        RET_OK,
        cast[ptr cchar](unsafeAddr bytes[0]),
        cast[csize_t](bytes.len),
        request[].userData,
      )
    elif request[].rawReply:
      # A CBOR-free 0-byte return is a real empty string, not CBOR "no value".
      var empty: byte
      request[].callback(
        RET_OK, cast[ptr cchar](addr empty), 0.csize_t, request[].userData
      )
    else:
      # Always hand the callback a real buffer; CBOR null marks "no value".
      var sentinel = CborNullByte
      request[].callback(
        RET_OK, cast[ptr cchar](addr sentinel), 1.csize_t, request[].userData
      )

proc fireStaleWarn*(request: ptr FFIThreadRequest, elapsedMs: int64) =
  ## In-flight ping; leaves `responded` unset and may fire many times — the
  ## terminal RET_OK/RET_ERR is still owed.
  if request[].responded:
    return
  foreignThreadGc:
    let msg = $elapsedMs
    request[].callback(
      RET_STALE_WARN,
      cast[ptr cchar](unsafeAddr msg[0]),
      cast[csize_t](msg.len),
      request[].userData,
    )

proc handleRes*(res: Result[seq[byte], string], request: ptr FFIThreadRequest) =
  ## Terminal step: delivers the response and frees the request exactly once.
  defer:
    deleteRequest(request)
  fireCallback(res, request)

proc nilProcess*(reqId: cstring): Future[Result[seq[byte], string]] {.async.} =
  return err("This request type is not implemented: " & $reqId)

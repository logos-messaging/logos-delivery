import std/tables
import chronos

type FFICallBack* = proc(
  callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}
  ## Result-delivery callback. `RET_OK`/`RET_ERR` fire once and end the request;
  ## `RET_STALE_WARN` may fire repeatedly before them.

const RET_OK*: cint = 0
const RET_ERR*: cint = 1
const RET_MISSING_CALLBACK*: cint = 2
const RET_STALE_WARN*: cint = 3
  ## Non-terminal: request still in flight, fires every `StaleWarnInterval` with
  ## `msg` = elapsed ms as decimal ASCII, always followed by a terminal code.

type FFIRequestProc* = proc(
  request: pointer, reqHandler: pointer
): Future[Result[seq[byte], string]] {.async.}
  ## OK payload is a CBOR-encoded response body; errors are plain UTF-8.

template foreignThreadGc*(body: untyped) =
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()

  body

  when declared(tearDownForeignThreadGc):
    tearDownForeignThreadGc()

## Compile-time-populated table: request type name (cstring) -> async handler.
var registeredRequests*: Table[cstring, FFIRequestProc]

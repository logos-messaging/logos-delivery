## The poll model, from inside the image: how a `logos_module_dispatch`
## handler (on the host's thread) calls one of this library's own nim-ffi
## exports and waits for its reply.
##
## The exports are the C symbols this same image defines; they are bound here
## by their C names rather than called as Nim procs, so this file depends on
## the ABI, not on nim-ffi's macro internals. A call submits a CBOR request and
## then polls the context on the calling thread until that reply arrives;
## events that arrive meanwhile go to the host's emit callback (see
## `events.nim`) -- in the module image they never enter nim-ffi's queue, so
## nothing is ever waiting in it but replies.

import std/[json, sets, tables]
import results
import ffi/[ffi_msg, ret_codes]
import cbor_serialization
import ffi/cbor_serial
import ../logos_module/events

type
  Ctx* = pointer
  Export* = proc(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.cdecl.}
  Reply* = object
    ret*: cint
    payload*: seq[byte] ## RET_OK: the reply's CBOR
    error*: string ## otherwise the library's text

# The library's fixed exports, by C name.
proc ldCreateNode(req: ptr byte, len: csize_t, ctxOut: ptr pointer, idOut: ptr uint64): cint
  {.importc: "logosdelivery_create_node", cdecl.}
proc ldDestroy(ctx: pointer): cint {.importc: "logosdelivery_destroy", cdecl.}
proc ldPoll(ctx: pointer, timeoutMs: int32, msg: ptr ptr NimFfiMsg): cint
  {.importc: "logosdelivery_poll", cdecl.}

const SliceMs = 50'i32

var
  settled: Table[uint64, Reply] # replies seen before their caller asked
  unwaited: HashSet[uint64] # submitted without a waiter: their replies are dropped

proc decodeReply(m: ptr NimFfiMsg): Reply =
  var r = Reply(ret: m.retCode.cint)
  if m.len > 0:
    let bytes = cast[ptr UncheckedArray[byte]](m.payload)
    if m.retCode == RET_OK:
      r.payload = @(bytes.toOpenArray(0, int(m.len) - 1))
    else:
      r.error = newString(int(m.len))
      copyMem(addr r.error[0], m.payload, int(m.len))
  return r

proc dispatch(m: ptr NimFfiMsg) =
  case m.kind
  of MsgReply:
    if m.id in unwaited:
      unwaited.excl(m.id)
    else:
      settled[m.id] = decodeReply(m)
  of MsgEvent:
    # not expected in the module image (events bypass the queue), but harmless
    var text = newString(int(m.len))
    if m.len > 0:
      copyMem(addr text[0], m.payload, int(m.len))
    emitLibraryEvent(text)
  else:
    discard # STALE_WARN and the liveness ticks: the deadline decides

proc waitFor*(ctx: Ctx, id: uint64, timeoutMs: int): Reply =
  ## Pumps this context on the calling thread until reply `id`, or the deadline.
  var left = timeoutMs
  while true:
    if settled.hasKey(id):
      let r = settled[id]
      settled.del(id)
      return r
    if left <= 0:
      return Reply(ret: RET_TIMEOUT, error: "no reply within " & $timeoutMs & " ms")
    var m: ptr NimFfiMsg = nil
    let slice = min(left, int(SliceMs))
    let rc = ldPoll(ctx, int32(slice), addr m)
    if rc == RET_OK and m != nil:
      dispatch(m)
    elif rc == RET_TIMEOUT:
      left -= slice
    elif rc != RET_OK:
      return Reply(ret: rc, error: "poll rc=" & $rc)

proc create*(req: seq[byte], timeoutMs: int): Result[Ctx, string] =
  ## The constructor: returns the context at once, its reply says whether the
  ## node came up.
  var ctx: pointer = nil
  var id: uint64 = 0
  let rc = ldCreateNode(if req.len > 0: unsafeAddr req[0] else: nil, csize_t(req.len), addr ctx, addr id)
  if rc != RET_OK or ctx.isNil:
    return err("create_node: not accepted, rc=" & $rc)
  let ready = waitFor(ctx, id, timeoutMs)
  if ready.ret != RET_OK:
    discard ldDestroy(ctx)
    return err(if ready.error.len > 0: ready.error else: "rc=" & $ready.ret)
  return ok(ctx)

proc destroy*(ctx: Ctx) =
  if not ctx.isNil:
    discard ldDestroy(ctx)
  settled.clear()
  unwaited.clear()

proc call*(ctx: Ctx, fn: Export, req: seq[byte], timeoutMs: int): Reply =
  ## Submits and pumps until the reply.
  var id: uint64 = 0
  let rc = fn(ctx, if req.len > 0: unsafeAddr req[0] else: nil, csize_t(req.len), addr id)
  if rc != RET_OK:
    return Reply(ret: rc, error: "not accepted, rc=" & $rc)
  return waitFor(ctx, id, timeoutMs)

proc submit*(ctx: Ctx, fn: Export, req: seq[byte]): Result[uint64, string] =
  ## Submits without waiting: the reply, when it comes, is dropped. For calls
  ## whose outcome the node reports as an event.
  var id: uint64 = 0
  let rc = fn(ctx, if req.len > 0: unsafeAddr req[0] else: nil, csize_t(req.len), addr id)
  if rc != RET_OK:
    return err("not accepted, rc=" & $rc)
  unwaited.incl(id)
  return ok(id)

proc encode*[T](req: T): seq[byte] =
  ## A request: a CBOR map keyed by the proc's parameter names -- the fields of `req`.
  return cborEncode(req)

proc decodeString*(r: Reply): string =
  ## A reply whose value is text (the common case).
  if r.payload.len == 0:
    return ""
  let d = cborDecode(r.payload, string)
  return if d.isOk: d.get() else: ""

proc decodeBool*(r: Reply): bool =
  if r.payload.len == 0:
    return false
  let d = cborDecode(r.payload, bool)
  return if d.isOk: d.get() else: false

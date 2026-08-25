## RLN module FFI — logos-delivery consumes an external RLN module over a C
## callback surface. Opaque JSON in/out: the host module owns the schema, so
## this file models no RLN types. See `library/liblogosdelivery_rln.h`.
##
## Threading: host callbacks may complete on a foreign thread, so the crossing
## uses `ThreadSignalPtr` + `allocShared` (no GC memory shared across threads).
## One `Lock` guards the callback pointer and the in-flight `ptr Pending` list.

import std/locks
import chronos, chronos/threadsync, results

type
  LogosDeliveryRlnOpFn = proc(reqId: uint64, payloadJson: cstring, userData: pointer) {.
    cdecl, gcsafe, raises: []
  .}

  LogosDeliveryRlnCallbacks = object
    start: LogosDeliveryRlnOpFn
    stop: LogosDeliveryRlnOpFn
    register_membership: LogosDeliveryRlnOpFn
    get_membership_state: LogosDeliveryRlnOpFn
    get_epoch_quota: LogosDeliveryRlnOpFn
    generate_proof: LogosDeliveryRlnOpFn
    verify_proof: LogosDeliveryRlnOpFn

  Pending = object
    reqId: uint64
    signal: ThreadSignalPtr # how rlnInvoke gets woken
    resultBuf: cstring # allocShared copy of the host's JSON; nil until answered
    completed: bool
    next: ptr Pending # intrusive in-flight list — no GC memory, cross-thread safe

  RlnOp* = enum
    RlnOpStart
    RlnOpStop
    RlnOpRegister
    RlnOpGetMembershipState
    RlnOpGetEpochQuota
    RlnOpGenerateProof
    RlnOpVerifyProof

var
  gLock: Lock
  gCallbacks: LogosDeliveryRlnCallbacks # all-nil struct = "not registered"
  gUserData: pointer
  gPending: ptr Pending # head of the in-flight request list
  gNextReqId: uint64

initLock(gLock)

proc unlinkPending(target: ptr Pending) =
  ## Remove `target` from the in-flight list. Safe if it was never linked.
  if gPending == target:
    gPending = target.next
    return
  var p = gPending
  while not p.isNil and p.next != target:
    p = p.next
  if not p.isNil:
    p.next = target.next

proc slotFor(op: RlnOp): LogosDeliveryRlnOpFn =
  case op
  of RlnOpStart: gCallbacks.start
  of RlnOpStop: gCallbacks.stop
  of RlnOpRegister: gCallbacks.register_membership
  of RlnOpGetMembershipState: gCallbacks.get_membership_state
  of RlnOpGetEpochQuota: gCallbacks.get_epoch_quota
  of RlnOpGenerateProof: gCallbacks.generate_proof
  of RlnOpVerifyProof: gCallbacks.verify_proof

#int logosdelivery_rln_set_callbacks(const LogosDeliveryRlnCallbacks* cbs, void* user_data);
proc logosdelivery_rln_set_callbacks(
    cbs: ptr LogosDeliveryRlnCallbacks, userData: pointer
): cint {.exportc, cdecl, dynlib.} =
  # copy struct (or clear on nil), stash userData; nil fails all pending
  withLock gLock:
    if cbs.isNil:
      gCallbacks = LogosDeliveryRlnCallbacks()
      gUserData = nil
      var p = gPending
      while not p.isNil:
        p.completed = false # signals "module cleared", not a real completion
        discard p.signal.fireSync()
        p = p.next
    else:
      gCallbacks = cbs[]
      gUserData = userData
    return 0

#int logosdelivery_rln_response(uint64_t req_id, const char* result_json);
proc logosdelivery_rln_response(
    reqId: uint64, resultJson: cstring
): cint {.exportc, cdecl, dynlib.} =
  # under lock: find pending by reqId, copy the JSON in, fireSync the signal.
  # unknown reqId → non-zero (late response after timeout)
  withLock gLock:
    var p = gPending
    while not p.isNil and p.reqId != reqId:
      p = p.next
    if p.isNil:
      return 1
    let n = resultJson.len()
    p.resultBuf = cast[cstring](allocShared0(n + 1)) # shared heap: safe on any thread
    copyMem(p.resultBuf, resultJson, n)
    p.completed = true
    discard p.signal.fireSync()
    return 0

proc rlnInvoke*(
    op: RlnOp, payloadJson: string
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  ## Fire the host's callback for `op` and await its `logosdelivery_rln_response`.
  ## JSON in, JSON out. Fails (in the Result) with "not registered" / "timeout";
  ## never leaks the pending node, even on cancellation.
  let p = cast[ptr Pending](allocShared0(sizeof(Pending)))
  p.signal = ThreadSignalPtr.new().valueOr:
    deallocShared(p)
    return err("signal alloc failed")

  # Registered before the insert so a cancellation anywhere below still unlinks
  # the node and frees the signal, the result buffer and the node itself.
  defer:
    withLock gLock:
      unlinkPending(p)
    discard p.signal.close()
    if not p.resultBuf.isNil:
      deallocShared(p.resultBuf)
    deallocShared(p)

  var fn: LogosDeliveryRlnOpFn
  withLock gLock: # short critical section, no await inside
    fn = slotFor(op)
    if fn.isNil:
      return err("RLN module not registered")
    p.reqId = gNextReqId
    inc gNextReqId
    p.next = gPending
    gPending = p

  fn(p.reqId, payloadJson.cstring, gUserData) # returns immediately; host works async

  let answered = await p.signal.wait().withTimeout(10.seconds)

  if not answered or not p.completed:
    return
      err("timeout") # or "module cleared" if completed=false via set_callbacks(nil)
  return ok($p.resultBuf) # Nim string materialized here, on the chronos thread — safe

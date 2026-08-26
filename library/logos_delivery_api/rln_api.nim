## RLN module FFI — logos-delivery consumes an external RLN module over a C
## callback surface. One typed callback per RLN function: scalar args are passed
## directly, complex args (options, proof) as JSON, and every call's result comes
## back as JSON via `logosdelivery_rln_response`. See `liblogosdelivery_rln.h`.
##
## Threading: host callbacks may complete on a foreign thread, so the crossing
## uses `ThreadSignalPtr` + `allocShared` (no GC memory shared across threads).
## One `Lock` guards the callback table and the in-flight `ptr Pending` list.

import std/locks
import chronos, chronos/threadsync, results

type
  LogosDeliveryRlnStartFn =
    proc(reqId: uint64, userData: pointer) {.cdecl, gcsafe, raises: [].}

  LogosDeliveryRlnStopFn =
    proc(reqId: uint64, userData: pointer) {.cdecl, gcsafe, raises: [].}

  LogosDeliveryRlnRegisterFn = proc(
    reqId: uint64, registryId, rlnIdentifier, optionsJson: cstring, userData: pointer
  ) {.cdecl, gcsafe, raises: [].}

  LogosDeliveryRlnGetMembershipStateFn = proc(
    reqId: uint64, registryId, rlnIdentifier: cstring, userData: pointer
  ) {.cdecl, gcsafe, raises: [].}

  LogosDeliveryRlnGetEpochQuotaFn = proc(
    reqId: uint64,
    registryId, rlnIdentifier: cstring,
    timestamp: uint64,
    userData: pointer,
  ) {.cdecl, gcsafe, raises: [].}

  LogosDeliveryRlnGenerateProofFn = proc(
    reqId: uint64,
    registryId, rlnIdentifier, signalHex: cstring,
    timestamp: uint64,
    userData: pointer,
  ) {.cdecl, gcsafe, raises: [].}

  LogosDeliveryRlnVerifyProofFn = proc(
    reqId: uint64,
    registryId, rlnIdentifier, signalHex: cstring,
    timestamp: uint64,
    proofJson: cstring,
    userData: pointer,
  ) {.cdecl, gcsafe, raises: [].}

  LogosDeliveryRlnCallbacks = object
    start: LogosDeliveryRlnStartFn
    stop: LogosDeliveryRlnStopFn
    register_membership: LogosDeliveryRlnRegisterFn
    get_membership_state: LogosDeliveryRlnGetMembershipStateFn
    get_epoch_quota: LogosDeliveryRlnGetEpochQuotaFn
    generate_proof: LogosDeliveryRlnGenerateProofFn
    verify_proof: LogosDeliveryRlnVerifyProofFn

  Pending = object
    reqId: uint64
    signal: ThreadSignalPtr # how the awaiting call gets woken
    resultBuf: cstring # allocShared copy of the host's JSON result; nil until answered
    completed: bool
    next: ptr Pending # intrusive in-flight list — no GC memory, cross-thread safe

var
  gLock: Lock
  gCallbacks: LogosDeliveryRlnCallbacks # all-nil struct = "not registered"
  gUserData: pointer
  gPending: ptr Pending # head of the in-flight request list
  gNextReqId: uint64

initLock(gLock)

# --- transport primitives -----------------------------------------------------

proc newPending(): ptr Pending =
  ## Allocate a pending node with a fresh signal. nil on signal-alloc failure.
  let p = cast[ptr Pending](allocShared0(sizeof(Pending)))
  p.signal = ThreadSignalPtr.new().valueOr:
    deallocShared(p)
    return nil
  p

proc linkPending(p: ptr Pending) =
  ## Assign `p` a req id and link it into the in-flight list. Caller holds gLock.
  p.reqId = gNextReqId
  inc gNextReqId
  p.next = gPending
  gPending = p

proc unlinkPending(target: ptr Pending) =
  ## Remove `target` from the in-flight list. Caller holds gLock. Safe if unlinked.
  if gPending == target:
    gPending = target.next
    return
  var p = gPending
  while not p.isNil and p.next != target:
    p = p.next
  if not p.isNil:
    p.next = target.next

proc awaitResult(
    p: ptr Pending
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  ## Await the host's response for an already-registered node; always unlinks + frees.
  defer:
    withLock gLock:
      unlinkPending(p)
    discard p.signal.close()
    if not p.resultBuf.isNil:
      deallocShared(p.resultBuf)
    deallocShared(p)

  let answered = await p.signal.wait().withTimeout(10.seconds)
  if not answered or not p.completed:
    return
      err("timeout") # or "module cleared" if completed=false via set_callbacks(nil)
  return ok($p.resultBuf)

# --- outbound calls (one per RLN function) ------------------------------------
# Each: allocate + register a pending node, capture its callback + userData under
# the lock, fire the callback (outside the lock, so a synchronous host response
# can't deadlock), then await the JSON result.

proc rlnStart*(): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: LogosDeliveryRlnStartFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.start
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(pending.reqId, ud)
  return await awaitResult(pending)

proc rlnStop*(): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: LogosDeliveryRlnStopFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.stop
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(pending.reqId, ud)
  return await awaitResult(pending)

proc rlnRegister*(
    registryId, rlnIdentifier, optionsJson: string
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: LogosDeliveryRlnRegisterFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.register_membership
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(pending.reqId, registryId.cstring, rlnIdentifier.cstring, optionsJson.cstring, ud)
  return await awaitResult(pending)

proc rlnGetMembershipState*(
    registryId, rlnIdentifier: string
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: LogosDeliveryRlnGetMembershipStateFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.get_membership_state
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(pending.reqId, registryId.cstring, rlnIdentifier.cstring, ud)
  return await awaitResult(pending)

proc rlnGetEpochQuota*(
    registryId, rlnIdentifier: string, timestamp: uint64
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: LogosDeliveryRlnGetEpochQuotaFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.get_epoch_quota
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(pending.reqId, registryId.cstring, rlnIdentifier.cstring, timestamp, ud)
  return await awaitResult(pending)

proc rlnGenerateProof*(
    registryId, rlnIdentifier, signalHex: string, timestamp: uint64
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: LogosDeliveryRlnGenerateProofFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.generate_proof
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(
    pending.reqId, registryId.cstring, rlnIdentifier.cstring, signalHex.cstring,
    timestamp, ud,
  )
  return await awaitResult(pending)

proc rlnVerifyProof*(
    registryId, rlnIdentifier, signalHex: string, timestamp: uint64, proofJson: string
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: LogosDeliveryRlnVerifyProofFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.verify_proof
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(
    pending.reqId, registryId.cstring, rlnIdentifier.cstring, signalHex.cstring,
    timestamp, proofJson.cstring, ud,
  )
  return await awaitResult(pending)

# --- C entry points -----------------------------------------------------------

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

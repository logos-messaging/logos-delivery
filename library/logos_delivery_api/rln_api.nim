## RLN module FFI — logos-delivery consumes an external RLN module over a C
## callback surface. One typed callback per RLN function: scalar args are passed
## directly, complex args (config, options, proof) as JSON, and every call's
## result comes back as JSON via `logosdelivery_rln_response`. See
## `liblogosdelivery_rln.h`. The reply-parsing helpers near the bottom decode
## the module's two wire dialects; the broker providers registered by
## `registerRlnModuleProviders` (called from node_api at node create) are their
## only consumers.
##
## Threading: host callbacks may complete on a foreign thread, so the crossing
## uses `ThreadSignalPtr` + `allocShared` (no GC memory shared across threads).
## One `Lock` guards the callback table and the in-flight `ptr Pending` list.
##
## Membership is keyed by two identifiers carried on nearly every call:
## `registryId` is a CAIP-10 account identifier (`namespace:reference:account_address`)
## and `rlnIdentifier` is a 32-byte per-application identifier.

import std/[json, locks]
import chronos, chronos/threadsync, results
import stew/byteutils
import brokers/broker_context
import
  logos_delivery/waku/waku_core/message/message,
  logos_delivery/waku/requests/rln_requests,
  logos_delivery/waku/rln/api/types as rln_api_types
from logos_delivery/waku/rln/proof import toRLNSignal

type
  LogosDeliveryRlnStartFn = proc(reqId: uint64, configJson: cstring, userData: pointer) {.
    cdecl, gcsafe, raises: []
  .}

  LogosDeliveryRlnStopFn =
    proc(reqId: uint64, userData: pointer) {.cdecl, gcsafe, raises: [].}

  LogosDeliveryRlnRegisterFn = proc(
    reqId: uint64,
    registryId, rlnIdentifier: cstring,
    optionsJson: cstring,
    userData: pointer,
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

  LogosDeliveryRlnValidateProofFn = proc(
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
    validate_proof: LogosDeliveryRlnValidateProofFn

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

const
  # Per-call response budgets, from the RLN module's documented time budgets
  # (docs/wire-binding.md): register / generate_proof / get_membership_state
  # may each perform one registry read (<= 70 s worst case), so they get 95 s;
  # everything else is local computation and answers in milliseconds.
  RlnLocalTimeout = 10.seconds
  RlnRegistryReadTimeout = 95.seconds

proc awaitResult(
    p: ptr Pending, timeout: Duration
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  ## Await the host's response for an already-registered node; always unlinks + frees.
  defer:
    withLock gLock:
      unlinkPending(p)
    discard p.signal.close()
    if not p.resultBuf.isNil:
      deallocShared(p.resultBuf)
    deallocShared(p)

  let answered = await p.signal.wait().withTimeout(timeout)
  if not answered or not p.completed:
    return
      err("timeout") # or "module cleared" if completed=false via set_callbacks(nil)
  return ok($p.resultBuf)

# --- outbound calls (one per RLN function) ------------------------------------
# Each: allocate + register a pending node, capture its callback + userData under
# the lock, fire the callback (outside the lock, so a synchronous host response
# can't deadlock), then await the JSON result.

proc rlnStart*(
    configJson: string
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
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
  cb(pending.reqId, configJson.cstring, ud)
  return await awaitResult(pending, RlnLocalTimeout)

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
  return await awaitResult(pending, RlnLocalTimeout)

proc rlnRegister*(
    registryId, rlnIdentifier: string, optionsJson: string
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
  return await awaitResult(pending, RlnRegistryReadTimeout)

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
  return await awaitResult(pending, RlnRegistryReadTimeout)

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
  return await awaitResult(pending, RlnLocalTimeout)

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
  return await awaitResult(pending, RlnRegistryReadTimeout)

proc rlnValidateProof*(
    registryId, rlnIdentifier, signalHex: string, timestamp: uint64, proofJson: string
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: LogosDeliveryRlnValidateProofFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.validate_proof
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
  return await awaitResult(pending, RlnLocalTimeout)

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

# --- reply parsing ------------------------------------------------------------
# Module replies follow the RLN module's own wire dialects (logos-rln-modules,
# docs/wire-binding.md), split by the method's declared return type:
# - `result` methods (start, stop, generate_proof, validate_proof,
#   get_epoch_quota) answer with the LogosResult envelope
#   {"success":bool,"value":<reply>,"error":<string>}; on failure `error` is
#   the JSON-encoded typed object {"class","kind","message"}.
# - `tstr` methods (register, get_membership_state) answer with compact JSON;
#   failures are the in-band envelope {"error":{"class",...}}.
# `class` is the spec's RlnErrorKind, lowercase: not_ready | transient |
# budget_exhausted | permanent.

proc parseRlnVerdict(s: string): Result[ProofVerdict, string] =
  case s
  of "valid":
    ok(ProofVerdict.Valid)
  of "invalid":
    ok(ProofVerdict.Invalid)
  of "duplicate":
    ok(ProofVerdict.Duplicate)
  of "rate_limit_violation":
    ok(ProofVerdict.RateLimitViolation)
  else:
    err("unknown verdict: " & s)

proc parseRlnJson(resultJson: string): Result[JsonNode, string] =
  ## Parses a module reply, tolerating the SDK's known double-encoding quirk
  ## (a JSON string containing the actual JSON reply).
  var node =
    try:
      parseJson(resultJson)
    except CatchableError as e:
      return err("invalid module reply JSON: " & e.msg)
  if node.kind == JString:
    try:
      node = parseJson(node.getStr())
    except CatchableError:
      return err("module reply is a plain string: " & node.getStr())
  if node.kind != JObject:
    return err("module reply is not a JSON object")
  ok(node)

proc formatRlnError(errNode: JsonNode): string =
  errNode{"class"}.getStr("transient") & ": " & errNode{"message"}.getStr("") &
    " (kind: " & errNode{"kind"}.getStr("") & ")"

proc parseRlnResultEnvelope(resultJson: string): Result[JsonNode, string] =
  ## `result`-dialect reply: returns the envelope's `value` on success.
  let node = ?parseRlnJson(resultJson)
  if not node.hasKey("success"):
    return err("module reply has no success field")
  if not node{"success"}.getBool(false):
    let errField = node{"error"}
    if not errField.isNil() and errField.kind == JString:
      let errObj =
        try:
          parseJson(errField.getStr())
        except CatchableError:
          return err(errField.getStr())
      return err(formatRlnError(errObj))
    return err("module call failed with no error detail")
  var value = node{"value"}
  if value.isNil():
    return err("module reply has no value field")
  if value.kind == JString:
    # the value itself may arrive JSON-encoded; a genuine string stays as-is
    try:
      value = parseJson(value.getStr())
    except CatchableError:
      discard
  ok(value)

proc parseRlnTstrReply(resultJson: string): Result[JsonNode, string] =
  ## `tstr`-dialect reply: the compact JSON object, or the in-band error.
  let node = ?parseRlnJson(resultJson)
  if node.hasKey("error"):
    return err(formatRlnError(node["error"]))
  ok(node)

proc parseRlnValidationResult(resultJson: string): Result[ValidationResult, string] =
  ## validate_proof reply: a result envelope whose value is the verdict object
  ## {"verdict":str}, plus "recovered_secret" (hex) on rate_limit_violation.
  ## An invalid proof is a verdict, not an error — an error means the module
  ## failed to answer.
  let value = ?parseRlnResultEnvelope(resultJson)
  let verdict = ?parseRlnVerdict(value{"verdict"}.getStr(""))
  var validation = ValidationResult(verdict: verdict)
  let recovered = value{"recovered_secret"}
  if not recovered.isNil() and recovered.kind == JString:
    var secret: array[RlnFieldElementSize, byte]
    try:
      hexToByteArray(recovered.getStr(), secret)
    except ValueError:
      return err("recovered_secret is not a 32-byte hex string")
    validation.recoveredSecret = some(secret)
  return ok(validation)

proc parseRlnGeneratedProof(resultJson: string): Result[seq[byte], string] =
  ## generate_proof reply: a result envelope whose value carries
  ## "proof_canonical" — the full zerokit serialization as hex, the one blob
  ## a message carries and validate_proof accepts alone.
  let value = ?parseRlnResultEnvelope(resultJson)
  let hexStr = value{"proof_canonical"}.getStr("")
  if hexStr.len == 0:
    return err("Generate_proof reply carries no proof_canonical")
  try:
    return ok(hexToSeqByte(hexStr))
  except ValueError as e:
    return err("Proof_canonical is not valid hex: " & e.msg)

proc parseRlnMembershipStatus(s: string): Result[MembershipStatus, string] =
  case s
  of "unknown":
    ok(MembershipStatus.Unknown)
  of "pending":
    ok(MembershipStatus.Pending)
  of "failed":
    ok(MembershipStatus.Failed)
  of "active":
    ok(MembershipStatus.Active)
  of "grace_period":
    ok(MembershipStatus.GracePeriod)
  of "expired":
    ok(MembershipStatus.Expired)
  of "erased_awaits_withdrawal":
    ok(MembershipStatus.ErasedAwaitsWithdrawal)
  of "erased":
    ok(MembershipStatus.Erased)
  of "slashed":
    ok(MembershipStatus.Slashed)
  else:
    err("unknown membership state: " & s)

proc parseRlnMembershipState(resultJson: string): Result[MembershipState, string] =
  ## get_membership_state reply: {"state":str} plus membership_hash /
  ## leaf_index / rate_limit once the membership data is known.
  let node = ?parseRlnTstrReply(resultJson)
  let status = ?parseRlnMembershipStatus(node{"state"}.getStr(""))
  var state = MembershipState(status: status)
  let hashHex = node{"membership_hash"}.getStr("")
  if hashHex.len > 0:
    var hash: array[RlnFieldElementSize, byte]
    try:
      hexToByteArray(hashHex, hash)
    except ValueError:
      return err("membership_hash is not a 32-byte hex string")
    state.membership = some(
      Membership(
        membershipHash: hash,
        rateLimit: node{"rate_limit"}.getBiggestInt(0).uint64,
        leafIndex: node{"leaf_index"}.getBiggestInt(0).uint64,
      )
    )
  return ok(state)

# --- broker providers ---------------------------------------------------------

proc registerRlnModuleProviders(ctx: BrokerContext, lez: bool): Result[void, string] =
  ## Bridges the waku layer's RLN module requests onto the FFI callback
  ## surface. Providers are registered at create time; the underlying calls
  ## only succeed once the host has installed its RLN callbacks.
  RequestStartRlnModule.setProvider(
    ctx,
    proc(configJson: string): Future[Result[RequestStartRlnModule, string]] {.async.} =
      let response = ?await rlnStart(configJson)
      # result-dialect call: surface a module-side failure as err so the
      # caller does not proceed to registration on a dead module.
      discard ?parseRlnResultEnvelope(response)
      return ok(RequestStartRlnModule(response: response)),
  ).isOkOr:
    return err("Failed to set RequestStartRlnModule provider: " & error)

  RequestRegisterRlnMembership.setProvider(
    ctx,
    proc(
        registryId: RegistryId, rlnIdentifier: RlnIdentifier, options: RegistryOptions
    ): Future[Result[RequestRegisterRlnMembership, string]] {.async.} =
      var optionsJson = newJArray()
      for opt in options:
        optionsJson.add(%*{"key": opt.key, "value": opt.value})
      let response = ?await rlnRegister(registryId, rlnIdentifier.toHex(), $optionsJson)
      # tstr-dialect call: failures arrive in-band under "error".
      discard ?parseRlnTstrReply(response)
      return ok(RequestRegisterRlnMembership(response: response)),
  ).isOkOr:
    return err("Failed to set RequestRegisterRlnMembership provider: " & error)

  RequestGetRlnMembershipState.setProvider(
    ctx,
    proc(
        registryId: RegistryId, rlnIdentifier: RlnIdentifier
    ): Future[Result[RequestGetRlnMembershipState, string]] {.async.} =
      let response = ?await rlnGetMembershipState(registryId, rlnIdentifier.toHex())
      let state = ?parseRlnMembershipState(response)
      return ok(RequestGetRlnMembershipState(state: state)),
  ).isOkOr:
    return err("Failed to set RequestGetRlnMembershipState provider: " & error)

  RequestValidateRlnProof.setProvider(
    ctx,
    proc(
        message: WakuMessage,
        registryId: RegistryId,
        rlnIdentifier: RlnIdentifier,
        timestamp: uint64,
    ): Future[Result[RequestValidateRlnProof, string]] {.async.} =
      let signalHex = message.toRLNSignal().toHex()
      let proofJson = $(%*{"proof": message.proof.toHex()})
      let response = ?await rlnValidateProof(
        registryId, rlnIdentifier.toHex(), signalHex, timestamp, proofJson
      )
      let validation = ?parseRlnValidationResult(response)
      return ok(RequestValidateRlnProof(validation: validation)),
  ).isOkOr:
    return err("Failed to set RequestValidateRlnProof provider: " & error)

  # lez-gated: the legacy zerokit path registers its own provider for this request type
  if lez:
    RequestGenerateRlnProof.setProvider(
      ctx,
      proc(
          message: WakuMessage,
          registryId: RegistryId,
          rlnIdentifier: RlnIdentifier,
          timestamp: uint64,
      ): Future[Result[RequestGenerateRlnProof, string]] {.async.} =
        let signalHex = message.toRLNSignal().toHex()
        let response = ?await rlnGenerateProof(
          registryId, rlnIdentifier.toHex(), signalHex, timestamp
        )
        let proofBytes = ?parseRlnGeneratedProof(response)
        return ok(RequestGenerateRlnProof(proof: proofBytes)),
    ).isOkOr:
      return err("failed to set RequestGenerateRlnProof provider: " & error)

  ok()

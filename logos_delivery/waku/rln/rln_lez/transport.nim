## FFI transport to the external RLN module: one typed C callback per RLN
## function; every result returns as JSON via `logosdelivery_rln_response`.
## Wire contract: `library/liblogosdelivery_rln.h`.
## `node_api.nim` imports this module to keep the C entry points compiled in.
##
## Host callbacks may complete on a foreign thread, so the crossing uses
## `ThreadSignalPtr` + `allocShared` only, with one `Lock` over the callback
## table and in-flight list.

import std/[json, locks]
import chronos, chronos/threadsync, results
import stew/byteutils
import brokers/broker_context
import
  logos_delivery/waku/waku_core/message/message,
  logos_delivery/waku/requests/rln_requests,
  ./types
from logos_delivery/waku/rln/rln_evm/proof import toRLNSignal

export types

type
  LogosDeliveryRlnGetMembershipStateFn* =
    proc(reqId: uint64, userData: pointer) {.cdecl, gcsafe, raises: [].}

  LogosDeliveryRlnGetEpochQuotaFn* = proc(
    reqId: uint64, timestamp: uint64, userData: pointer
  ) {.cdecl, gcsafe, raises: [].}

  LogosDeliveryRlnGenerateProofFn* = proc(
    reqId: uint64, signalHex: cstring, timestamp: uint64, userData: pointer
  ) {.cdecl, gcsafe, raises: [].}

  LogosDeliveryRlnValidateProofFn* = proc(
    reqId: uint64,
    signalHex: cstring,
    timestamp: uint64,
    proofJson: cstring,
    userData: pointer,
  ) {.cdecl, gcsafe, raises: [].}

  LogosDeliveryRlnPlugin* = object
    get_membership_state*: LogosDeliveryRlnGetMembershipStateFn
    get_epoch_quota*: LogosDeliveryRlnGetEpochQuotaFn
    generate_proof*: LogosDeliveryRlnGenerateProofFn
    validate_proof*: LogosDeliveryRlnValidateProofFn

  Pending = object
    reqId: uint64
    signal: ThreadSignalPtr # how the awaiting call gets woken
    resultBuf: cstring # allocShared copy of the host's JSON result; nil until answered
    completed: bool
    next: ptr Pending # intrusive in-flight list — no GC memory, cross-thread safe

var
  gLock: Lock
  gPlugin: LogosDeliveryRlnPlugin # all-nil struct = "no plugin installed"
  gUserData: pointer
  gPending: ptr Pending # head of the in-flight request list
  gNextReqId: uint64
  gRegistered: bool # a plugin has been installed

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
  # Per-call response budgets. Add 10s to each request's documented worst case.
  RlnLocalTimeout = 10.seconds
  RlnRegistryReadTimeout = 80.seconds

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
  if not answered:
    return err("timeout")
  if not p.completed:
    return err("RLN module unregistered while awaiting response")
  return ok($p.resultBuf)

# --- outbound calls (one per RLN function) ------------------------------------
# Each: allocate + register a pending node, capture its callback + userData under
# the lock, fire the callback (outside the lock, so a synchronous host response
# can't deadlock), then await the JSON result.

proc rlnGetMembershipState*(): Future[Result[string, string]] {.
    async: (raises: [CancelledError])
.} =
  var cb: LogosDeliveryRlnGetMembershipStateFn
  var ud: pointer
  let pending = newPending()
  if pending.isNil:
    return err("failed to allocate RLN request")
  withLock gLock:
    cb = gPlugin.get_membership_state
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(pending.reqId, ud)
  return await awaitResult(pending, RlnRegistryReadTimeout)

proc rlnGetEpochQuota*(
    timestamp: uint64
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  var cb: LogosDeliveryRlnGetEpochQuotaFn
  var ud: pointer
  let pending = newPending()
  if pending.isNil:
    return err("failed to allocate RLN request")
  withLock gLock:
    cb = gPlugin.get_epoch_quota
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(pending.reqId, timestamp, ud)
  return await awaitResult(pending, RlnLocalTimeout)

proc rlnGenerateProof*(
    signalHex: string, timestamp: uint64
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  var cb: LogosDeliveryRlnGenerateProofFn
  var ud: pointer
  let pending = newPending()
  if pending.isNil:
    return err("failed to allocate RLN request")
  withLock gLock:
    cb = gPlugin.generate_proof
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(pending.reqId, signalHex.cstring, timestamp, ud)
  return await awaitResult(pending, RlnRegistryReadTimeout)

proc rlnValidateProof*(
    signalHex: string, timestamp: uint64, proofJson: string
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  var cb: LogosDeliveryRlnValidateProofFn
  var ud: pointer
  let pending = newPending()
  if pending.isNil:
    return err("failed to allocate RLN request")
  withLock gLock:
    cb = gPlugin.validate_proof
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(pending.reqId, signalHex.cstring, timestamp, proofJson.cstring, ud)
  return await awaitResult(pending, RlnLocalTimeout)

# --- C entry points -----------------------------------------------------------

proc logosdelivery_rln_set_plugin*(
    plugin: ptr LogosDeliveryRlnPlugin, userData: pointer
): cint {.exportc, cdecl, dynlib.} =
  # copy the struct (or clear on nil), stash userData; nil fails all pending
  withLock gLock:
    if plugin.isNil:
      gPlugin = LogosDeliveryRlnPlugin()
      gUserData = nil
      gRegistered = false
      var p = gPending
      while not p.isNil:
        p.completed = false # signals "module cleared", not a real completion
        discard p.signal.fireSync()
        p = p.next
    else:
      gPlugin = plugin[]
      gUserData = userData
      gRegistered = true
    return 0

proc rlnPluginRegistered*(): bool =
  ## Whether the host has installed an RLN plugin. This is what enables RLN
  ## over it: there is no separate configuration switch.
  withLock gLock:
    result = gRegistered

proc logosdelivery_rln_response*(
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
# Two dialects (see liblogosdelivery_rln.h): `result` methods answer with the
# {"success","value","error"} envelope, `tstr` methods with compact JSON and an
# in-band {"error":{...}}. Decode failures map to Transient.

proc toRlnError(errNode: JsonNode): RlnError =
  let kind =
    case errNode{"class"}.getStr("transient")
    of "not_ready": RlnErrorKind.NotReady
    of "budget_exhausted": RlnErrorKind.BudgetExhausted
    of "permanent": RlnErrorKind.Permanent
    else: RlnErrorKind.Transient
  var msg = errNode{"message"}.getStr("")
  let wireKind = errNode{"kind"}.getStr("")
  if wireKind.len > 0:
    msg.add " (kind: " & wireKind & ")"
  RlnError.init(kind, msg)

proc parseRlnVerdict(s: string): Result[ProofVerdict, RlnError] =
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
    err(RlnError.transient("unknown verdict: " & s))

proc parseRlnJson(resultJson: string): Result[JsonNode, RlnError] =
  ## Parses a module reply, tolerating the SDK's known double-encoding quirk
  ## (a JSON string containing the actual JSON reply).
  var node =
    try:
      parseJson(resultJson)
    except CatchableError as e:
      return err(RlnError.transient("invalid module reply JSON: " & e.msg))
  if node.kind == JString:
    try:
      node = parseJson(node.getStr())
    except CatchableError:
      return err(RlnError.transient("module reply is a plain string: " & node.getStr()))
  if node.kind != JObject:
    return err(RlnError.transient("module reply is not a JSON object"))
  ok(node)

proc parseRlnResultEnvelope*(resultJson: string): Result[JsonNode, RlnError] =
  ## `result`-dialect reply: returns the envelope's `value` on success.
  let node = ?parseRlnJson(resultJson)
  if not node.hasKey("success"):
    return err(RlnError.transient("module reply has no success field"))
  if not node{"success"}.getBool(false):
    let errField = node{"error"}
    if not errField.isNil() and errField.kind == JString:
      let errObj =
        try:
          parseJson(errField.getStr())
        except CatchableError:
          return err(RlnError.transient(errField.getStr()))
      return err(toRlnError(errObj))
    return err(RlnError.transient("module call failed with no error detail"))
  var value = node{"value"}
  if value.isNil():
    return err(RlnError.transient("module reply has no value field"))
  if value.kind == JString:
    # the value itself may arrive JSON-encoded; a genuine string stays as-is
    try:
      value = parseJson(value.getStr())
    except CatchableError:
      discard
  ok(value)

proc parseRlnTstrReply*(resultJson: string): Result[JsonNode, RlnError] =
  ## `tstr`-dialect reply: the compact JSON object, or the in-band error.
  let node = ?parseRlnJson(resultJson)
  if node.hasKey("error"):
    return err(toRlnError(node{"error"}))
  ok(node)

proc parseRlnValidationResult*(resultJson: string): Result[ValidationResult, RlnError] =
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
      return err(RlnError.transient("recovered_secret is not a 32-byte hex string"))
    validation.recoveredSecret = some(secret)
  return ok(validation)

proc parseRlnGeneratedProof*(resultJson: string): Result[seq[byte], RlnError] =
  ## generate_proof reply: a result envelope whose value carries
  ## "proof_canonical" — the full zerokit serialization as hex, the one blob
  ## a message carries and validate_proof accepts alone.
  let value = ?parseRlnResultEnvelope(resultJson)
  let hexStr = value{"proof_canonical"}.getStr("")
  if hexStr.len == 0:
    return err(RlnError.transient("generate_proof reply carries no proof_canonical"))
  try:
    return ok(hexToSeqByte(hexStr))
  except ValueError as e:
    return err(RlnError.transient("proof_canonical is not valid hex: " & e.msg))

proc parseRlnEpochQuota*(resultJson: string): Result[EpochQuota, RlnError] =
  ## get_epoch_quota reply: a result envelope whose value is
  ## {"epoch_index","rate_limit","remaining"}.
  let value = ?parseRlnResultEnvelope(resultJson)
  ok(
    EpochQuota(
      epochIndex: value{"epoch_index"}.getBiggestInt(0).uint64,
      rateLimit: value{"rate_limit"}.getBiggestInt(0).uint64,
      remaining: value{"remaining"}.getBiggestInt(0).uint64,
    )
  )

proc parseRlnMembershipStatus(s: string): Result[MembershipStatus, RlnError] =
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
    err(RlnError.transient("unknown membership state: " & s))

proc parseRlnMembershipState*(resultJson: string): Result[MembershipState, RlnError] =
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
      return err(RlnError.transient("membership_hash is not a 32-byte hex string"))
    state.membership = some(
      Membership(
        membershipHash: hash,
        rateLimit: node{"rate_limit"}.getBiggestInt(0).uint64,
        leafIndex: node{"leaf_index"}.getBiggestInt(0).uint64,
      )
    )
  return ok(state)

# --- broker providers ---------------------------------------------------------

proc registerRlnModuleProviders*(
    ctx: BrokerContext, plugin: bool
): Result[void, string] =
  ## Bridges the waku layer's RLN requests onto the FFI plugin surface.
  ## Providers are registered at create time; the underlying calls only succeed
  ## once the host has installed its plugin.
  RequestGetRlnMembershipState.setProvider(
    ctx,
    proc(): Future[Result[RequestGetRlnMembershipState, string]] {.async.} =
      let response = ?await rlnGetMembershipState()
      let state = parseRlnMembershipState(response).valueOr:
        return err($error)
      return ok(RequestGetRlnMembershipState(state: state)),
  ).isOkOr:
    return err("Failed to set RequestGetRlnMembershipState provider: " & error)

  RequestValidateRlnProof.setProvider(
    ctx,
    proc(
        message: WakuMessage, timestamp: uint64
    ): Future[Result[RequestValidateRlnProof, string]] {.async.} =
      let signalHex = message.toRLNSignal().toHex()
      let proofJson = $(%*{"proof": message.proof.toHex()})
      let response = ?await rlnValidateProof(signalHex, timestamp, proofJson)
      let validation = parseRlnValidationResult(response).valueOr:
        return err($error)
      return ok(RequestValidateRlnProof(validation: validation)),
  ).isOkOr:
    return err("Failed to set RequestValidateRlnProof provider: " & error)

  # plugin-gated: the legacy zerokit path registers its own provider for this
  # request type
  if plugin:
    RequestGenerateRlnProof.setProvider(
      ctx,
      proc(
          message: WakuMessage, timestamp: uint64
      ): Future[Result[RequestGenerateRlnProof, string]] {.async.} =
        let signalHex = message.toRLNSignal().toHex()
        let response = ?await rlnGenerateProof(signalHex, timestamp)
        let blob = parseRlnGeneratedProof(response).valueOr:
          return err($error)
        return ok(RequestGenerateRlnProof(proof: blob)),
    ).isOkOr:
      return err("Failed to set RequestGenerateRlnProof provider: " & error)

  return ok()

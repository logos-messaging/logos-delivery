## RLN module wire — how the RLN API backend (`./rln_lez`) asks the host
## its RLN questions, and the decoders for the module's replies.
##
## Each question is a nim-ffi reverse call: `{.ffiReverse.}` encodes the
## parameters as a CBOR map, queues a REVERSE_CALL the host polls
## (`logosdelivery_poll`), and resolves the Future when the host answers
## through `logosdelivery_reverse_reply`. The host owns the registry and the
## membership: it forwards each question to the RLN module over logos-core
## and replies with the module's JSON verbatim, so the parsers below see
## exactly the module's two dialects. Wire names are the proc names in snake
## case. Nothing here owns a thread, a lock or shared memory; a question the
## host never answers fails with a timeout.
##
## Whether a host answers at all is declared at node creation
## (`rlnPluginRegistered`): the constructor's `rlnPlugin` flag replaces the
## callback table the host used to install, and it is what enables RLN.
##
## A build without the poll model (the apps, the tests) has no host to ask:
## every question fails NotReady, unless a test installed `rlnFakeHost`.

{.push raises: [].}

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

type RlnAnswer* = Future[Result[string, string]].Raising([CancelledError])
  ## What a question resolves to: the module's JSON reply text, or a
  ## wire-level failure. Only cancellation escapes.

const NotRegistered* = "RLN module not registered"

var gRlnPlugin: bool
  ## Set once at node creation, on the host's thread; read when the node is
  ## built. A bool needs no lock.

proc setRlnPluginRegistered*(registered: bool) =
  gRlnPlugin = registered

proc rlnPluginRegistered*(): bool =
  ## Whether the host answers RLN questions. This is what enables RLN over
  ## the wire: there is no separate configuration switch.
  gRlnPlugin

when defined(ffiPollMode):
  import ffi

  # `{.ffiReverse.}` reads the return type as written: spelled out, not the alias.
  proc rlnGetMembershipState*(): Future[Result[string, string]] {.ffiReverse.}
  proc rlnGetEpochQuota*(timestamp: uint64): Future[Result[string, string]] {.ffiReverse.}
  proc rlnGenerateProof*(
    signalHex: string, timestamp: uint64
  ): Future[Result[string, string]] {.ffiReverse.}
  proc rlnValidateProof*(
    signalHex: string, timestamp: uint64, proofJson: string
  ): Future[Result[string, string]] {.ffiReverse.}
else:
  type RlnFakeHost* = object
    ## A test's stand-in for the host: an entry left nil answers NotReady.
    getMembershipState*: proc(): RlnAnswer {.gcsafe, raises: [].}
    getEpochQuota*: proc(timestamp: uint64): RlnAnswer {.gcsafe, raises: [].}
    generateProof*: proc(signalHex: string, timestamp: uint64): RlnAnswer {.gcsafe, raises: [].}
    validateProof*:
      proc(signalHex: string, timestamp: uint64, proofJson: string): RlnAnswer {.gcsafe, raises: [].}

  var rlnFakeHost*: RlnFakeHost

  proc notRegistered(): RlnAnswer =
    let fut = RlnAnswer.init("rln wire: not registered")
    fut.complete(Result[string, string].err(NotRegistered))
    return fut

  template host(): RlnFakeHost =
    {.cast(gcsafe).}:
      rlnFakeHost

  proc rlnGetMembershipState*(): RlnAnswer =
    if host().getMembershipState.isNil: notRegistered() else: host().getMembershipState()
  proc rlnGetEpochQuota*(timestamp: uint64): RlnAnswer =
    if host().getEpochQuota.isNil: notRegistered() else: host().getEpochQuota(timestamp)
  proc rlnGenerateProof*(signalHex: string, timestamp: uint64): RlnAnswer =
    if host().generateProof.isNil: notRegistered()
    else: host().generateProof(signalHex, timestamp)
  proc rlnValidateProof*(signalHex: string, timestamp: uint64, proofJson: string): RlnAnswer =
    if host().validateProof.isNil: notRegistered()
    else: host().validateProof(signalHex, timestamp, proofJson)

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

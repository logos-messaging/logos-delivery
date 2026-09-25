## RLN module wire — how the RLN API backend (`./rln_lez`) asks the host
## its RLN questions, and the decoders for the module's replies.
##
## Each question is a nim-ffi reverse call: `{.ffiReverse.}` encodes the
## parameters as a CBOR map, queues a REVERSE_CALL the host polls
## (`logosdelivery_poll`), and resolves the Future when the host answers
## through `logosdelivery_reverse_reply`. The host forwards each one to the
## RLN module over logos-core and replies with the module's JSON verbatim, so
## the parsers below see exactly the module's two dialects. Wire names are the
## proc names in snake case. Nothing here owns a thread, a lock or shared
## memory; a question the host never answers fails with a timeout.
##
## A build without the poll model (the apps, the tests) has no host to ask:
## every question fails NotReady, unless a test installed `rlnFakeHost`.
##
## Membership is keyed by two identifiers carried on nearly every call:
## `registryId` is a CAIP-10 account identifier (`namespace:reference:account_address`)
## and `rlnIdentifier` is a 32-byte per-application identifier.

{.push raises: [].}

import std/json
import chronos, results
import stew/byteutils
import ./types

type
  RlnAnswer* = Future[Result[string, string]]
    ## What a question resolves to: the module's JSON reply text, or a
    ## wire-level failure.
  RlnReply* = Future[Result[string, string]].Raising([CancelledError])

const NotRegistered* = "RLN module not registered"

when defined(ffiPollMode):
  import ffi

  # `{.ffiReverse.}` reads the return type as written: spelled out, not the alias.

  proc rlnStart*(configJson: string): Future[Result[string, string]] {.ffiReverse.}
  proc rlnStop*(): Future[Result[string, string]] {.ffiReverse.}
  proc rlnRegisterMembership*(
    registryId: string, rlnIdentifierHex: string, optionsJson: string
  ): Future[Result[string, string]] {.ffiReverse.}
  proc rlnGetMembershipState*(
    registryId: string, rlnIdentifierHex: string
  ): Future[Result[string, string]] {.ffiReverse.}
  proc rlnGetEpochQuota*(
    registryId: string, rlnIdentifierHex: string, timestamp: uint64
  ): Future[Result[string, string]] {.ffiReverse.}
  proc rlnGenerateProof*(
    registryId: string, rlnIdentifierHex: string, signalHex: string, timestamp: uint64
  ): Future[Result[string, string]] {.ffiReverse.}
  proc rlnValidateProof*(
    registryId: string,
    rlnIdentifierHex: string,
    signalHex: string,
    timestamp: uint64,
    proofJson: string,
  ): Future[Result[string, string]] {.ffiReverse.}
else:
  type RlnFakeHost* = object
    ## A test's stand-in for the host: an entry left nil answers NotReady.
    start*: proc(configJson: string): RlnAnswer {.gcsafe, raises: [].}
    stop*: proc(): RlnAnswer {.gcsafe, raises: [].}
    register*: proc(registryId, rlnIdentifierHex, optionsJson: string): RlnAnswer {.gcsafe, raises: [].}
    getMembershipState*: proc(registryId, rlnIdentifierHex: string): RlnAnswer {.gcsafe, raises: [].}
    getEpochQuota*: proc(registryId, rlnIdentifierHex: string, timestamp: uint64): RlnAnswer {.gcsafe, raises: [].}
    generateProof*: proc(registryId, rlnIdentifierHex, signalHex: string, timestamp: uint64): RlnAnswer {.gcsafe, raises: [].}
    validateProof*: proc(
      registryId, rlnIdentifierHex, signalHex: string, timestamp: uint64, proofJson: string
    ): RlnAnswer {.gcsafe, raises: [].}

  var rlnFakeHost*: RlnFakeHost

  proc notRegistered(): RlnAnswer =
    let fut = newFuture[Result[string, string]]("rln wire: not registered")
    fut.complete(Result[string, string].err(NotRegistered))
    return fut

  template host(): RlnFakeHost =
    {.cast(gcsafe).}:
      rlnFakeHost

  proc rlnStart*(configJson: string): RlnAnswer =
    if host().start.isNil: notRegistered() else: host().start(configJson)
  proc rlnStop*(): RlnAnswer =
    if host().stop.isNil: notRegistered() else: host().stop()
  proc rlnRegisterMembership*(registryId, rlnIdentifierHex, optionsJson: string): RlnAnswer =
    if host().register.isNil: notRegistered()
    else: host().register(registryId, rlnIdentifierHex, optionsJson)
  proc rlnGetMembershipState*(registryId, rlnIdentifierHex: string): RlnAnswer =
    if host().getMembershipState.isNil: notRegistered()
    else: host().getMembershipState(registryId, rlnIdentifierHex)
  proc rlnGetEpochQuota*(registryId, rlnIdentifierHex: string, timestamp: uint64): RlnAnswer =
    if host().getEpochQuota.isNil: notRegistered()
    else: host().getEpochQuota(registryId, rlnIdentifierHex, timestamp)
  proc rlnGenerateProof*(
      registryId, rlnIdentifierHex, signalHex: string, timestamp: uint64
  ): RlnAnswer =
    if host().generateProof.isNil: notRegistered()
    else: host().generateProof(registryId, rlnIdentifierHex, signalHex, timestamp)
  proc rlnValidateProof*(
      registryId, rlnIdentifierHex, signalHex: string, timestamp: uint64, proofJson: string
  ): RlnAnswer =
    if host().validateProof.isNil: notRegistered()
    else: host().validateProof(registryId, rlnIdentifierHex, signalHex, timestamp, proofJson)

proc ask*(question: RlnAnswer): RlnReply =
  ## The generated procs answer with a plain Future; the backend's procs only
  ## raise CancelledError, so a failure becomes the Result's error and
  ## cancelling the backend's future cancels the question. Goes away once
  ## nim-ffi annotates the reverse procs' raises.
  let fut = RlnReply.init("rln question")
  question.addCallback(
    proc(udata: pointer) {.gcsafe, raises: [].} =
      if fut.finished():
        return
      if question.completed():
        fut.complete(question.value())
      elif question.cancelled():
        fut.complete(Result[string, string].err("cancelled"))
      else:
        fut.complete(Result[string, string].err(question.error.msg))
  )
  fut.cancelCallback = proc(udata: pointer) {.gcsafe, raises: [].} =
    question.cancelSoon()
  return fut

# --- reply parsing ------------------------------------------------------------
# Module replies follow the RLN module's own wire bindings, 
# split by the method's declared return type:
# - `result` methods (start, stop, generate_proof, validate_proof,
#   get_epoch_quota) answer with the LogosResult envelope
#   {"success":bool,"value":<reply>,"error":<string>}; on failure `error` is
#   the JSON-encoded typed object {"class","kind","message"}.
# - `tstr` methods (register, get_membership_state) answer with compact JSON;
#   failures are the in-band envelope {"error":{"class",...}}.
# `class` is the spec's RlnErrorKind, lowercase: not_ready | transient |
# budget_exhausted | permanent. Decode failures map to Transient (retry
# permitted; the module may answer coherently next time).

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

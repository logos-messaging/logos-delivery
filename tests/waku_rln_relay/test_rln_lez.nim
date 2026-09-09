{.used.}

## Drives `RlnLez` (the RlnInterface backend over the module-API FFI
## crossing) against a fake host: real C entry points, canned wire replies
## answered synchronously through `logosdelivery_rln_response`. Covers both
## wire dialects, both error paths (transport-level and module-level), and the
## canonical-proof round trip.

import std/strutils
import testutils/unittests, chronos

import logos_delivery/waku/rln/rln_lez/rln_lez
import logos_delivery/waku/rln/rln_lez/transport

const
  OkEnvelope = """{"error":null,"success":true,"value":{"started":true}}"""
  QuotaReply =
    """{"error":null,"success":true,"value":{"epoch_index":42,"rate_limit":100,"remaining":99}}"""
  StateReply =
    """{"state":"active","membership_hash":"""" & repeat("aa", 32) &
    """","rate_limit":100,"leaf_index":7}"""
  RegisterReply = """{"state":"pending"}"""
  NotReadyEnvelope =
    """{"success":false,"error":"{\"class\":\"not_ready\",\"kind\":\"module_stopped\",\"message\":\"not started\"}"}"""

let
  ProofHex = repeat("ab", RlnProofSize)
  GenerateReply =
    """{"error":null,"success":true,"value":{"proof_canonical":"""" & ProofHex &
    """"}}"""
  ViolationReply =
    """{"error":null,"success":true,"value":{"verdict":"rate_limit_violation","recovered_secret":"""" &
    repeat("cd", 32) & """"}}"""

# The fake host: each callback answers its canned reply immediately, on the
# caller's thread (the crossing explicitly supports a synchronous response).
var
  gStartReply = OkEnvelope
  gValidateReply = ViolationReply
  gLastRegistryId = ""

proc fakeStart(
    reqId: uint64, configJson: cstring, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe), cast(raises: []).}:
    discard logosdelivery_rln_response(reqId, gStartReply.cstring)

proc fakeStop(reqId: uint64, userData: pointer) {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe), cast(raises: []).}:
    discard logosdelivery_rln_response(reqId, OkEnvelope.cstring)

proc fakeRegister(
    reqId: uint64,
    registryId, rlnIdentifier: cstring,
    optionsJson: cstring,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe), cast(raises: []).}:
    gLastRegistryId = $registryId
    discard logosdelivery_rln_response(reqId, RegisterReply.cstring)

proc fakeGetState(
    reqId: uint64, registryId, rlnIdentifier: cstring, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe), cast(raises: []).}:
    discard logosdelivery_rln_response(reqId, StateReply.cstring)

proc fakeGetQuota(
    reqId: uint64,
    registryId, rlnIdentifier: cstring,
    timestamp: uint64,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe), cast(raises: []).}:
    discard logosdelivery_rln_response(reqId, QuotaReply.cstring)

proc fakeGenerate(
    reqId: uint64,
    registryId, rlnIdentifier, signalHex: cstring,
    timestamp: uint64,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe), cast(raises: []).}:
    discard logosdelivery_rln_response(reqId, GenerateReply.cstring)

proc fakeValidate(
    reqId: uint64,
    registryId, rlnIdentifier, signalHex: cstring,
    timestamp: uint64,
    proofJson: cstring,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe), cast(raises: []).}:
    discard logosdelivery_rln_response(reqId, gValidateReply.cstring)

var gCallbacks = LogosDeliveryRlnCallbacks(
  start: fakeStart,
  stop: fakeStop,
  register_membership: fakeRegister,
  get_membership_state: fakeGetState,
  get_epoch_quota: fakeGetQuota,
  generate_proof: fakeGenerate,
  validate_proof: fakeValidate,
)

suite "RlnLez - RlnInterface over the module FFI crossing":
  var rlnId: RlnIdentifier
  rlnId[0] = 1'u8
  let
    scope = MembershipScope.init("logos:testnet:0", rlnId)
    timestamp = 1_700_000_000'u64
    configJson = """{"epoch_size_sec":120,"registries":["logos:testnet:0"]}"""
    rlnLez = RlnLez.init()

  test "unregistered host fails NotReady":
    let res = waitFor rlnLez.start(configJson)
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.NotReady

  test "start and stop round-trip the result envelope":
    check logosdelivery_rln_set_callbacks(addr gCallbacks, nil) == 0
    check:
      (waitFor rlnLez.start(configJson)).isOk()
      (waitFor rlnLez.stop()).isOk()

  test "module-level failure decodes into the typed error":
    gStartReply = NotReadyEnvelope
    defer:
      gStartReply = OkEnvelope
    let res = waitFor rlnLez.start(configJson)
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.NotReady
      "module_stopped" in res.error.message

  test "registerMembership submits and reports the pending state":
    let options = @[RegistryOption(key: "rate_limit", value: "100")]
    let state = (waitFor rlnLez.registerMembership(scope, options)).valueOr:
      raiseAssert $error
    check:
      state.status == MembershipStatus.Pending
      gLastRegistryId == scope.registryId

  test "getMembershipState decodes the tstr reply":
    let state = (waitFor rlnLez.getMembershipState(scope)).valueOr:
      raiseAssert $error
    check:
      state.status == MembershipStatus.Active
      state.membership.isSome()
      state.membership.get().rateLimit == 100
      state.membership.get().leafIndex == 7

  test "getEpochQuota decodes the envelope value":
    let quota = (waitFor rlnLez.getEpochQuota(scope, timestamp)).valueOr:
      raiseAssert $error
    check:
      quota.epochIndex == 42
      quota.rateLimit == 100
      quota.remaining == 99

  test "generateProof carries the canonical blob":
    let proof = (waitFor rlnLez.generateProof(scope, @[1'u8, 2, 3], timestamp)).valueOr:
      raiseAssert $error
    check:
      proof.proof[0] == 0xab'u8
      proof.proof[RlnProofSize - 1] == 0xab'u8

  test "validateProof decodes verdict and recovered secret":
    let generated = (waitFor rlnLez.generateProof(scope, @[1'u8, 2, 3], timestamp)).valueOr:
      raiseAssert $error
    let validation = (
      waitFor rlnLez.validateProof(scope, @[1'u8, 2, 3], timestamp, generated)
    ).valueOr:
      raiseAssert $error
    check:
      validation.verdict == ProofVerdict.RateLimitViolation
      validation.recoveredSecret.isSome()
      validation.recoveredSecret.get()[0] == 0xcd'u8

    gValidateReply = """{"error":null,"success":true,"value":{"verdict":"valid"}}"""
    let valid = (
      waitFor rlnLez.validateProof(scope, @[1'u8, 2, 3], timestamp, generated)
    ).valueOr:
      raiseAssert $error
    check:
      valid.verdict == ProofVerdict.Valid
      valid.recoveredSecret.isNone()

  test "clearing the host callbacks returns the backend to NotReady":
    check logosdelivery_rln_set_callbacks(nil, nil) == 0
    let res = waitFor rlnLez.getEpochQuota(scope, timestamp)
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.NotReady

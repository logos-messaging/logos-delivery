{.used.}

## Drives `RlnLez` (the RlnInterface backend over the RLN plugin FFI crossing)
## against a fake host: real C entry points, canned wire replies answered
## synchronously through `logosdelivery_rln_response`. Covers both wire
## dialects, both error paths (transport-level and module-level), and the
## canonical-proof round trip.

import std/strutils
import testutils/unittests, chronos

import logos_delivery/waku/rln/rln_lez/rln_lez
import logos_delivery/waku/rln/rln_lez/transport

const
  QuotaReply =
    """{"error":null,"success":true,"value":{"epoch_index":42,"rate_limit":100,"remaining":99}}"""
  StateReply =
    """{"state":"active","membership_hash":"""" & repeat("aa", 32) &
    """","rate_limit":100,"leaf_index":7}"""
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
# No callback carries a registry, a membership or any configuration.
var
  gQuotaReply = QuotaReply
  gValidateReply = ViolationReply

proc fakeGetState(reqId: uint64, userData: pointer) {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe), cast(raises: []).}:
    discard logosdelivery_rln_response(reqId, StateReply.cstring)

proc fakeGetQuota(
    reqId: uint64, timestamp: uint64, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe), cast(raises: []).}:
    discard logosdelivery_rln_response(reqId, gQuotaReply.cstring)

proc fakeGenerate(
    reqId: uint64, signalHex: cstring, timestamp: uint64, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe), cast(raises: []).}:
    discard logosdelivery_rln_response(reqId, GenerateReply.cstring)

proc fakeValidate(
    reqId: uint64,
    signalHex: cstring,
    timestamp: uint64,
    proofJson: cstring,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe), cast(raises: []).}:
    discard logosdelivery_rln_response(reqId, gValidateReply.cstring)

var gPlugin = LogosDeliveryRlnPlugin(
  get_membership_state: fakeGetState,
  get_epoch_quota: fakeGetQuota,
  generate_proof: fakeGenerate,
  validate_proof: fakeValidate,
)

suite "RlnLez - RlnInterface over the RLN plugin FFI crossing":
  let
    timestamp = 1_700_000_000'u64
    rlnLez = RlnLez.init()

  test "no plugin installed fails NotReady":
    check logosdelivery_rln_set_plugin(nil, nil) == 0
    check not rlnPluginRegistered()
    let res = waitFor rlnLez.getEpochQuota(timestamp)
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.NotReady

  test "installing the plugin enables the backend":
    check logosdelivery_rln_set_plugin(addr gPlugin, nil) == 0
    check rlnPluginRegistered()

  test "module-level failure decodes into the typed error":
    gQuotaReply = NotReadyEnvelope
    defer:
      gQuotaReply = QuotaReply
    let res = waitFor rlnLez.getEpochQuota(timestamp)
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.NotReady
      "module_stopped" in res.error.message

  test "getMembershipState decodes the tstr reply":
    let state = (waitFor rlnLez.getMembershipState()).valueOr:
      raiseAssert $error
    check:
      state.status == MembershipStatus.Active
      state.membership.isSome()
      state.membership.get().rateLimit == 100
      state.membership.get().leafIndex == 7

  test "verifyMembership caches a usable membership":
    let rln = RlnLez.init()
    check not rln.membershipVerified
    let status = (waitFor rln.verifyMembership()).valueOr:
      raiseAssert $error
    check:
      status == MembershipStatus.Active
      rln.membershipVerified

  test "getEpochQuota decodes the envelope value":
    let quota = (waitFor rlnLez.getEpochQuota(timestamp)).valueOr:
      raiseAssert $error
    check:
      quota.epochIndex == 42
      quota.rateLimit == 100
      quota.remaining == 99

  test "generateProof carries the canonical blob":
    let proof = (waitFor rlnLez.generateProof(@[1'u8, 2, 3], timestamp)).valueOr:
      raiseAssert $error
    check:
      proof.proof[0] == 0xab'u8
      proof.proof[RlnProofSize - 1] == 0xab'u8

  test "validateProof decodes verdict and recovered secret":
    let generated = (waitFor rlnLez.generateProof(@[1'u8, 2, 3], timestamp)).valueOr:
      raiseAssert $error
    let validation = (waitFor rlnLez.validateProof(@[1'u8, 2, 3], timestamp, generated)).valueOr:
      raiseAssert $error
    check:
      validation.verdict == ProofVerdict.RateLimitViolation
      validation.recoveredSecret.isSome()
      validation.recoveredSecret.get()[0] == 0xcd'u8

    gValidateReply = """{"error":null,"success":true,"value":{"verdict":"valid"}}"""
    let valid = (waitFor rlnLez.validateProof(@[1'u8, 2, 3], timestamp, generated)).valueOr:
      raiseAssert $error
    check:
      valid.verdict == ProofVerdict.Valid
      valid.recoveredSecret.isNone()

  test "clearing the plugin returns the backend to NotReady":
    check logosdelivery_rln_set_plugin(nil, nil) == 0
    let res = waitFor rlnLez.getEpochQuota(timestamp)
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.NotReady

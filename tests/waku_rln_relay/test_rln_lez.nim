{.used.}

## Drives `RlnLez` (the RlnInterface backend over the RLN wire) against a fake
## host: the wire's `rlnFakeHost` (a build without the poll model has no real
## host), whose entries answer canned module replies at once. Covers both wire
## dialects, both error paths (wire-level and module-level), and the
## canonical-proof round trip.

import std/strutils
import testutils/unittests, chronos

import logos_delivery/waku/rln/rln_lez/rln_lez
import logos_delivery/waku/rln/rln_lez/wire

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

# The fake host: each wire entry answers its canned reply immediately, as an
# already-completed Future. No entry carries a registry, a membership or any
# configuration: the host owns those.
var
  gQuotaReply = QuotaReply
  gValidateReply = ViolationReply

proc canned(reply: string): RlnAnswer =
  let fut = newFuture[Result[string, string]]("fake rln host")
  fut.complete(Result[string, string].ok(reply))
  return fut

proc fakeHost(): RlnFakeHost =
  RlnFakeHost(
    getMembershipState: proc(): RlnAnswer {.gcsafe.} =
      {.cast(gcsafe).}:
        canned(StateReply),
    getEpochQuota: proc(timestamp: uint64): RlnAnswer {.gcsafe.} =
      {.cast(gcsafe).}:
        canned(gQuotaReply),
    generateProof: proc(signalHex: string, timestamp: uint64): RlnAnswer {.gcsafe.} =
      {.cast(gcsafe).}:
        canned(GenerateReply),
    validateProof: proc(signalHex: string, timestamp: uint64, proofJson: string): RlnAnswer {.gcsafe.} =
      {.cast(gcsafe).}:
        canned(gValidateReply),
  )

suite "RlnLez - RlnInterface over the RLN wire":
  let
    timestamp = 1_700_000_000'u64
    rlnLez = RlnLez.init()

  test "no host fails NotReady":
    setRlnPluginRegistered(false)
    rlnFakeHost = RlnFakeHost()
    check not rlnPluginRegistered()
    let res = waitFor rlnLez.getEpochQuota(timestamp)
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.NotReady

  test "a host that answers enables the backend":
    setRlnPluginRegistered(true)
    rlnFakeHost = fakeHost()
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
    setRlnPluginRegistered(false)
    rlnFakeHost = RlnFakeHost()
    let res = waitFor rlnLez.getEpochQuota(timestamp)
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.NotReady

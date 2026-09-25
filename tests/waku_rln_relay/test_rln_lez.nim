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

# The fake host: each wire entry answers its canned reply immediately, as an
# already-completed Future (the host may well answer before the caller awaits).
var
  gStartReply = OkEnvelope
  gValidateReply = ViolationReply
  gLastRegistryId = ""

proc canned(reply: string): RlnAnswer =
  let fut = newFuture[Result[string, string]]("fake rln host")
  fut.complete(Result[string, string].ok(reply))
  return fut

proc fakeHost(): RlnFakeHost =
  RlnFakeHost(
    start: proc(configJson: string): RlnAnswer {.gcsafe.} =
      {.cast(gcsafe).}:
        canned(gStartReply),
    stop: proc(): RlnAnswer {.gcsafe.} =
      {.cast(gcsafe).}:
        canned(OkEnvelope),
    register: proc(registryId, rlnIdentifierHex, optionsJson: string): RlnAnswer {.gcsafe.} =
      {.cast(gcsafe).}:
        gLastRegistryId = registryId
      canned(RegisterReply),
    getMembershipState: proc(registryId, rlnIdentifierHex: string): RlnAnswer {.gcsafe.} =
      {.cast(gcsafe).}:
        canned(StateReply),
    getEpochQuota: proc(registryId, rlnIdentifierHex: string, timestamp: uint64): RlnAnswer {.gcsafe.} =
      {.cast(gcsafe).}:
        canned(QuotaReply),
    generateProof: proc(
        registryId, rlnIdentifierHex, signalHex: string, timestamp: uint64
    ): RlnAnswer {.gcsafe.} =
      {.cast(gcsafe).}:
        canned(GenerateReply),
    validateProof: proc(
        registryId, rlnIdentifierHex, signalHex: string,
        timestamp: uint64,
        proofJson: string,
    ): RlnAnswer {.gcsafe.} =
      {.cast(gcsafe).}:
        canned(gValidateReply),
  )

suite "RlnLez - RlnInterface over the RLN wire":
  var rlnId: RlnIdentifier
  rlnId[0] = 1'u8
  let
    scope = MembershipScope.init("logos:testnet:0", rlnId)
    timestamp = 1_700_000_000'u64
    configJson = """{"epoch_size_sec":120,"registries":["logos:testnet:0"]}"""
    m = RlnLez.init()

  test "unregistered host fails NotReady":
    let res = waitFor m.start(configJson)
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.NotReady

  test "start and stop round-trip the result envelope":
    rlnFakeHost = fakeHost()
    check:
      (waitFor m.start(configJson)).isOk()
      (waitFor m.stop()).isOk()

  test "module-level failure decodes into the typed error":
    gStartReply = NotReadyEnvelope
    defer:
      gStartReply = OkEnvelope
    let res = waitFor m.start(configJson)
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.NotReady
      "module_stopped" in res.error.message

  test "registerMembership submits and reports the pending state":
    let options = @[RegistryOption(key: "rate_limit", value: "100")]
    let state = (waitFor m.registerMembership(scope, options)).valueOr:
      raiseAssert $error
    check:
      state.status == MembershipStatus.Pending
      gLastRegistryId == scope.registryId

  test "getMembershipState decodes the tstr reply":
    let state = (waitFor m.getMembershipState(scope)).valueOr:
      raiseAssert $error
    check:
      state.status == MembershipStatus.Active
      state.membership.isSome()
      state.membership.get().rateLimit == 100
      state.membership.get().leafIndex == 7

  test "getEpochQuota decodes the envelope value":
    let quota = (waitFor m.getEpochQuota(scope, timestamp)).valueOr:
      raiseAssert $error
    check:
      quota.epochIndex == 42
      quota.rateLimit == 100
      quota.remaining == 99

  test "generateProof carries the canonical blob":
    let proof = (waitFor m.generateProof(scope, @[1'u8, 2, 3], timestamp)).valueOr:
      raiseAssert $error
    check:
      proof.proof[0] == 0xab'u8
      proof.proof[RlnProofSize - 1] == 0xab'u8

  test "validateProof decodes verdict and recovered secret":
    let generated = (waitFor m.generateProof(scope, @[1'u8, 2, 3], timestamp)).valueOr:
      raiseAssert $error
    let validation = (
      waitFor m.validateProof(scope, @[1'u8, 2, 3], timestamp, generated)
    ).valueOr:
      raiseAssert $error
    check:
      validation.verdict == ProofVerdict.RateLimitViolation
      validation.recoveredSecret.isSome()
      validation.recoveredSecret.get()[0] == 0xcd'u8

    gValidateReply = """{"error":null,"success":true,"value":{"verdict":"valid"}}"""
    let valid = (
      waitFor m.validateProof(scope, @[1'u8, 2, 3], timestamp, generated)
    ).valueOr:
      raiseAssert $error
    check:
      valid.verdict == ProofVerdict.Valid
      valid.recoveredSecret.isNone()

  test "an empty host returns the backend to NotReady":
    rlnFakeHost = RlnFakeHost()
    let res = waitFor m.getEpochQuota(scope, timestamp)
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.NotReady

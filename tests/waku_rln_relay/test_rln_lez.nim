{.used.}

## Drives `RlnLez` (the RlnInterface backend over the RLN plugin FFI crossing)
## against a fake host: real C entry points, canned wire replies answered
## synchronously through `logosdelivery_rln_response`. Covers both wire
## dialects, both error paths (transport-level and module-level), and the
## canonical-proof round trip.

import std/[strutils, json]
import testutils/unittests, chronos

import logos_delivery/waku/rln/rln_lez/rln_lez
import logos_delivery/waku/rln/rln_lez/transport
import logos_delivery/waku/rln/rln_plugin
import logos_delivery/waku/waku_core

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
  gGenerateReply = GenerateReply

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
    discard logosdelivery_rln_response(reqId, gGenerateReply.cstring)

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

  test "the external plugin declares the generated canonical proof length":
    let plugin = rlnLez.toRlnPlugin()
    let message =
      WakuMessage(payload: @[1'u8], timestamp: int64(timestamp) * 1_000_000_000)
    let preview =
      Opt.some(plugin).messageForSizeCheck(message).expect("messageForSizeCheck")
    let proven = (waitFor plugin.generateProof(message)).expect("generateProof")
    check:
      preview.proof.len == proven.len
      message.proof.len == 0

  test "both external proof paths reject malformed host responses":
    defer:
      gGenerateReply = GenerateReply
    let plugin = RlnLez.init().toRlnPlugin()
    let message =
      WakuMessage(payload: @[1'u8], timestamp: int64(timestamp) * 1_000_000_000)
    for (proofHex, reason) in [
      (repeat("ab", RlnProofSize - 1), "bytes, expected " & $RlnProofSize),
      (repeat("ab", RlnProofSize + 1), "bytes, expected " & $RlnProofSize),
      ("", "no proof_canonical"),
      ("zz", "not valid hex"),
    ]:
      gGenerateReply = $(%*{"success": true, "value": {"proof_canonical": proofHex}})
      let typed = waitFor rlnLez.generateProof(@[1'u8], timestamp)
      let adapted = waitFor plugin.generateProof(message)
      check:
        typed.isErr()
        adapted.isErr()
        message.proof.len == 0
      if typed.isErr():
        check:
          typed.error.kind == RlnErrorKind.Transient
          reason in typed.error.message
      if adapted.isErr():
        check:
          adapted.error.kind == RlnErrorKind.Transient
          reason in adapted.error.message

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

var mixRequestId: uint64

proc captureMixRequest(
    reqId: uint64, methodName, argsJson: cstring, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  mixRequestId = reqId

proc checkMixTransport() {.async.} =
  check logosdelivery_mix_rln_set_callback(nil, nil) == 0
  check (await rlnMixCall("validate_proof", newJArray())).isErr()
  check logosdelivery_mix_rln_set_callback(captureMixRequest, nil) == 0
  defer:
    discard logosdelivery_mix_rln_set_callback(nil, nil)
  let pending = rlnMixCall("validate_proof", %*["registry", "scope"])
  check not pending.finished()
  # Relay owns a separate callback lifetime, even in the same library.
  check logosdelivery_rln_set_plugin(nil, nil) == 0
  check logosdelivery_rln_response(mixRequestId, "{}") == 0
  check logosdelivery_rln_response(mixRequestId, "{}") != 0
  check (await pending).isOk()
  let cancelled = rlnMixCall("generate_proof", newJArray())
  let cancelledId = mixRequestId
  await cancelled.cancelAndWait()
  check logosdelivery_rln_response(cancelledId, "{}") != 0
  var requests: seq[Future[Result[JsonNode, string]]]
  for i in 0 ..< 64:
    requests.add(rlnMixCall("generate_proof", newJArray()))
  check (await rlnMixCall("generate_proof", newJArray())).isErr()
  check logosdelivery_mix_rln_set_callback(nil, nil) == 0
  for request in requests:
    check (await request).isErr()

suite "Mix RLN transport":
  test "separate lifecycle, first response wins, cancellation and bounded requests":
    waitFor checkMixTransport()

suite "selectRlnPlugin - rln-relay":
  proc descriptor(name: string, present: bool): RlnPluginDescriptor =
    RlnPluginDescriptor(
      name: name,
      matches: proc(): bool =
        present,
      mount: nil,
    )

  test "unset picks the backend whose source is present":
    let selected = selectRlnPlugin([descriptor("external", true)]).expect("select")
    check selected.isSome() and selected.get().name == "external"

  test "rln-relay=false selects none, though a source is present":
    let selected =
      selectRlnPlugin([descriptor("external", true)], Opt.some(false)).expect("select")
    check selected.isNone()

  test "rln-relay=true with no source present is an error":
    check selectRlnPlugin([descriptor("external", false)], Opt.some(true)).isErr()

  test "rln-relay=true with a source present picks it":
    let selected =
      selectRlnPlugin([descriptor("external", true)], Opt.some(true)).expect("select")
    check selected.isSome()

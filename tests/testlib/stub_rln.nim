{.used.}

## A stub RLN backend and a relay validator that refuse as RLN-invalid, for tests.

import results, chronos, libp2p/protocols/pubsub/pubsub
import
  logos_delivery/waku/
    [waku_core, waku_node, waku_relay, rln, rln/rln_plugin, rln/types as rln_types]

proc rejectFirstMessageAsRlnInvalid*(node: WakuNode) =
  ## Registers a relay validator that rejects the first message it sees with
  ## the RLN validator's error marker, then accepts everything.
  var rejected = false
  node.wakuRelay.addValidator(
    proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[pubsub.ValidationResult] {.async.} =
      if rejected:
        return pubsub.ValidationResult.Accept
      rejected = true
      return pubsub.ValidationResult.Reject,
    RlnValidatorErrorMsg & ": simulated",
  )

type StubRlnCalls* = ref object
  ## How often the node asked the stub RLN backend for a proof or a refresh.
  generateCalls*: int
  refreshCalls*: int

proc mountStubRln*(node: WakuNode, validProof: seq[byte]): StubRlnCalls =
  ## Mounts an RLN backend that accepts only `validProof` and cannot generate
  ## proofs, like a node without a usable membership.
  let calls = StubRlnCalls()

  proc validate(
      message: WakuMessage
  ): Future[Result[rln_types.ValidationResult, RlnError]] {.async.} =
    if message.proof == validProof:
      return ok(rln_types.ValidationResult(verdict: ProofVerdict.Valid))
    return ok(rln_types.ValidationResult(verdict: ProofVerdict.Invalid))

  proc generate(message: WakuMessage): Future[Result[seq[byte], RlnError]] {.async.} =
    calls.generateCalls.inc()
    return err(RlnError.notReady("no usable RLN membership"))

  proc refresh() {.gcsafe, raises: [].} =
    calls.refreshCalls.inc()

  node.mountRln(
    RlnPlugin(
      name: "stub",
      validateProof: validate,
      generateProof: generate,
      onProofRejected: refresh,
    ),
    RlnCommonConf(),
  )
  return calls

{.used.}

import chronos, testutils/unittests, results, libp2p/protocols/pubsub/pubsub

import
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/api/publish,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/waku_relay,
  logos_delivery/waku/rln,
  logos_delivery/api/types,
  logos_delivery/messaging/delivery_service/send_service/transports {.all.}
import ../testlib/[testasync, wakucore, wakunodeconf]

## Tests of how a transport reads the answer of a publish.

type RepeatValidator = ref object
  calls: int
  seen: seq[seq[byte]]

func refusal(code: LightpushStatusCode, desc = "scripted"): WakuLightPushResult =
  return lighpushErrorResult(code, desc)

suite "Send transports - the result of a publish":
  test "a publish to one peer or more is Propagated, and a publish to no peer is not":
    check:
      toAttemptResult(lightpushSuccessResult(1)) == AttemptResult.propagated()
      toAttemptResult(lightpushSuccessResult(0)) == AttemptResult.notPropagated()

  test "a refused RLN proof is NotPropagated, and it asks for a new proof":
    ## The service node, or the relay of this node, did not publish the message.
    let outOfProof = toAttemptResult(refusal(LightPushErrorCode.OUT_OF_RLN_PROOF))
    let invalidProof = toAttemptResult(
      refusal(LightPushErrorCode.INVALID_MESSAGE, RlnValidatorErrorMsg & ": scripted")
    )
    check:
      outOfProof.outcome == AttemptOutcome.NotPropagated
      outOfProof.proofRefused
      invalidProof.outcome == AttemptOutcome.NotPropagated
      invalidProof.proofRefused

  test "a message that the relay already has is Propagated":
    ## An earlier attempt with no answer put the message on the network.
    check toAttemptResult(
      refusal(LightPushErrorCode.INVALID_MESSAGE, AlreadySeenMessageDesc)
    ) == AttemptResult.propagated()

  test "a refusal that can end is NotPropagated with no reason and no new proof":
    ## `send` then reports the end of its attempts, and not the answer of one peer.
    for code in [
      LightPushErrorCode.NO_PEERS_TO_RELAY, LightPushErrorCode.TOO_MANY_REQUESTS,
      LightPushErrorCode.SERVICE_NOT_AVAILABLE, LightPushErrorCode.INTERNAL_SERVER_ERROR,
    ]:
      check toAttemptResult(refusal(code)) == AttemptResult.notPropagated()

  test "a refusal of the message itself is Invalid":
    for code in [
      LightPushErrorCode.BAD_REQUEST, LightPushErrorCode.PAYLOAD_TOO_LARGE,
      LightPushErrorCode.INVALID_MESSAGE, LightPushErrorCode.UNSUPPORTED_PUBSUB_TOPIC,
    ]:
      check toAttemptResult(refusal(code)) == AttemptResult.invalid("scripted")

suite "Send transports - a node with no peer":
  var waku {.threadvar.}: Waku

  asyncSetup:
    let conf = defaultTestWakuNodeConf().toWakuConf().valueOr:
        raiseAssert error
    waku = (await Waku.new(conf)).expect("Waku.new")

  asyncTeardown:
    discard await waku.stop()

  asyncTest "lightpush cannot attempt a message, and says so with no network call":
    let lightpush = Transports.init(waku)[Transport.Lightpush]
    check lightpush.isSome()
    if lightpush.isSome():
      check lightpush.get().checkBeforeAttempt(DefaultPubsubTopic, fakeWakuMessage()) ==
        Opt.some(AttemptResult.notPropagated())

  asyncTest "relay attempts a message, and the attempt is NotPropagated":
    ## A relay with no peer still gives the message to the Store and the filter
    ## clients of this node. So the relay transport must not stop the attempt.
    let relay = Transports.init(waku)[Transport.Relay]
    check relay.isSome()
    if relay.isNone():
      return
    let message = fakeWakuMessage()
    check relay.get().checkBeforeAttempt(DefaultPubsubTopic, message).isNone()
    let res = await relay.get().attempt(DefaultPubsubTopic, message, @[], false)
    check res.outcome == AttemptOutcome.NotPropagated

  asyncTest "relay validates a message one time, and a repeat publishes with no validation":
    ## The RLN validator of a node refuses a proof that it already has. The
    ## validator of this test does the same for a payload.
    let validator = RepeatValidator()
    proc refuseRepeat(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[ValidationResult] {.async.} =
      validator.calls.inc()
      if message.payload in validator.seen:
        return ValidationResult.Reject
      validator.seen.add(message.payload)
      return ValidationResult.Accept

    waku.node.wakuRelay.addValidator(refuseRepeat, RlnValidatorErrorMsg)
    let relay = Transports.init(waku)[Transport.Relay]
    check relay.isSome()
    if relay.isNone():
      return
    let message = fakeWakuMessage()

    let first = await relay.get().attempt(DefaultPubsubTopic, message, @[], false)
    check:
      first.outcome == AttemptOutcome.NotPropagated
      first.validated
      not first.proofRefused
      validator.calls == 1

    let repeat = await relay.get().attempt(DefaultPubsubTopic, message, @[], true)
    check:
      repeat.outcome == AttemptOutcome.NotPropagated
      not repeat.proofRefused
      validator.calls == 1

    # A second validation of the message gives a refused proof.
    let again = await relay.get().attempt(DefaultPubsubTopic, message, @[], false)
    check:
      again.proofRefused
      validator.calls == 2

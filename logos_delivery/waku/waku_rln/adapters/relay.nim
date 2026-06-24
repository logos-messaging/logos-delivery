{.push raises: [].}

import
  std/options,
  chronicles,
  chronos,
  results,
  stew/byteutils,
  libp2p/protocols/pubsub/pubsub

import ../rln, ../protocol_types, ../protocol_metrics, ../conversion_utils

import logos_delivery/waku/[waku_relay, waku_core]

logScope:
  topics = "waku rln_relay adapter"

proc generateRlnValidator*(
    wakuRlnRelay: WakuRln, spamHandler = none(SpamHandler)
): WakuValidatorHandler =
  ## Bridges RLN's protocol-agnostic message validation into a relay
  ## (gossipsub) validator. The core decision is made by
  ## `validateMessageAndUpdateLog`; this adapter maps the result to
  ## `pubsub.ValidationResult` so the validator can be installed on
  ## WakuRelay's validator chain.
  ## Validation logic follows https://rfc.vac.dev/spec/17/
  proc validator(
      topic: string, message: WakuMessage
  ): Future[pubsub.ValidationResult] {.async.} =
    trace "rln-relay topic validator is called"
    wakuRlnRelay.clearNullifierLog()

    let msgProof = RateLimitProof.init(message.proof).valueOr:
      trace "generateRlnValidator reject", error = error
      return pubsub.ValidationResult.Reject

    # validate the message and update log
    let validationRes = await wakuRlnRelay.validateMessageAndUpdateLog(message)

    let
      proof = byteutils.toHex(msgProof.proof)
      epoch = fromEpoch(msgProof.epoch)
      root = inHex(msgProof.merkleRoot)
      shareX = inHex(msgProof.shareX)
      shareY = inHex(msgProof.shareY)
      nullifier = inHex(msgProof.nullifier)
      payload = string.fromBytes(message.payload)
    case validationRes
    of Valid:
      trace "message validity is verified, relaying",
        proof = proof,
        root = root,
        shareX = shareX,
        shareY = shareY,
        nullifier = nullifier
      waku_rln_valid_messages_total.inc(labelValues = [topic])
      return pubsub.ValidationResult.Accept
    of Invalid:
      trace "message validity could not be verified, discarding",
        proof = proof,
        root = root,
        shareX = shareX,
        shareY = shareY,
        nullifier = nullifier
      return pubsub.ValidationResult.Reject
    of Spam:
      trace "A spam message is found! yay! discarding:",
        proof = proof,
        root = root,
        shareX = shareX,
        shareY = shareY,
        nullifier = nullifier
      if spamHandler.isSome():
        let handler = spamHandler.get()
        handler(message)
      return pubsub.ValidationResult.Reject

  return validator

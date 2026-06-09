{.push raises: [].}

import results

import
  ../waku_core,
  ../waku_relay,
  ./common,
  ../waku_rln_relay,
  ../waku_rln_relay/protocol_types

import std/times, libp2p/peerid, stew/byteutils

proc checkAndGenerateRLNProof*(
    rlnPeer: Option[WakuRLNRelay], message: WakuMessage
): Result[WakuMessage, string] =
  # check if the message already has RLN proof
  if message.proof.len > 0:
    return ok(message)

  if rlnPeer.isNone():
    notice "Publishing message without RLN proof"
    return ok(message)
  # generate and append RLN proof
  let
    time = getTime().toUnix()
    senderEpochTime = float64(time)
  var msgWithProof = message
  ?(rlnPeer.get().appendRLNProof(msgWithProof, senderEpochTime))
  return ok(msgWithProof)

proc getNilPushHandler*(): PushMessageHandler =
  return proc(
      pubsubTopic: string, message: WakuMessage
  ): Future[WakuLightPushResult] {.async.} =
    return lightpushResultInternalError("no waku relay found")

proc getRelayPushHandler*(
    wakuRelay: WakuRelay, rlnPeer: Option[WakuRLNRelay] = none[WakuRLNRelay]()
): PushMessageHandler =
  return proc(
      pubsubTopic: string, message: WakuMessage
  ): Future[WakuLightPushResult] {.async.} =
    # append RLN proof
    let msgWithProof = checkAndGenerateRLNProof(rlnPeer, message).valueOr:
      return lighpushErrorResult(LightPushErrorCode.OUT_OF_RLN_PROOF, error)

    (await wakuRelay.validateMessage(pubSubTopic, msgWithProof)).isOkOr:
      return lighpushErrorResult(LightPushErrorCode.INVALID_MESSAGE, $error)

    let publishedResult = (await wakuRelay.publish(pubsubTopic, msgWithProof)).valueOr:
      let msgHash = computeMessageHash(pubsubTopic, message).to0xHex()
      notice "Lightpush request has not been published to any peers",
        msg_hash = msgHash, reason = $error
      return mapPubishingErrorToPushResult(error)

    return lightpushSuccessResult(publishedResult.uint32)

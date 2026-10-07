{.push raises: [].}

import results, chronos, chronicles

import ../waku_core, ../waku_relay, ./common

import libp2p/peerid

proc getNilPushHandler*(): PushMessageHandler =
  return proc(
      pubsubTopic: string, message: WakuMessage
  ): Future[WakuLightPushResult] {.async.} =
    return lightpushResultInternalError("no waku relay found")

proc getRelayPushHandler*(wakuRelay: WakuRelay): PushMessageHandler =
  return proc(
      pubsubTopic: string, message: WakuMessage
  ): Future[WakuLightPushResult] {.async.} =
    let messageSizeBytes = message.encode().len
    if messageSizeBytes > wakuRelay.maxMessageSize:
      return lighpushErrorResult(
        LightPushErrorCode.PAYLOAD_TOO_LARGE,
        "Message size exceeded maximum of: " & $wakuRelay.maxMessageSize & " bytes",
      )

    (await wakuRelay.validateMessage(pubSubTopic, message)).isOkOr:
      return lighpushErrorResult(LightPushErrorCode.INVALID_MESSAGE, $error)

    let publishedResult = (await wakuRelay.publish(pubsubTopic, message)).valueOr:
      let msgHash = computeMessageHash(pubsubTopic, message).to0xHex()
      debug "Lightpush request has not been published to any peers",
        msg_hash = msgHash, reason = $error
      return mapPubishingErrorToPushResult(error)

    return lightpushSuccessResult(publishedResult.uint32)

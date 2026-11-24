{.push raises: [].}

import results, chronos, chronicles

import ../waku_core, ../waku_relay, ./common

import libp2p/peerid

proc getNilPushHandler*(): PushMessageHandler =
  return proc(
      pubsubTopic: string, message: WakuMessage
  ): Future[WakuLightPushResult] {.async.} =
    return lightpushResultInternalError("no waku relay found")

proc getRelayPushHandler*(
    wakuRelay: WakuRelay, handleAsReceived = false
): PushMessageHandler =
  ## `handleAsReceived` is for the lightpush server: the messages it publishes are
  ## its clients', so its own subscribers receive them (see `WakuRelay.publish`).
  return proc(
      pubsubTopic: string, message: WakuMessage
  ): Future[WakuLightPushResult] {.async.} =
    let messageSizeBytes = message.encode().len
    if messageSizeBytes > wakuRelay.maxEncodedMessageSize:
      return lighpushErrorResult(
        LightPushErrorCode.PAYLOAD_TOO_LARGE,
        "Message size exceeded maximum of: " & $wakuRelay.maxEncodedMessageSize &
          " bytes",
      )

    (await wakuRelay.validateMessage(pubSubTopic, message)).isOkOr:
      return lighpushErrorResult(LightPushErrorCode.INVALID_MESSAGE, $error)

    let publishedResult = (
      await wakuRelay.publish(pubsubTopic, message, handleAsReceived)
    ).valueOr:
      let msgHash = computeMessageHash(pubsubTopic, message).to0xHex()
      debug "Lightpush request has not been published to any peers",
        msg_hash = msgHash, reason = $error
      return mapPubishingErrorToPushResult(error, wakuRelay.maxEncodedMessageSize)

    return lightpushSuccessResult(publishedResult.uint32)

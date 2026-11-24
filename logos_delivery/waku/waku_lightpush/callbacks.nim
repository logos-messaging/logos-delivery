{.push raises: [].}

import results, chronos, chronicles

import ../waku_core, ../waku_relay, ./common

import libp2p/peerid

proc getNilPushHandler*(): PushMessageHandler =
  return proc(
      pubsubTopic: string, message: WakuMessage
  ): Future[WakuLightPushResult] {.async.} =
    return lightpushResultInternalError("no waku relay found")

proc relayPushHandler(wakuRelay: WakuRelay, forPeer: bool): PushMessageHandler =
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

    let published =
      if forPeer:
        await wakuRelay.publishForPeer(pubsubTopic, message)
      else:
        await wakuRelay.publish(pubsubTopic, message)
    let publishedResult = published.valueOr:
      let msgHash = computeMessageHash(pubsubTopic, message).to0xHex()
      debug "Lightpush request has not been published to any peers",
        msg_hash = msgHash, reason = $error
      return mapPubishingErrorToPushResult(error, wakuRelay.maxEncodedMessageSize)

    return lightpushSuccessResult(publishedResult.uint32)

proc getRelayPushHandler*(wakuRelay: WakuRelay): PushMessageHandler =
  ## Publishes the messages of this node.
  return relayPushHandler(wakuRelay, forPeer = false)

proc getRelayServerPushHandler*(wakuRelay: WakuRelay): PushMessageHandler =
  ## Publishes the messages a lightpush server receives from its clients, so
  ## its own subscribers receive them too (see `WakuRelay.publishForPeer`).
  return relayPushHandler(wakuRelay, forPeer = true)

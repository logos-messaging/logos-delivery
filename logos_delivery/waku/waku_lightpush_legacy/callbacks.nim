{.push raises: [].}

import results, chronos, chronicles
import ../waku_core, ../waku_relay, ./common, ./protocol_metrics

import libp2p/peerid

proc getNilPushHandler*(): PushMessageHandler =
  return proc(
      pubsubTopic: string, message: WakuMessage
  ): Future[WakuLightPushResult[void]] {.async.} =
    return err("no waku relay found")

proc getRelayPushHandler*(
    wakuRelay: WakuRelay, handleAsReceived = false
): PushMessageHandler =
  ## `handleAsReceived` is for the lightpush server: the messages it publishes are
  ## its clients', so its own subscribers receive them (see `WakuRelay.publish`).
  return proc(
      pubsubTopic: string, message: WakuMessage
  ): Future[WakuLightPushResult[void]] {.async.} =
    ?(await wakuRelay.validateMessage(pubSubTopic, message))

    (await wakuRelay.publish(pubsubTopic, message, handleAsReceived)).isOkOr:
      ## Agreed change expected to the lightpush protocol to better handle such case. https://github.com/waku-org/pm/issues/93
      let msgHash = computeMessageHash(pubsubTopic, message).to0xHex()
      debug "Lightpush request has not been published to any peers",
        msg_hash = msgHash, reason = $error
      # for legacy lightpush we do not detail the reason towards clients. All error during publish result in not-published-to-any-peer
      # this let client of the legacy protocol to react as they did so far.
      return err(protocol_metrics.notPublishedAnyPeer)

    return ok()

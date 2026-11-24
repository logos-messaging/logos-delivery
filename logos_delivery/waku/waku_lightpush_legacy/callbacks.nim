{.push raises: [].}

import results, chronos, chronicles
import ../waku_core, ../waku_relay, ./common, ./protocol_metrics

import libp2p/peerid

proc getNilPushHandler*(): PushMessageHandler =
  return proc(
      pubsubTopic: string, message: WakuMessage
  ): Future[WakuLightPushResult[void]] {.async.} =
    return err("no waku relay found")

type RelayPublish = proc(
  w: WakuRelay, pubsubTopic: PubsubTopic, wakuMessage: WakuMessage
): Future[Result[int, PublishOutcome]] {.async, nimcall.}

proc relayPushHandler(wakuRelay: WakuRelay, publish: RelayPublish): PushMessageHandler =
  return proc(
      pubsubTopic: string, message: WakuMessage
  ): Future[WakuLightPushResult[void]] {.async.} =
    ?(await wakuRelay.validateMessage(pubSubTopic, message))

    let published = await publish(wakuRelay, pubsubTopic, message)
    published.isOkOr:
      ## Agreed change expected to the lightpush protocol to better handle such case. https://github.com/waku-org/pm/issues/93
      let msgHash = computeMessageHash(pubsubTopic, message).to0xHex()
      debug "Lightpush request has not been published to any peers",
        msg_hash = msgHash, reason = $error
      # for legacy lightpush we do not detail the reason towards clients. All error during publish result in not-published-to-any-peer
      # this let client of the legacy protocol to react as they did so far.
      return err(protocol_metrics.notPublishedAnyPeer)

    return ok()

proc getRelayPushHandler*(wakuRelay: WakuRelay): PushMessageHandler =
  ## Publishes the messages of this node.
  return relayPushHandler(wakuRelay, publish)

proc getRelayServerPushHandler*(wakuRelay: WakuRelay): PushMessageHandler =
  ## Publishes the messages a lightpush server receives from its clients, so
  ## its own subscribers receive them too (see `WakuRelay.publishForPeer`).
  return relayPushHandler(wakuRelay, publishForPeer)

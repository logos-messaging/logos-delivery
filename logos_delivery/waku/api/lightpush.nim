## Waku layer API — lightpush (light client publish) operations.
import logos_delivery/waku/compat/option_valueor
{.push raises: [].}

import results, chronos, chronicles

import logos_delivery/waku/waku
import
  logos_delivery/waku/[
    waku_core,
    waku_core/codecs,
    node/waku_node,
    node/peer_manager,
    waku_lightpush_legacy/client,
  ]

proc lightpushPublish*(
    self: Waku, pubsubTopic: PubsubTopic, message: WakuMessage
): Future[Result[string, string]] {.async.} =
  ## Selects a lightpush service peer and publishes; returns the message hash.
  try:
    if self.node.wakuLegacyLightpushClient.isNil():
      return err("wakuLegacyLightpushClient is not mounted")

    let remotePeer = self.node.peerManager.selectPeer(WakuLightPushCodec).valueOr:
      return err("failed to lightpublish message, no suitable remote peers")

    let msgHashHex = (
      await self.node.wakuLegacyLightpushClient.publish(
        pubsubTopic, message, remotePeer
      )
    ).valueOr:
      return err($error)

    return ok(msgHashHex)
  except CatchableError as e:
    return err(e.msg)

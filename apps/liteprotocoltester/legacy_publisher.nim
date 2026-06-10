import chronos, results, options
import logos_delivery/waku/[waku_node, waku_core]
import publisher_base

type LegacyPublisher* = ref object of PublisherBase

proc new*(T: type LegacyPublisher, wakuNode: WakuNode): T =
  if isNil(wakuNode.wakuLegacyLightpushClient):
    wakuNode.mountLegacyLightPushClient()

  return LegacyPublisher(wakuNode: wakuNode)

method send*(
    self: LegacyPublisher,
    topic: PubsubTopic,
    message: WakuMessage,
    servicePeer: RemotePeerInfo,
): Future[Result[void, string]] {.async.} =
  # when error it must return original error desc due the text is used for distinction between error types in metrics.
  discard (
    await self.wakuNode.legacyLightpushPublish(some(topic), message, servicePeer)
  ).valueOr:
    return err(error)
  return ok()

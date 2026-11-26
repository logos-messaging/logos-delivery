import results, chronos
import logos_delivery/waku/[waku_node, waku_core, waku_lightpush, waku_lightpush/common]
import publisher_base

type V3Publisher* = ref object of PublisherBase

proc new*(T: type V3Publisher, wakuNode: WakuNode): T =
  if isNil(wakuNode.wakuLightpushClient):
    wakuNode.mountLightPushClient()

  return V3Publisher(wakuNode: wakuNode)

method send*(
    self: V3Publisher,
    topic: PubsubTopic,
    message: WakuMessage,
    servicePeer: RemotePeerInfo,
): Future[Result[void, string]] {.async.} =
  # The publisher reads this text to pick the metric label and to switch the service peer.
  discard (
    await self.wakuNode.lightpushPublish(
      Opt.some(topic), message, Opt.some(servicePeer)
    )
  ).valueOr:
    if error.localErrorCode == LightPushLocalErrorCode.DialFailure:
      return err("dial_failure")
    else:
      return err($error.code)
  return ok()

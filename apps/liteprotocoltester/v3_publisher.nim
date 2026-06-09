import results, options, chronos
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
  # when error it must return original error desc due the text is used for distinction between error types in metrics.
  discard (
    await self.wakuNode.lightpushPublish(some(topic), message, some(servicePeer))
  ).valueOr:
    if error.code == LightPushErrorCode.NO_PEERS_TO_RELAY and
        error.desc != some("No peers for topic, skipping publish"):
      # TODO: We need better separation of errors happening on the client side or the server side.-
      return err("dial_failure")
    else:
      return err($error.code)
  return ok()

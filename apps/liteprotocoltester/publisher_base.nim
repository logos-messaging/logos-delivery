import chronos, results
import logos_delivery/waku/[waku_node, waku_core]

type PublisherBase* = ref object of RootObj
  wakuNode*: WakuNode

method send*(
    self: PublisherBase,
    topic: PubsubTopic,
    message: WakuMessage,
    servicePeer: RemotePeerInfo,
): Future[Result[void, string]] {.base, async.} =
  discard
  # when error it must return original error desc due the text is used for distinction between error types in metrics.

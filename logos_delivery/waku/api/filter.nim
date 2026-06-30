## Waku layer API — filter (light client) operations.
import logos_delivery/waku/compat/option_valueor
{.push raises: [].}

import std/options
import results, chronos, chronicles

import logos_delivery/waku/waku
import
  logos_delivery/waku/[
    waku_core,
    waku_core/subscription/push_handler,
    node/waku_node,
    node/waku_node/filter,
    node/peer_manager,
    waku_filter_v2/client,
    waku_filter_v2/common,
  ]

const FilterOpTimeout = 5.seconds

proc filterSubscribe*(
    self: Waku,
    pubsubTopic: PubsubTopic,
    contentTopics: seq[ContentTopic],
    pushHandler: FilterPushHandler,
): Future[Result[bool, string]] {.async.} =
  ## Registers `pushHandler` for incoming filtered messages, selects a filter
  ## service peer, and subscribes.
  try:
    if self.node.wakuFilterClient.isNil():
      return err("wakuFilterClient is not mounted")

    self.node.wakuFilterClient.registerPushHandler(pushHandler)

    let peer = self.node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      return err("could not find peer with WakuFilterSubscribeCodec when subscribing")

    let subFut = self.node.filterSubscribe(some(pubsubTopic), contentTopics, peer)
    if not await subFut.withTimeout(FilterOpTimeout):
      return err("filter subscription timed out")
    subFut.read().isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc filterUnsubscribe*(
    self: Waku, pubsubTopic: PubsubTopic, contentTopics: seq[ContentTopic]
): Future[Result[bool, string]] {.async.} =
  ## Selects a filter service peer and unsubscribes the given content topics.
  try:
    if self.node.wakuFilterClient.isNil():
      return err("wakuFilterClient is not mounted")

    let peer = self.node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      return err("could not find peer with WakuFilterSubscribeCodec when unsubscribing")

    let unsubFut = self.node.filterUnsubscribe(some(pubsubTopic), contentTopics, peer)
    if not await unsubFut.withTimeout(FilterOpTimeout):
      return err("filter un-subscription timed out")
    unsubFut.read().isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc filterUnsubscribeAll*(self: Waku): Future[Result[bool, string]] {.async.} =
  ## Selects a filter service peer and unsubscribes from everything.
  try:
    if self.node.wakuFilterClient.isNil():
      return err("wakuFilterClient is not mounted")

    let peer = self.node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      return
        err("could not find peer with WakuFilterSubscribeCodec when unsubscribing all")

    let unsubFut = self.node.filterUnsubscribeAll(peer)
    if not await unsubFut.withTimeout(FilterOpTimeout):
      return err("filter un-subscription all timed out")
    unsubFut.read().isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

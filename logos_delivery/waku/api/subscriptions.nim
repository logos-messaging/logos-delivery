## Waku layer API — content-topic subscription operations.
##
## These wrap the node's `SubscriptionManager`, which resolves each content
## topic to its autosharding shard. They give the layers above (messaging) a
## kernel-level entry point so they never reach into `waku.node` internals.
{.push raises: [].}

import results

import logos_delivery/waku/waku
import logos_delivery/waku/[waku_core, node/waku_node, node/subscription_manager]

proc subscribe*(self: Waku, contentTopic: ContentTopic): Result[void, string] =
  ## Subscribes to `contentTopic`, resolving its shard via autosharding.
  return self.node.subscriptionManager.subscribe(contentTopic)

proc unsubscribe*(self: Waku, contentTopic: ContentTopic): Result[void, string] =
  ## Unsubscribes from `contentTopic`, resolving its shard via autosharding.
  return self.node.subscriptionManager.unsubscribe(contentTopic)

proc isSubscribed*(self: Waku, contentTopic: ContentTopic): Result[bool, string] =
  ## True if the node already subscribes to `contentTopic`.
  return self.node.subscriptionManager.isSubscribed(contentTopic)

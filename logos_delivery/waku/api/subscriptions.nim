## Waku layer API — content-topic subscription operations.
##
## These wrap the node's `SubscriptionManager`, which resolves each content
## topic to its autosharding shard. They give the layers above (messaging) a
## kernel-level entry point so they never reach into `waku.node` internals.
{.push raises: [].}

import std/sets
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

proc isContentSubscribed*(
    self: Waku, shard: PubsubTopic, contentTopic: ContentTopic
): bool =
  ## True if `contentTopic` is subscribed on the given `shard` (pubsub topic).
  return self.node.subscriptionManager.isContentSubscribed(shard, contentTopic)

proc subscribedContentTopics*(self: Waku): seq[(PubsubTopic, HashSet[ContentTopic])] =
  ## Snapshot of every shard with its non-empty content-topic set.
  var res: seq[(PubsubTopic, HashSet[ContentTopic])]
  for shard, contentTopics in self.node.subscriptionManager.subscribedContentTopics:
    res.add((shard, contentTopics))
  return res

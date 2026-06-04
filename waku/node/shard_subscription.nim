{.push raises: [].}

import std/sets
import ../waku_core

type ShardSubscription* = object
  contentTopics*: HashSet[ContentTopic]
  directShardSub*: bool
    ## shard subscribed directly (PubsubSub), independent of content-topic interest

{.pop.}

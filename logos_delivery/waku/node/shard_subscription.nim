{.push raises: [].}

import std/sets
import ../waku_core

type ShardSubscription* = object
  contentTopics*: HashSet[ContentTopic]
  weakTopics*: HashSet[ContentTopic]
    ## The topics of `contentTopics` that only a send placed. An app subscribe
    ## removes a topic from this set.
  directShardSub*: bool
    ## shard subscribed directly (PubsubSub), independent of content-topic interest

{.pop.}

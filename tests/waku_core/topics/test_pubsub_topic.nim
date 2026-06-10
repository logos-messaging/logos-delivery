{.used.}

import std/[options], testutils/unittests, results

import logos_delivery/waku/waku_core/topics/pubsub_topic, ../../testlib/[wakucore]

suite "Static Sharding Functionality":
  test "Shard Cluster Identification":
    let shard = RelayShard.parseStaticSharding("/waku/2/rs/0/1").get()
    check:
      shard.clusterId == 0
      shard.shardId == 1
      shard == RelayShard(clusterId: 0, shardId: 1)

  test "Pubsub Topic Naming Compliance":
    let shard = RelayShard(clusterId: 0, shardId: 1)
    check:
      shard.clusterId == 0
      shard.shardId == 1
      shard == "/waku/2/rs/0/1"

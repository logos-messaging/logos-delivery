import std/[options, tables], testutils/unittests

import logos_delivery/waku/waku_core/topics, ../../testlib/[wakucore, tables, testutils]

const GenerationZeroShardsCount = 8
const ClusterId = 1

suite "Autosharding":
  const
    pubsubTopic04 = "/waku/2/rs/0/4"
    pubsubTopic13 = "/waku/2/rs/1/3"
    contentTopicShort = "/toychat/2/huilong/proto"
    contentTopicFull = "/0/toychat/2/huilong/proto"
    contentTopicShort2 = "/toychat2/2/huilong/proto"
    contentTopicFull2 = "/0/toychat2/2/huilong/proto"
    contentTopicShort3 = "/toychat/2/huilong/proto2"
    contentTopicFull3 = "/0/toychat/2/huilong/proto2"
    contentTopicShort4 = "/toychat/4/huilong/proto2"
    contentTopicFull4 = "/0/toychat/4/huilong/proto2"
    contentTopicFull5 = "/1/toychat/2/huilong/proto"
    contentTopicFull6 = "/1/toychat2/2/huilong/proto"
    contentTopicInvalid = "/1/toychat/2/huilong/proto"

  suite "getGenZeroShard":
    test "Generate Gen0 Shard":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)

      # Given two valid topics
      let
        nsContentTopic1 = NsContentTopic.parse(contentTopicShort).value()
        nsContentTopic2 = NsContentTopic.parse(contentTopicFull).value()
        nsContentTopic3 = NsContentTopic.parse(contentTopicShort2).value()
        nsContentTopic4 = NsContentTopic.parse(contentTopicFull2).value()
        nsContentTopic5 = NsContentTopic.parse(contentTopicShort3).value()
        nsContentTopic6 = NsContentTopic.parse(contentTopicFull3).value()
        nsContentTopic7 = NsContentTopic.parse(contentTopicShort3).value()
        nsContentTopic8 = NsContentTopic.parse(contentTopicFull3).value()
        nsContentTopic9 = NsContentTopic.parse(contentTopicFull4).value()
        nsContentTopic10 = NsContentTopic.parse(contentTopicFull5).value()

      # When we generate a gen0 shard from them
      let
        shard1 = sharding.getGenZeroShard(nsContentTopic1, GenerationZeroShardsCount)
        shard2 = sharding.getGenZeroShard(nsContentTopic2, GenerationZeroShardsCount)
        shard3 = sharding.getGenZeroShard(nsContentTopic3, GenerationZeroShardsCount)
        shard4 = sharding.getGenZeroShard(nsContentTopic4, GenerationZeroShardsCount)
        shard5 = sharding.getGenZeroShard(nsContentTopic5, GenerationZeroShardsCount)
        shard6 = sharding.getGenZeroShard(nsContentTopic6, GenerationZeroShardsCount)
        shard7 = sharding.getGenZeroShard(nsContentTopic7, GenerationZeroShardsCount)
        shard8 = sharding.getGenZeroShard(nsContentTopic8, GenerationZeroShardsCount)
        shard9 = sharding.getGenZeroShard(nsContentTopic9, GenerationZeroShardsCount)
        shard10 = sharding.getGenZeroShard(nsContentTopic10, GenerationZeroShardsCount)

      # Then the generated shards are valid
      check:
        shard1 == RelayShard(clusterId: ClusterId, shardId: 3)
        shard2 == RelayShard(clusterId: ClusterId, shardId: 3)
        shard3 == RelayShard(clusterId: ClusterId, shardId: 6)
        shard4 == RelayShard(clusterId: ClusterId, shardId: 6)
        shard5 == RelayShard(clusterId: ClusterId, shardId: 3)
        shard6 == RelayShard(clusterId: ClusterId, shardId: 3)
        shard7 == RelayShard(clusterId: ClusterId, shardId: 3)
        shard8 == RelayShard(clusterId: ClusterId, shardId: 3)
        shard9 == RelayShard(clusterId: ClusterId, shardId: 7)
        shard10 == RelayShard(clusterId: ClusterId, shardId: 3)

    test "Generate Gen0 Shard with shardOverride":
      # Given a sharding with a forced shard mapping (index -> value)
      let shardOverride = @[10'u16, 11, 12, 13, 14, 15, 16, 17]
      let sharding = Sharding(
        clusterId: ClusterId,
        shardCountGenZero: GenerationZeroShardsCount,
        shardOverride: shardOverride,
      )

      let
        nsContentTopic1 = NsContentTopic.parse(contentTopicShort).value()
          # hashes to index 3
        nsContentTopic3 = NsContentTopic.parse(contentTopicShort2).value()
          # hashes to index 6
        nsContentTopic9 = NsContentTopic.parse(contentTopicFull4).value()
          # hashes to index 7

      # When we generate gen0 shards from them
      let
        shard1 = sharding.getGenZeroShard(nsContentTopic1, GenerationZeroShardsCount)
        shard3 = sharding.getGenZeroShard(nsContentTopic3, GenerationZeroShardsCount)
        shard9 = sharding.getGenZeroShard(nsContentTopic9, GenerationZeroShardsCount)

      # Then the computed index is remapped through the override array
      check:
        shard1 == RelayShard(clusterId: ClusterId, shardId: 13) # index 3 -> 13
        shard3 == RelayShard(clusterId: ClusterId, shardId: 16) # index 6 -> 16
        shard9 == RelayShard(clusterId: ClusterId, shardId: 17) # index 7 -> 17

    test "shardOverride is ignored when length differs from shard count":
      # Given a shardOverride whose length does not match the shard count
      let sharding = Sharding(
        clusterId: ClusterId,
        shardCountGenZero: GenerationZeroShardsCount,
        shardOverride: @[10'u16, 11, 12], # wrong length, must be ignored
      )

      let nsContentTopic1 = NsContentTopic.parse(contentTopicShort).value()
      let shard1 = sharding.getGenZeroShard(nsContentTopic1, GenerationZeroShardsCount)

      # Then it falls back to using the index as the shard id
      check:
        shard1 == RelayShard(clusterId: ClusterId, shardId: 3)

  suite "getShard from NsContentTopic":
    test "Generate Gen0 Shard with topic.generation==none":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)

      # When we get a shard from a topic without generation
      let shard = sharding.getShard(contentTopicShort)

      # Then the generated shard is valid
      check:
        shard.value() == RelayShard(clusterId: ClusterId, shardId: 3)

    test "Generate Gen0 Shard with topic.generation==0":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When we get a shard from a gen0 topic
      let shard = sharding.getShard(contentTopicFull)

      # Then the generated shard is valid
      check:
        shard.value() == RelayShard(clusterId: ClusterId, shardId: 3)

    test "Generate Gen0 Shard with topic.generation==other":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When we get a shard from ain invalid content topic
      let shard = sharding.getShard(contentTopicInvalid)

      # Then the generated shard is valid
      check:
        shard.error() == "Generation > 0 are not supported yet"

  suite "getShard from ContentTopic":
    test "Generate Gen0 Shard with topic.generation==none":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When we get a shard from it
      let shard = sharding.getShard(contentTopicShort)

      # Then the generated shard is valid
      check:
        shard.value() == RelayShard(clusterId: ClusterId, shardId: 3)

    test "Generate Gen0 Shard with topic.generation==0":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When we get a shard from it
      let shard = sharding.getShard(contentTopicFull)

      # Then the generated shard is valid
      check:
        shard.value() == RelayShard(clusterId: ClusterId, shardId: 3)

    test "Generate Gen0 Shard with topic.generation==other":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When we get a shard from it
      let shard = sharding.getShard(contentTopicInvalid)

      # Then the generated shard is valid
      check:
        shard.error() == "Generation > 0 are not supported yet"

    test "Generate Gen0 Shard invalid topic":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When we get a shard from it
      let shard = sharding.getShard("invalid")

      # Then the generated shard is valid
      check:
        shard.error() == "invalid format: topic must start with slash"

  suite "parseSharding":
    test "contentTopics is ContentTopic":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When calling with contentTopic as string
      let topicMap = sharding.parseSharding(some(pubsubTopic04), contentTopicShort)

      # Then the topicMap is valid
      check:
        topicMap.value() == {pubsubTopic04: @[contentTopicShort]}

    test "contentTopics is seq[ContentTopic]":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When calling with contentTopic as string seq
      let topicMap = sharding.parseSharding(
        some(pubsubTopic04), @[contentTopicShort, "/0/foo/1/bar/proto"]
      )

      # Then the topicMap is valid
      check:
        topicMap.value() == {pubsubTopic04: @[contentTopicShort, "/0/foo/1/bar/proto"]}

    test "pubsubTopic is none":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When calling with pubsubTopic as none
      let topicMap = sharding.parseSharding(PubsubTopic.none(), contentTopicShort)

      # Then the topicMap is valid
      check:
        topicMap.value() == {pubsubTopic13: @[contentTopicShort]}

    test "content parse error":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When calling with pubsubTopic as none with invalid content
      let topicMap = sharding.parseSharding(PubsubTopic.none(), "invalid")

      # Then the topicMap is valid
      check:
        topicMap.error() ==
          "Cannot parse content topic: invalid format: topic must start with slash"

    test "pubsubTopic parse error":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When calling with pubsubTopic as none with invalid content
      let topicMap = sharding.parseSharding(some("invalid"), contentTopicShort)

      # Then the topicMap is valid
      check:
        topicMap.error() ==
          "Cannot parse pubsub topic: invalid format: must start with /waku/2"

    test "pubsubTopic getShard error":
      let sharding =
        Sharding(clusterId: ClusterId, shardCountGenZero: GenerationZeroShardsCount)
      # When calling with pubsubTopic as none with invalid content
      let topicMap = sharding.parseSharding(PubsubTopic.none(), contentTopicInvalid)

      # Then the topicMap is valid
      check:
        topicMap.error() ==
          "Cannot autoshard content topic: Generation > 0 are not supported yet"

    xtest "catchable error on add to topicMap":
      # TODO: Trigger a CatchableError or mock
      discard

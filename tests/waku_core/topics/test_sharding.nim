import std/[options, tables], testutils/unittests

import waku/waku_core/topics, ../../testlib/[wakucore, tables, testutils]

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
        Sharding.init(ClusterId, GenerationZeroShardsCount)

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

  suite "getShard from NsContentTopic":
    test "Generate Gen0 Shard with topic.generation==none":
      let sharding =
        Sharding.init(ClusterId, GenerationZeroShardsCount)

      # When we get a shard from a topic without generation
      let shard = sharding.getShard(contentTopicShort)

      # Then the generated shard is valid
      check:
        shard.value() == RelayShard(clusterId: ClusterId, shardId: 3)

    test "Generate Gen0 Shard with topic.generation==0":
      let sharding =
        Sharding.init(ClusterId, GenerationZeroShardsCount)
      # When we get a shard from a gen0 topic
      let shard = sharding.getShard(contentTopicFull)

      # Then the generated shard is valid
      check:
        shard.value() == RelayShard(clusterId: ClusterId, shardId: 3)

    test "Generate Gen0 Shard with topic.generation==other":
      let sharding =
        Sharding.init(ClusterId, GenerationZeroShardsCount)
      # When we get a shard from ain invalid content topic
      let shard = sharding.getShard(contentTopicInvalid)

      # Then the generated shard is valid
      check:
        shard.error() == "Generation > 0 are not supported yet"

  suite "getShard from ContentTopic":
    test "Generate Gen0 Shard with topic.generation==none":
      let sharding =
        Sharding.init(ClusterId, GenerationZeroShardsCount)
      # When we get a shard from it
      let shard = sharding.getShard(contentTopicShort)

      # Then the generated shard is valid
      check:
        shard.value() == RelayShard(clusterId: ClusterId, shardId: 3)

    test "Generate Gen0 Shard with topic.generation==0":
      let sharding =
        Sharding.init(ClusterId, GenerationZeroShardsCount)
      # When we get a shard from it
      let shard = sharding.getShard(contentTopicFull)

      # Then the generated shard is valid
      check:
        shard.value() == RelayShard(clusterId: ClusterId, shardId: 3)

    test "Generate Gen0 Shard with topic.generation==other":
      let sharding =
        Sharding.init(ClusterId, GenerationZeroShardsCount)
      # When we get a shard from it
      let shard = sharding.getShard(contentTopicInvalid)

      # Then the generated shard is valid
      check:
        shard.error() == "Generation > 0 are not supported yet"

    test "Generate Gen0 Shard invalid topic":
      let sharding =
        Sharding.init(ClusterId, GenerationZeroShardsCount)
      # When we get a shard from it
      let shard = sharding.getShard("invalid")

      # Then the generated shard is valid
      check:
        shard.error() == "invalid format: content-topic 'invalid' must start with slash"

  xsuite "parseSharding":
    test "contentTopics is ContentTopic":
      let sharding =
        Sharding.init(ClusterId, GenerationZeroShardsCount)
      # When calling with contentTopic as string
      let topicMap = sharding.parseSharding(some(pubsubTopic04), contentTopicShort)

      # Then the topicMap is valid
      check:
        topicMap.value() == {pubsubTopic04: @[contentTopicShort]}

    test "contentTopics is seq[ContentTopic]":
      let sharding =
        Sharding.init(ClusterId, GenerationZeroShardsCount)
      # When calling with contentTopic as string seq
      let topicMap = sharding.parseSharding(
        some(pubsubTopic04), @[contentTopicShort, "/0/foo/1/bar/proto"]
      )

      # Then the topicMap is valid
      check:
        topicMap.value() == {pubsubTopic04: @[contentTopicShort, "/0/foo/1/bar/proto"]}

    test "pubsubTopic is none":
      let sharding =
        Sharding.init(ClusterId, GenerationZeroShardsCount)
      # When calling with pubsubTopic as none
      let topicMap = sharding.parseSharding(PubsubTopic.none(), contentTopicShort)

      # Then the topicMap is valid
      check:
        topicMap.value() == {pubsubTopic13: @[contentTopicShort]}

    test "content parse error":
      let sharding =
        Sharding.init(ClusterId, GenerationZeroShardsCount)
      # When calling with pubsubTopic as none with invalid content
      let topicMap = sharding.parseSharding(PubsubTopic.none(), "invalid")

      # Then the topicMap is valid
      check:
        topicMap.error() ==
          "Cannot parse content topic: invalid format: topic must start with slash"

    test "pubsubTopic parse error":
      let sharding =
        Sharding.init(ClusterId, GenerationZeroShardsCount)
      # When calling with pubsubTopic as none with invalid content
      let topicMap = sharding.parseSharding(some("invalid"), contentTopicShort)

      # Then the topicMap is valid
      check:
        topicMap.error() ==
          "Cannot parse pubsub topic: invalid format: must start with /waku/2"

    test "pubsubTopic getShard error":
      let sharding =
        Sharding.init(ClusterId, GenerationZeroShardsCount)
      # When calling with pubsubTopic as none with invalid content
      let topicMap = sharding.parseSharding(PubsubTopic.none(), contentTopicInvalid)

      # Then the topicMap is valid
      check:
        topicMap.error() ==
          "Cannot autoshard content topic: Generation > 0 are not supported yet"

    xtest "catchable error on add to topicMap":
      # TODO: Trigger a CatchableError or mock
      discard

  suite "Arbitrary sharder network, auto shard selection":
    const arbitraryShards = @[2'u16, 4, 8, 16, 32, 64, 128, 256]

    test "Initialize with arbitrary shard list":
      # When we initialize sharding with a custom shard list
      let sharding = Sharding.init(ClusterId, arbitraryShards)

      # Given valid content topics
      let
        nsContentTopic1 = NsContentTopic.parse(contentTopicShort).value()
        nsContentTopic2 = NsContentTopic.parse(contentTopicFull).value()
        nsContentTopic3 = NsContentTopic.parse(contentTopicShort2).value()
        nsContentTopic4 = NsContentTopic.parse(contentTopicFull2).value()
        nsContentTopic5 = NsContentTopic.parse(contentTopicShort3).value()
        nsContentTopic6 = NsContentTopic.parse(contentTopicFull4).value()

      # When we generate shards from them
      let
        shard1 = sharding.getGenZeroShard(nsContentTopic1, arbitraryShards.len)
        shard2 = sharding.getGenZeroShard(nsContentTopic2, arbitraryShards.len)
        shard3 = sharding.getGenZeroShard(nsContentTopic3, arbitraryShards.len)
        shard4 = sharding.getGenZeroShard(nsContentTopic4, arbitraryShards.len)
        shard5 = sharding.getGenZeroShard(nsContentTopic5, arbitraryShards.len)
        shard6 = sharding.getGenZeroShard(nsContentTopic6, arbitraryShards.len)

      # Then the generated shards use IDs from the arbitrary list
      check:
        shard1 == RelayShard(clusterId: ClusterId, shardId: 16)
        shard2 == RelayShard(clusterId: ClusterId, shardId: 16)
        shard3 == RelayShard(clusterId: ClusterId, shardId: 128)
        shard4 == RelayShard(clusterId: ClusterId, shardId: 128)
        shard5 == RelayShard(clusterId: ClusterId, shardId: 16)
        shard6 == RelayShard(clusterId: ClusterId, shardId: 256)

    test "getShard with arbitrary shard list - generation none":
      # When we initialize sharding with a custom shard list
      let sharding = Sharding.init(ClusterId, arbitraryShards)

      # When we get a shard from a topic without generation
      let shard = sharding.getShard(contentTopicShort)

      # Then the generated shard uses an ID from the arbitrary list
      check:
        shard.value() == RelayShard(clusterId: ClusterId, shardId: 16)

    test "getShard with arbitrary shard list - generation zero":
      # When we initialize sharding with a custom shard list
      let sharding = Sharding.init(ClusterId, arbitraryShards)

      # When we get a shard from a gen0 topic
      let shard = sharding.getShard(contentTopicFull)

      # Then the generated shard uses an ID from the arbitrary list
      check:
        shard.value() == RelayShard(clusterId: ClusterId, shardId: 16)

    test "Multiple topics map to shards from arbitrary list":
      # When we initialize sharding with a custom shard list
      let sharding = Sharding.init(ClusterId, arbitraryShards)

      # Given multiple content topics
      let contentTopics = @[
        contentTopicShort,
        contentTopicFull,
        contentTopicShort2,
        contentTopicFull2,
        contentTopicShort3,
        contentTopicFull3,
      ]

      # When we get shards for all topics
      let shards = @[
        sharding.getShard(contentTopicShort).value(),
        sharding.getShard(contentTopicFull).value(),
        sharding.getShard(contentTopicShort2).value(),
        sharding.getShard(contentTopicFull2).value(),
        sharding.getShard(contentTopicShort3).value(),
        sharding.getShard(contentTopicFull3).value(),
      ]

      # Then all shard IDs match expected values from the arbitrary list
      check:
        shards[0] == RelayShard(clusterId: ClusterId, shardId: 16)
        shards[1] == RelayShard(clusterId: ClusterId, shardId: 16)
        shards[2] == RelayShard(clusterId: ClusterId, shardId: 128)
        shards[3] == RelayShard(clusterId: ClusterId, shardId: 128)
        shards[4] == RelayShard(clusterId: ClusterId, shardId: 16)
        shards[5] == RelayShard(clusterId: ClusterId, shardId: 16)

    test "Consistent shard mapping with arbitrary list":
      # When we initialize sharding with a custom shard list
      let sharding = Sharding.init(ClusterId, arbitraryShards)

      # Given a content topic
      let topic = contentTopicShort

      # When we get the shard multiple times
      let
        shard1 = sharding.getShard(topic)
        shard2 = sharding.getShard(topic)
        shard3 = sharding.getShard(topic)

      # Then the shard is consistent
      check:
        shard1.isOk()
        shard2.isOk()
        shard3.isOk()
        shard1.value() == shard2.value()
        shard2.value() == shard3.value()

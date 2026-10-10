{.used.}

import results, std/tables, testutils/unittests

import logos_delivery/waku/waku_core/topics, ../../testlib/[wakucore, tables, testutils]

const GenerationZeroShardsCount = 8
const ClusterId = 1

suite "Autosharding":
  const
    pubsubTopic13 = "/waku/2/rs/1/3"
    contentTopicShort = "/toychat/2/huilong/proto"
    contentTopicFull = "/0/toychat/2/huilong/proto"
    contentTopicShort2 = "/toychat2/2/huilong/proto"
    contentTopicFull2 = "/0/toychat2/2/huilong/proto"
    contentTopicShort3 = "/toychat/2/huilong/proto2"
    contentTopicFull3 = "/0/toychat/2/huilong/proto2"
    contentTopicFull4 = "/0/toychat/4/huilong/proto2"
    contentTopicFull5 = "/1/toychat/2/huilong/proto"
    contentTopicInvalid = "/1/toychat/2/huilong/proto"

  suite "getGenZeroShard":
    test "Generate Gen0 Shard":
      let sharding = Sharding.new(ClusterId, GenerationZeroShardsCount)

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
        shard1 = sharding.getGenZeroShard(nsContentTopic1)
        shard2 = sharding.getGenZeroShard(nsContentTopic2)
        shard3 = sharding.getGenZeroShard(nsContentTopic3)
        shard4 = sharding.getGenZeroShard(nsContentTopic4)
        shard5 = sharding.getGenZeroShard(nsContentTopic5)
        shard6 = sharding.getGenZeroShard(nsContentTopic6)
        shard7 = sharding.getGenZeroShard(nsContentTopic7)
        shard8 = sharding.getGenZeroShard(nsContentTopic8)
        shard9 = sharding.getGenZeroShard(nsContentTopic9)
        shard10 = sharding.getGenZeroShard(nsContentTopic10)

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

    test "Generate Gen0 Shard with explicit shards":
      # Given a sharding over explicit shard ids
      let sharding = Sharding.new(ClusterId, @[10'u16, 11, 12, 13, 14, 15, 16, 17])

      let
        nsContentTopic1 = NsContentTopic.parse(contentTopicShort).value()
          # hashes to index 3
        nsContentTopic3 = NsContentTopic.parse(contentTopicShort2).value()
          # hashes to index 6
        nsContentTopic9 = NsContentTopic.parse(contentTopicFull4).value()
          # hashes to index 7

      # When we generate gen0 shards from them
      let
        shard1 = sharding.getGenZeroShard(nsContentTopic1)
        shard3 = sharding.getGenZeroShard(nsContentTopic3)
        shard9 = sharding.getGenZeroShard(nsContentTopic9)

      # Then the computed index selects the shard id
      check:
        shard1 == RelayShard(clusterId: ClusterId, shardId: 13)
        shard3 == RelayShard(clusterId: ClusterId, shardId: 16)
        shard9 == RelayShard(clusterId: ClusterId, shardId: 17)

    test "A single-shard cluster lands on its shard":
      let sharding = Sharding.new(16, @[32'u16])

      check:
        sharding.getShard(contentTopicShort).value() ==
          RelayShard(clusterId: 16, shardId: 32)

  suite "getShard from NsContentTopic":
    test "Generate Gen0 Shard with topic.generation==none":
      let sharding = Sharding.new(ClusterId, GenerationZeroShardsCount)

      # When we get a shard from a topic without generation
      let shard = sharding.getShard(NsContentTopic.parse(contentTopicShort).value())

      # Then the generated shard is valid
      check:
        shard.value() == RelayShard(clusterId: ClusterId, shardId: 3)

    test "Generate Gen0 Shard with topic.generation==0":
      let sharding = Sharding.new(ClusterId, GenerationZeroShardsCount)
      # When we get a shard from a gen0 topic
      let shard = sharding.getShard(NsContentTopic.parse(contentTopicFull).value())

      # Then the generated shard is valid
      check:
        shard.value() == RelayShard(clusterId: ClusterId, shardId: 3)

    test "Generate Gen0 Shard with topic.generation==other":
      let sharding = Sharding.new(ClusterId, GenerationZeroShardsCount)
      # When we get a shard from ain invalid content topic
      let shard = sharding.getShard(NsContentTopic.parse(contentTopicInvalid).value())

      # Then the generated shard is valid
      check:
        shard.error() == "Generation > 0 are not supported yet"

  suite "getShard from ContentTopic":
    test "Generate Gen0 Shard with topic.generation==none":
      let sharding = Sharding.new(ClusterId, GenerationZeroShardsCount)
      # When we get a shard from it
      let shard = sharding.getShard(contentTopicShort)

      # Then the generated shard is valid
      check:
        shard.value() == RelayShard(clusterId: ClusterId, shardId: 3)

    test "Generate Gen0 Shard with topic.generation==0":
      let sharding = Sharding.new(ClusterId, GenerationZeroShardsCount)
      # When we get a shard from it
      let shard = sharding.getShard(contentTopicFull)

      # Then the generated shard is valid
      check:
        shard.value() == RelayShard(clusterId: ClusterId, shardId: 3)

    test "Generate Gen0 Shard with topic.generation==other":
      let sharding = Sharding.new(ClusterId, GenerationZeroShardsCount)
      # When we get a shard from it
      let shard = sharding.getShard(contentTopicInvalid)

      # Then the generated shard is valid
      check:
        shard.error() == "Generation > 0 are not supported yet"

    test "Generate Gen0 Shard invalid topic":
      let sharding = Sharding.new(ClusterId, GenerationZeroShardsCount)
      # When we get a shard from it
      let shard = sharding.getShard("invalid")

      # Then the generated shard is valid
      check:
        shard.error() == "invalid format: content-topic 'invalid' must start with slash"

  suite "getShardsFromContentTopics":
    test "contentTopics is ContentTopic":
      let sharding = Sharding.new(ClusterId, GenerationZeroShardsCount)
      # When calling with contentTopic as string
      let topicMap = sharding.getShardsFromContentTopics(contentTopicShort)

      # Then the topicMap is valid
      check:
        topicMap.value() == {pubsubTopic13: @[contentTopicShort]}

    test "contentTopics is seq[ContentTopic]":
      let sharding = Sharding.new(ClusterId, GenerationZeroShardsCount)
      # When calling with contentTopic as string seq
      let topicMap =
        sharding.getShardsFromContentTopics(@[contentTopicShort, contentTopicShort3])

      # Then the topicMap is valid
      check:
        topicMap.value() == {pubsubTopic13: @[contentTopicShort, contentTopicShort3]}

    test "content parse error":
      let sharding = Sharding.new(ClusterId, GenerationZeroShardsCount)
      # When calling with an invalid content topic
      let topicMap = sharding.getShardsFromContentTopics("invalid")

      # Then the topicMap is valid
      check:
        topicMap.error() ==
          "Cannot parse content topic: invalid format: content-topic 'invalid' must start with slash"

    test "shard deduction error":
      let sharding = Sharding.new(ClusterId, GenerationZeroShardsCount)
      # When calling with a content topic that cannot be autosharded
      let topicMap = sharding.getShardsFromContentTopics(contentTopicInvalid)

      # Then the topicMap is valid
      check:
        topicMap.error() ==
          "Cannot deduce shard from content topic: Generation > 0 are not supported yet"

    xtest "catchable error on add to topicMap":
      # TODO: Trigger a CatchableError or mock
      discard

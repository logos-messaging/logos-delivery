## Waku autosharding utils
##
## See 51/WAKU2-RELAY-SHARDING RFC: https://rfc.vac.dev/spec/51/#automatic-sharding

{.push raises: [].}

import nimcrypto, std/[options, tables, sequtils], stew/[endians2, byteutils], results

import ./content_topic, ./pubsub_topic

# TODO: this is autosharding, not just "sharding"
type Sharding* = object
  clusterId: uint16
  # TODO: generations could be stored in a table here
  shardCountGenZero: uint32
  supportedShards: seq[uint16]

proc init*(T: typedesc[Sharding], clusterId: uint16, shardCount: uint32): T =
  return Sharding(
    clusterId: clusterId,
    shardCountGenZero: shardCount,
    supportedShards: toSeq(0'u16 ..< uint16(shardCount)),
  )

proc init*(T: typedesc[Sharding], clusterId: uint16, supportedShards: seq[uint16]): T =
  return Sharding(
    clusterId: clusterId,
    shardCountGenZero: uint32(supportedShards.len),
    supportedShards: supportedShards,
  )

proc getGenZeroShard*(s: Sharding, topic: NsContentTopic, count: int): RelayShard =
  let bytes = toBytes(topic.application) & toBytes(topic.version)

  let hash = sha256.digest(bytes)

  # We only use the last 64 bits of the hash as having more shards is unlikely.
  let hashValue = uint64.fromBytesBE(hash.data[24 .. 31])

  let shard = hashValue mod uint64(count)

  RelayShard(clusterId: s.clusterId, shardId: s.supportedShards[shard])

proc getShard*(s: Sharding, topic: NsContentTopic): Result[RelayShard, string] =
  ## Compute the (pubsub topic) shard to use for this content topic.

  if topic.generation.isNone():
    ## Implicit generation # is 0 for all content topic
    return ok(s.getGenZeroShard(topic, int(s.shardCountGenZero)))

  case topic.generation.get()
  of 0:
    return ok(s.getGenZeroShard(topic, int(s.shardCountGenZero)))
  else:
    return err("Generation > 0 are not supported yet")

proc getShard*(s: Sharding, topic: ContentTopic): Result[RelayShard, string] =
  let parsedTopic = NsContentTopic.parse(topic).valueOr:
    return err($error)

  let shard = ?s.getShard(parsedTopic)

  ok(shard)

proc getShardsFromContentTopics*(
    s: Sharding, contentTopics: ContentTopic | seq[ContentTopic]
): Result[Table[RelayShard, seq[NsContentTopic]], string] =
  let topics =
    when contentTopics is seq[ContentTopic]:
      contentTopics
    else:
      @[contentTopics]

  let nsContentTopics = NsContentTopic.parse(topics).valueOr:
    return err("Cannot parse content topic: " & $error)

  var topicMap = initTable[RelayShard, seq[NsContentTopic]]()
  for content in nsContentTopics:
    let shard = s.getShard(content).valueOr:
      return err("Cannot deduce shard from content topic: " & $error)

    if not topicMap.hasKey(shard):
      topicMap[shard] = @[]

    try:
      topicMap[shard].add(content)
    except CatchableError:
      return err(getCurrentExceptionMsg())

  ok(topicMap)

#type ShardsPriority = seq[tuple[topic: RelayShard, value: float64]]

#[ proc shardCount*(topic: NsContentTopic): Result[int, string] =
  ## Returns the total shard count from the content topic.
  let shardCount =
    if topic.generation.isNone():
      ## Implicit generation # is 0 for all content topic
      GenerationZeroShardsCount
    else:
      case topic.generation.get():
        of 0:
          GenerationZeroShardsCount
        else:
          return err("Generation > 0 are not supported yet")

  ok((shardCount)) ]#

#[ proc applyWeight(hashValue: uint64, weight: float64): float64 =
  (-weight) / math.ln(float64(hashValue) / float64(high(uint64))) ]#

#[ proc hashOrder*(x, y: (RelayShard, float64)): int =
    cmp(x[1], y[1]) ]#

#[ proc weightedShardList*(topic: NsContentTopic, shardCount: int, weightList: seq[float64]): Result[ShardsPriority, string] =
  ## Returns the ordered list of shards and their priority values.
  if weightList.len < shardCount:
    return err("Must provide weights for every shards")

  let shardsNWeights = zip(toSeq(0..shardCount), weightList)

  var list = newSeq[(RelayShard, float64)](shardCount)

  for (shard, weight) in shardsNWeights:
    let pubsub = RelayShard(clusterId: ClusterId, shardId: uint16(shard))

    let clusterBytes = toBytesBE(uint16(ClusterId))
    let shardBytes = toBytesBE(uint16(shard))
    let bytes = toBytes(topic.application) & toBytes(topic.version) & @clusterBytes & @shardBytes
    let hash = sha256.digest(bytes)
    let hashValue = uint64.fromBytesBE(hash.data)
    let value = applyWeight(hashValue, weight)

    list[shard] = (pubsub, value)

  list.sort(hashOrder)

  ok(list) ]#

#[ proc singleHighestWeigthShard*(topic: NsContentTopic): Result[RelayShard, string] =
  let count = ? shardCount(topic)

  let weights = repeat(1.0, count)

  let list = ? weightedShardList(topic, count, weights)

  let (pubsub, _) = list[list.len - 1]

  ok(pubsub) ]#

## Waku pub-sub topics definition and namespacing utils
##
## See 23/WAKU2-TOPICS RFC: https://rfc.vac.dev/spec/23/

{.push raises: [].}

import std/strutils, stew/base10, results
import ./parsing

export parsing

## Pub-sub topic

type PubsubTopic* = string

## Relay Shard

type RelayShard* = object
  clusterId*: uint16
  shardId*: uint16

const DefaultShardId* = uint16(0)
const DefaultClusterId* = uint16(0)
const DefaultRelayShard* =
  RelayShard(clusterId: DefaultClusterId, shardId: DefaultShardId)

# Serialization

proc `$`*(topic: RelayShard): string =
  ## Returns a string representation of a namespaced topic
  ## in the format `/waku/2/rs/<cluster-id>/<shard-id>
  return "/waku/2/rs/" & $topic.clusterId & "/" & $topic.shardId

const DefaultPubsubTopic* = $DefaultRelayShard

# Deserialization

const
  Waku2PubsubTopicPrefix = "/waku/2"
  StaticShardingPubsubTopicPrefix = Waku2PubsubTopicPrefix & "/rs"

proc parseStaticSharding*(
    T: type RelayShard, topic: PubsubTopic
): ParsingResult[RelayShard] =
  if not topic.startsWith(StaticShardingPubsubTopicPrefix):
    return err(
      ParsingError.invalidFormat("must start with " & StaticShardingPubsubTopicPrefix)
    )

  let parts = topic[11 ..< topic.len].split("/")
  if parts.len != 2:
    return err(ParsingError.invalidFormat("invalid topic structure"))

  let clusterPart = parts[0]
  if clusterPart.len == 0:
    return err(ParsingError.missingPart("cluster_id"))
  let clusterId = ?Base10.decode(uint16, clusterPart).mapErr(
    proc(err: auto): auto =
      ParsingError.invalidFormat($err)
  )

  let shardPart = parts[1]
  if shardPart.len == 0:
    return err(ParsingError.missingPart("shard_number"))
  let shardId = ?Base10.decode(uint16, shardPart).mapErr(
    proc(err: auto): auto =
      ParsingError.invalidFormat($err)
  )

  ok(RelayShard(clusterId: clusterId, shardId: shardId))

proc parse*(T: type RelayShard, topic: PubsubTopic): ParsingResult[RelayShard] =
  ## Splits a namespaced topic string into its constituent parts.
  ## The topic string has to be in the format `/<application>/<version>/<topic-name>/<encoding>`
  RelayShard.parseStaticSharding(topic)

# Pubsub topic compatibility

converter toPubsubTopic*(topic: RelayShard): PubsubTopic =
  $topic

proc `==`*[T: RelayShard](x, y: T): bool =
  if x.clusterId != y.clusterId:
    return false

  if x.shardId != y.shardId:
    return false

  return true

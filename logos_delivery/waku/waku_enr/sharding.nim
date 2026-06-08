{.push raises: [].}

import
  std/[options, bitops, sequtils, net],
  stew/endians2,
  results,
  chronicles,
  eth/keys,
  libp2p/[multiaddress, multicodec],
  libp2p/crypto/crypto
import ../common/enr, ../waku_core/topics/pubsub_topic

logScope:
  topics = "waku enr sharding"

const MaxShardIndex*: uint16 = 1023

const
  ShardingIndicesListEnrField* = "rs"
  ShardingIndicesListMaxLength* = 64
  ShardingBitVectorEnrField* = "rsv"

type RelayShards* = object
  clusterId*: uint16
  shardIds*: seq[uint16]

func topics*(rs: RelayShards): seq[RelayShard] =
  rs.shardIds.mapIt(RelayShard(clusterId: rs.clusterId, shardId: it))

func init*(T: type RelayShards, clusterId, shardId: uint16): Result[T, string] =
  if shardId > MaxShardIndex:
    return err("invalid shard Id")

  ok(RelayShards(clusterId: clusterId, shardIds: @[shardId]))

func init*(
    T: type RelayShards, clusterId: uint16, shardIds: varargs[uint16]
): Result[T, string] =
  if toSeq(shardIds).anyIt(it > MaxShardIndex):
    return err("invalid shard")

  let indicesSeq = deduplicate(@shardIds)
  if shardIds.len < 1:
    return err("invalid shard count")

  ok(RelayShards(clusterId: clusterId, shardIds: indicesSeq))

func init*(
    T: type RelayShards, clusterId: uint16, shardIds: seq[uint16]
): Result[T, string] =
  if shardIds.anyIt(it > MaxShardIndex):
    return err("invalid shard")

  let indicesSeq = deduplicate(shardIds)
  if shardIds.len < 1:
    return err("invalid shard count")

  ok(RelayShards(clusterId: clusterId, shardIds: indicesSeq))

func topicsToRelayShards*(topics: seq[string]): Result[Option[RelayShards], string] =
  if topics.len < 1:
    return ok(none(RelayShards))

  let parsedTopicsRes = topics.mapIt(RelayShard.parse(it))

  for res in parsedTopicsRes:
    res.isOkOr:
      return err("failed to parse topic: " & $error)

  if parsedTopicsRes.anyIt(it.get().clusterId != parsedTopicsRes[0].get().clusterId):
    return err("use shards with the same cluster Id.")

  let relayShard = ?RelayShards.init(
    parsedTopicsRes[0].get().clusterId, parsedTopicsRes.mapIt(it.get().shardId)
  )

  return ok(some(relayShard))

func contains*(rs: RelayShards, clusterId, shardId: uint16): bool =
  return rs.clusterId == clusterId and rs.shardIds.contains(shardId)

func contains*(rs: RelayShards, shard: RelayShard): bool =
  return rs.contains(shard.clusterId, shard.shardId)

func contains*(rs: RelayShards, topic: PubsubTopic): bool =
  let parseRes = RelayShard.parse(topic).valueOr:
    return false

  rs.contains(parseRes)

# ENR builder extension

func toIndicesList*(rs: RelayShards): EnrResult[seq[byte]] =
  if rs.shardIds.len > high(uint8).int:
    return err("shards list too long")

  var res: seq[byte]
  res.add(rs.clusterId.toBytesBE())

  res.add(rs.shardIds.len.uint8)
  for shardId in rs.shardIds:
    res.add(shardId.toBytesBE())

  ok(res)

func fromIndicesList*(buf: seq[byte]): Result[RelayShards, string] =
  if buf.len < 3:
    return
      err("insufficient data: expected at least 3 bytes, got " & $buf.len & " bytes")

  let clusterId = uint16.fromBytesBE(buf[0 .. 1])
  let length = int(buf[2])

  if buf.len != 3 + 2 * length:
    return err(
      "invalid data: `length` field is " & $length & " but " & $buf.len &
        " bytes were provided"
    )

  var shardIds: seq[uint16]
  for i in 0 ..< length:
    shardIds.add(uint16.fromBytesBE(buf[3 + 2 * i ..< 5 + 2 * i]))

  ok(RelayShards(clusterId: clusterId, shardIds: shardIds))

func toBitVector*(rs: RelayShards): seq[byte] =
  ## The value is comprised of a two-byte cluster id in network byte
  ## order concatenated with a 128-byte wide bit vector. The bit vector
  ## indicates which shard ids of the respective cluster id the node is part
  ## of. The right-most bit in the bit vector represents shard id 0, the left-most
  ## bit represents shard id 1023.
  var res: seq[byte]
  res.add(rs.clusterId.toBytesBE())

  var vec = newSeq[byte](128)
  for shardId in rs.shardIds:
    vec[shardId div 8].setBit(shardId mod 8)

  res.add(vec)

  res

func fromBitVector(buf: seq[byte]): EnrResult[RelayShards] =
  if buf.len != 130:
    return err("invalid data: expected 130 bytes")

  let clusterId = uint16.fromBytesBE(buf[0 .. 1])
  var shardIds: seq[uint16]

  for i in 0u16 ..< 128u16:
    for j in 0u16 ..< 8u16:
      if not buf[2 + i].testBit(j):
        continue

      shardIds.add(j + 8 * i)

  ok(RelayShards(clusterId: clusterId, shardIds: shardIds))

func withWakuRelayShardingIndicesList*(
    builder: var EnrBuilder, rs: RelayShards
): EnrResult[void] =
  let value = ?rs.toIndicesList()
  builder.addFieldPair(ShardingIndicesListEnrField, value)
  ok()

func withWakuRelayShardingBitVector*(
    builder: var EnrBuilder, rs: RelayShards
): EnrResult[void] =
  let value = rs.toBitVector()
  builder.addFieldPair(ShardingBitVectorEnrField, value)
  ok()

func withWakuRelaySharding*(builder: var EnrBuilder, rs: RelayShards): EnrResult[void] =
  if rs.shardIds.len >= ShardingIndicesListMaxLength:
    builder.withWakuRelayShardingBitVector(rs)
  else:
    builder.withWakuRelayShardingIndicesList(rs)

func withShardedTopics*(
    builder: var EnrBuilder, topics: seq[string]
): Result[void, string] =
  let relayShardOp = topicsToRelayShards(topics).valueOr:
    return err("building ENR with relay sharding failed: " & $error)

  let relayShard = relayShardOp.valueOr:
    return ok()

  builder.withWakuRelaySharding(relayShard).isOkOr:
    return err($error)

  return ok()

# ENR record accessors (e.g., Record, TypedRecord, etc.)

proc relayShardingIndicesList*(record: TypedRecord): Option[RelayShards] =
  let field = record.tryGet(ShardingIndicesListEnrField, seq[byte]).valueOr:
    return none(RelayShards)

  let indexList = fromIndicesList(field).valueOr:
    info "invalid shards list", error = error
    return none(RelayShards)

  some(indexList)

proc relayShardingBitVector*(record: TypedRecord): Option[RelayShards] =
  let field = record.tryGet(ShardingBitVectorEnrField, seq[byte]).valueOr:
    return none(RelayShards)

  let bitVector = fromBitVector(field).valueOr:
    info "invalid shards bit vector", error = error
    return none(RelayShards)

  some(bitVector)

proc relaySharding*(record: TypedRecord): Option[RelayShards] =
  let indexList = record.relayShardingIndicesList().valueOr:
    return record.relayShardingBitVector()

  return some(indexList)

## Utils

proc containsShard*(r: Record, clusterId, shardId: uint16): bool =
  if shardId > MaxShardIndex:
    return false

  let record = r.toTyped().valueOr:
    trace "invalid ENR record", error = error
    return false

  let rs = record.relaySharding().valueOr:
    return false

  rs.contains(clusterId, shardId)

proc containsShard*(r: Record, shard: RelayShard): bool =
  return containsShard(r, shard.clusterId, shard.shardId)

proc containsShard*(r: Record, topic: PubsubTopic): bool =
  let parseRes = RelayShard.parse(topic).valueOr:
    info "invalid static sharding topic", topic = topic, error = error
    return false

  containsShard(r, parseRes)

proc isClusterMismatched*(record: Record, clusterId: uint16): bool =
  ## Check the ENR sharding info for matching cluster id
  if (let typedRecord = record.toTyped(); typedRecord.isOk()):
    if (let relayShard = typedRecord.get().relaySharding(); relayShard.isSome()):
      return relayShard.get().clusterId != clusterId

  return false

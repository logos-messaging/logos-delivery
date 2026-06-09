{.push raises: [].}

import std/options

import ../common/protobuf

type WakuMetadataRequest* = object
  clusterId*: Option[uint32]
  shards*: seq[uint32]

type WakuMetadataResponse* = object
  clusterId*: Option[uint32]
  shards*: seq[uint32]

proc encode*(rpc: WakuMetadataRequest): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.clusterId)
  for shard in rpc.shards:
    pb.write3(2, shard) # deprecated
  pb.writePacked(3, rpc.shards)
  pb.finish3()

  pb

proc decode*(T: type WakuMetadataRequest, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = WakuMetadataRequest()

  var clusterId: uint64
  if not ?pb.getField(1, clusterId):
    rpc.clusterId = none(uint32)
  else:
    rpc.clusterId = some(clusterId.uint32)

  var shards: seq[uint64]
  if ?pb.getPackedRepeatedField(3, shards):
    for shard in shards:
      rpc.shards.add(shard.uint32)
  elif ?pb.getPackedRepeatedField(2, shards):
    for shard in shards:
      rpc.shards.add(shard.uint32)
  elif ?pb.getRepeatedField(2, shards):
    for shard in shards:
      rpc.shards.add(shard.uint32)

  ok(rpc)

proc encode*(rpc: WakuMetadataResponse): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.clusterId)
  for shard in rpc.shards:
    pb.write3(2, shard) # deprecated
  pb.writePacked(3, rpc.shards)
  pb.finish3()

  pb

proc decode*(T: type WakuMetadataResponse, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = WakuMetadataResponse()

  var clusterId: uint64
  if not ?pb.getField(1, clusterId):
    rpc.clusterId = none(uint32)
  else:
    rpc.clusterId = some(clusterId.uint32)

  var shards: seq[uint64]

  if ?pb.getPackedRepeatedField(3, shards):
    for shard in shards:
      rpc.shards.add(shard.uint32)
  elif ?pb.getPackedRepeatedField(2, shards):
    for shard in shards:
      rpc.shards.add(shard.uint32)
  elif ?pb.getRepeatedField(2, shards):
    for shard in shards:
      rpc.shards.add(shard.uint32)

  ok(rpc)

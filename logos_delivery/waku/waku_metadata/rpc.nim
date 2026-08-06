{.push raises: [].}

import results
import protobuf_serialization, protobuf_serialization/pkg/results
import ../common/protobuf

type WakuMetadataRequest* = object
  clusterId*: Opt[uint32]
  shards*: seq[uint32]

type WakuMetadataResponse* = object
  clusterId*: Opt[uint32]
  shards*: seq[uint32]

# shards emitted twice: unpacked field 2 (deprecated) + packed field 3
type WakuMetadataPB {.proto2.} = object
  clusterId {.fieldNumber: 1, pint.}: Opt[uint32]
  shardsDeprecated {.fieldNumber: 2, pint, packed: false.}: seq[uint32]
  shardsPacked {.fieldNumber: 3, pint, packed: true.}: seq[uint32]

proc toPB(clusterId: Opt[uint32], shards: seq[uint32]): WakuMetadataPB =
  WakuMetadataPB(clusterId: clusterId, shardsDeprecated: shards, shardsPacked: shards)

proc shardsFrom(pb: WakuMetadataPB): seq[uint32] =
  if pb.shardsPacked.len > 0: pb.shardsPacked else: pb.shardsDeprecated

proc decodeMetadataPB(buffer: seq[byte]): ProtobufResult[WakuMetadataPB] =
  try:
    ok(Protobuf.decode(buffer, WakuMetadataPB))
  except SerializationError:
    err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

proc encode*(rpc: WakuMetadataRequest): seq[byte] =
  Protobuf.encode(toPB(rpc.clusterId, rpc.shards))

proc decode*(T: type WakuMetadataRequest, buffer: seq[byte]): ProtobufResult[T] =
  let pb = ?decodeMetadataPB(buffer)
  ok(WakuMetadataRequest(clusterId: pb.clusterId, shards: shardsFrom(pb)))

proc encode*(rpc: WakuMetadataResponse): seq[byte] =
  Protobuf.encode(toPB(rpc.clusterId, rpc.shards))

proc decode*(T: type WakuMetadataResponse, buffer: seq[byte]): ProtobufResult[T] =
  let pb = ?decodeMetadataPB(buffer)
  ok(WakuMetadataResponse(clusterId: pb.clusterId, shards: shardsFrom(pb)))

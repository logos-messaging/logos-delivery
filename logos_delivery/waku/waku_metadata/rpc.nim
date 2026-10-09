{.push raises: [].}

import results

import ../common/protobuf

type
  WakuMetadataRequest* = object
    clusterId*: Opt[uint32]
    shards*: seq[uint32]

  WakuMetadataResponse* = object
    clusterId*: Opt[uint32]
    shards*: seq[uint32]

  MetadataRow {.proto3.} = object
    ## The wire form of a metadata request and response. Since #2511, a node
    ## writes the shards in field 2, unpacked, and in field 3, packed. go-waku
    ## writes and reads field 3 only. The schema has field 2 only.
    clusterId {.fieldNumber: 1, pint.}: Opt[uint32]
    shardsDeprecated {.fieldNumber: 2, pint, packed: false.}: seq[uint32]
    shards {.fieldNumber: 3, pint, packed: true.}: seq[uint32]

protobufCodec(MetadataRow)

proc encodeRow(clusterId: Opt[uint32], shards: seq[uint32]): seq[byte] =
  MetadataRow(clusterId: clusterId, shardsDeprecated: shards, shards: shards).encode()

proc decodeRow(buffer: seq[byte]): ProtobufResult[(Opt[uint32], seq[uint32])] =
  let row = ?MetadataRow.decode(buffer)
  # Field 3 first, then field 2 in each form, as master reads them.
  let shards = if row.shards.len > 0: row.shards else: row.shardsDeprecated
  ok((row.clusterId, shards))

proc encode*(rpc: WakuMetadataRequest): seq[byte] =
  encodeRow(rpc.clusterId, rpc.shards)

proc encode*(rpc: WakuMetadataResponse): seq[byte] =
  encodeRow(rpc.clusterId, rpc.shards)

proc decode*(T: type WakuMetadataRequest, buffer: seq[byte]): ProtobufResult[T] =
  let (clusterId, shards) = ?decodeRow(buffer)
  ok(T(clusterId: clusterId, shards: shards))

proc decode*(T: type WakuMetadataResponse, buffer: seq[byte]): ProtobufResult[T] =
  let (clusterId, shards) = ?decodeRow(buffer)
  ok(T(clusterId: clusterId, shards: shards))

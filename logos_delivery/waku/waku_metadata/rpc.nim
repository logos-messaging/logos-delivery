{.push raises: [].}

import results

import ../common/protobuf

type WakuMetadataRequest* {.proto3.} = object
  clusterId* {.fieldNumber: 1, pint.}: Opt[uint32]
  shards* {.fieldNumber: 2, pint.}: seq[uint32]

type WakuMetadataResponse* {.proto3.} = object
  clusterId* {.fieldNumber: 1, pint.}: Opt[uint32]
  shards* {.fieldNumber: 2, pint.}: seq[uint32]

protobufCodec(WakuMetadataRequest)
protobufCodec(WakuMetadataResponse)

{.push raises: [].}

import results, ../common/protobuf, ../waku_core, ./rpc

const DefaultMaxRpcSize* = -1

proc validateDecoded(rpc: LightpushRequest): ProtobufResult[void] =
  validateWakuMessageFields(rpc.message)

protobufCodec(LightpushRequest, validateDecoded)
protobufCodec(LightPushResponse)

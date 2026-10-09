{.push raises: [].}

import results, ../common/protobuf, ../waku_core, ./rpc

const DefaultMaxPushResponseSize* = DefaultSafetyBufferProtocolOverhead
  ## The largest lightpush response that a client reads.

proc validateDecoded(rpc: LightpushRequest): ProtobufResult[void] =
  validateWakuMessageFields(rpc.message)

protobufCodec(LightpushRequest, validateDecoded)
protobufCodec(LightPushResponse)

{.push raises: [].}

import results, ../common/protobuf, ../waku_core, ./rpc

const DefaultMaxRpcSize* = -1

proc validateDecoded(rpc: LightpushRequest): ProtobufResult[void] =
  if rpc.requestId.len == 0:
    return err(ProtobufError.missingRequiredField("request_id"))
  validateWakuMessageFields(rpc.message)

proc validateDecoded(rpc: LightPushResponse): ProtobufResult[void] =
  if rpc.requestId.len == 0:
    return err(ProtobufError.missingRequiredField("request_id"))
  if rpc.statusCode == LightPushStatusCode(0):
    return err(ProtobufError.missingRequiredField("status_code"))
  ok()

protobufCodec(LightpushRequest, validateDecoded)
protobufCodec(LightPushResponse, validateDecoded)

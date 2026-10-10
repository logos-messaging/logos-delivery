{.push raises: [].}

import results, ../common/protobuf, ../waku_core, ./rpc

const DefaultMaxRpcSize* = -1

proc validateDecoded(rpc: PushRPC): ProtobufResult[void] =
  if rpc.requestId.len == 0:
    return err(ProtobufError.missingRequiredField("request_id"))
  if rpc.request.isSome():
    return validateWakuMessageFields(rpc.request.get().message)
  ok()

protobufCodec(PushRPC, validateDecoded)

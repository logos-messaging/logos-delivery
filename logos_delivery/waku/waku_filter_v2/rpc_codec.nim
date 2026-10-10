{.push raises: [].}

import results, ../common/protobuf, ../waku_core, ./rpc

const
  DefaultMaxSubscribeSize* = 10 * DefaultMaxWakuMessageSize + 64 * 1024
    # We add a 64kB safety buffer for protocol overhead
  DefaultMaxSubscribeResponseSize* = 64 * 1024 # Responses are small. 64kB safety buffer.
  DefaultMaxPushSize* = 10 * DefaultMaxWakuMessageSize + 64 * 1024
    # We add a 64kB safety buffer for protocol overhead

proc validateDecoded(rpc: FilterSubscribeRequest): ProtobufResult[void] =
  if rpc.requestId.len == 0:
    return err(ProtobufError.missingRequiredField("request_id"))
  ok()

proc validateDecoded(rpc: FilterSubscribeResponse): ProtobufResult[void] =
  if rpc.requestId.len == 0:
    return err(ProtobufError.missingRequiredField("request_id"))
  if rpc.statusCode == 0:
    return err(ProtobufError.missingRequiredField("status_code"))
  ok()

proc validateDecoded(rpc: MessagePush): ProtobufResult[void] =
  if rpc.pubsubTopic.len == 0:
    return err(ProtobufError.missingRequiredField("pubsub_topic"))
  validateWakuMessageFields(rpc.wakuMessage)

protobufCodec(FilterSubscribeRequest, validateDecoded)
protobufCodec(FilterSubscribeResponse, validateDecoded)
protobufCodec(MessagePush, validateDecoded)

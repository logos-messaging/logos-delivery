{.push raises: [].}

import results, ../common/protobuf, ../waku_core, ./rpc

const
  DefaultMaxSubscribeSize* = 10 * DefaultMaxWakuMessageSize + 64 * 1024
    # We add a 64kB safety buffer for protocol overhead
  DefaultMaxSubscribeResponseSize* = 64 * 1024 # Responses are small. 64kB safety buffer.
  DefaultMaxPushSize* = 10 * DefaultMaxWakuMessageSize + 64 * 1024
    # We add a 64kB safety buffer for protocol overhead

proc validateDecoded(rpc: MessagePush): ProtobufResult[void] =
  if rpc.pubsubTopic.len == 0:
    return err(ProtobufError.missingRequiredField("pubsub_topic"))
  validateWakuMessageFields(rpc.wakuMessage)

protobufCodec(FilterSubscribeRequest)
protobufCodec(FilterSubscribeResponse)
protobufCodec(MessagePush, validateDecoded)

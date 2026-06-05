{.push raises: [].}

import std/options
import ../common/protobuf, ../waku_core, ./rpc

const
  DefaultMaxSubscribeSize* = 10 * DefaultMaxWakuMessageSize + 64 * 1024
    # We add a 64kB safety buffer for protocol overhead
  DefaultMaxSubscribeResponseSize* = 64 * 1024 # Responses are small. 64kB safety buffer.
  DefaultMaxPushSize* = 10 * DefaultMaxWakuMessageSize + 64 * 1024
    # We add a 64kB safety buffer for protocol overhead

proc encode*(rpc: FilterSubscribeRequest): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.requestId)
  pb.write3(2, uint32(ord(rpc.filterSubscribeType)))

  pb.write3(10, rpc.pubsubTopic)

  for contentTopic in rpc.contentTopics:
    pb.write3(11, contentTopic)

  pb

proc decode*(T: type FilterSubscribeRequest, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = FilterSubscribeRequest()

  if not ?pb.getField(1, rpc.requestId):
    return err(ProtobufError.missingRequiredField("request_id"))

  var filterSubscribeType: uint32
  if not ?pb.getField(2, filterSubscribeType):
    # Revert to ping by default if not set
    rpc.filterSubscribeType = FilterSubscribeType.SUBSCRIBER_PING
  else:
    rpc.filterSubscribeType = FilterSubscribeType(filterSubscribeType)

  var pubsubTopic: PubsubTopic
  if not ?pb.getField(10, pubsubTopic):
    rpc.pubsubTopic = none(PubsubTopic)
  else:
    rpc.pubsubTopic = some(pubsubTopic)

  discard ?pb.getRepeatedField(11, rpc.contentTopics)

  ok(rpc)

proc encode*(rpc: FilterSubscribeResponse): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.requestId)
  pb.write3(10, rpc.statusCode)
  pb.write3(11, rpc.statusDesc)

  pb

proc decode*(T: type FilterSubscribeResponse, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = FilterSubscribeResponse()

  if not ?pb.getField(1, rpc.requestId):
    return err(ProtobufError.missingRequiredField("request_id"))

  if not ?pb.getField(10, rpc.statusCode):
    return err(ProtobufError.missingRequiredField("status_code"))

  var statusDesc: string
  if not ?pb.getField(11, statusDesc):
    rpc.statusDesc = none(string)
  else:
    rpc.statusDesc = some(statusDesc)

  ok(rpc)

proc encode*(rpc: MessagePush): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.wakuMessage.encode())
  pb.write3(2, rpc.pubsubTopic)

  pb

proc decode*(T: type MessagePush, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = MessagePush()

  var message: seq[byte]
  if not ?pb.getField(1, message):
    return err(ProtobufError.missingRequiredField("message"))
  else:
    rpc.wakuMessage = ?WakuMessage.decode(message)

  if not ?pb.getField(2, rpc.pubsubTopic):
    return err(ProtobufError.missingRequiredField("pubsub_topic"))

  ok(rpc)

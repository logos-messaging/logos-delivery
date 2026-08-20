{.push raises: [].}

import
  protobuf_serialization,
  protobuf_serialization/pkg/results,
  protobuf_serialization/std/enums
import ../common/protobuf, ../waku_core, ./rpc

const
  DefaultMaxSubscribeSize* = 10 * DefaultMaxWakuMessageSize + 64 * 1024
    # We add a 64kB safety buffer for protocol overhead
  DefaultMaxSubscribeResponseSize* = 64 * 1024 # Responses are small. 64kB safety buffer.
  DefaultMaxPushSize* = 10 * DefaultMaxWakuMessageSize + 64 * 1024
    # We add a 64kB safety buffer for protocol overhead

# absent field 2 (Opt) decodes to SUBSCRIBER_PING
type FilterSubscribeRequestPB {.proto2.} = object
  requestId {.fieldNumber: 1, required.}: string
  filterSubscribeType {.fieldNumber: 2, ext.}: Opt[FilterSubscribeType]
  pubsubTopic {.fieldNumber: 10.}: Opt[PubsubTopic]
  contentTopics {.fieldNumber: 11.}: seq[ContentTopic]

proc encode*(rpc: FilterSubscribeRequest): seq[byte] =
  Protobuf.encode(
    FilterSubscribeRequestPB(
      requestId: rpc.requestId,
      filterSubscribeType: Opt.some(rpc.filterSubscribeType),
      pubsubTopic: rpc.pubsubTopic,
      contentTopics: rpc.contentTopics,
    )
  )

proc encode*(rpc: FilterSubscribeResponse): seq[byte] =
  Protobuf.encode(rpc)

proc encode*(rpc: MessagePush): seq[byte] =
  Protobuf.encode(rpc)

# non-generic: mixin Reader must resolve here
proc decodeFilterSubscribeRequest(
    buffer: seq[byte]
): ProtobufResult[FilterSubscribeRequest] =
  var pb: FilterSubscribeRequestPB
  try:
    pb = Protobuf.decode(buffer, FilterSubscribeRequestPB)
  except SerializationError:
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))
  ok(
    FilterSubscribeRequest(
      requestId: pb.requestId,
      filterSubscribeType:
        pb.filterSubscribeType.get(FilterSubscribeType.SUBSCRIBER_PING),
      pubsubTopic: pb.pubsubTopic,
      contentTopics: pb.contentTopics,
    )
  )

proc decodeFilterSubscribeResponse(
    buffer: seq[byte]
): ProtobufResult[FilterSubscribeResponse] =
  try:
    ok(Protobuf.decode(buffer, FilterSubscribeResponse))
  except SerializationError:
    err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

proc decodeMessagePush(buffer: seq[byte]): ProtobufResult[MessagePush] =
  try:
    ok(Protobuf.decode(buffer, MessagePush))
  except SerializationError:
    err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

proc decode*(T: type FilterSubscribeRequest, buffer: seq[byte]): ProtobufResult[T] =
  decodeFilterSubscribeRequest(buffer)

proc decode*(T: type FilterSubscribeResponse, buffer: seq[byte]): ProtobufResult[T] =
  decodeFilterSubscribeResponse(buffer)

proc decode*(T: type MessagePush, buffer: seq[byte]): ProtobufResult[T] =
  decodeMessagePush(buffer)

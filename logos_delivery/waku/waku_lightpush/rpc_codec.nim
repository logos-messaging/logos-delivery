{.push raises: [].}

import protobuf_serialization, protobuf_serialization/pkg/results
import ../common/protobuf, ../waku_core, ./rpc

const DefaultMaxRpcSize* = -1

proc encode*(rpc: LightpushRequest): seq[byte] =
  Protobuf.encode(rpc)

proc encode*(rpc: LightPushResponse): seq[byte] =
  Protobuf.encode(rpc)

proc decodeLightpushRequest(buffer: seq[byte]): ProtobufResult[LightpushRequest] =
  try:
    ok(Protobuf.decode(buffer, LightpushRequest))
  except SerializationError:
    err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

proc decodeLightPushResponse(buffer: seq[byte]): ProtobufResult[LightPushResponse] =
  try:
    ok(Protobuf.decode(buffer, LightPushResponse))
  except SerializationError:
    err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

proc decode*(T: type LightpushRequest, buffer: seq[byte]): ProtobufResult[T] =
  decodeLightpushRequest(buffer)

proc decode*(T: type LightPushResponse, buffer: seq[byte]): ProtobufResult[T] =
  decodeLightPushResponse(buffer)

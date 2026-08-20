{.push raises: [].}

import protobuf_serialization, protobuf_serialization/pkg/results
import ../common/protobuf, ../waku_core, ./rpc

const DefaultMaxRpcSize* = -1

proc encode*(rpc: PushRequest): seq[byte] =
  Protobuf.encode(rpc)

proc encode*(rpc: PushResponse): seq[byte] =
  Protobuf.encode(rpc)

proc encode*(rpc: PushRPC): seq[byte] =
  Protobuf.encode(rpc)

# non-generic: mixin Reader must resolve here
proc decodePushRequest(buffer: seq[byte]): ProtobufResult[PushRequest] =
  try:
    ok(Protobuf.decode(buffer, PushRequest))
  except SerializationError:
    err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

proc decodePushResponse(buffer: seq[byte]): ProtobufResult[PushResponse] =
  try:
    ok(Protobuf.decode(buffer, PushResponse))
  except SerializationError:
    err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

proc decodePushRPC(buffer: seq[byte]): ProtobufResult[PushRPC] =
  try:
    ok(Protobuf.decode(buffer, PushRPC))
  except SerializationError:
    err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

proc decode*(T: type PushRequest, buffer: seq[byte]): ProtobufResult[T] =
  decodePushRequest(buffer)

proc decode*(T: type PushResponse, buffer: seq[byte]): ProtobufResult[T] =
  decodePushResponse(buffer)

proc decode*(T: type PushRPC, buffer: seq[byte]): ProtobufResult[T] =
  decodePushRPC(buffer)

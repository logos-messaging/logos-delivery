{.push raises: [].}

import results, protobuf_serialization, protobuf_serialization/pkg/results
import ../waku_core

type LightPushStatusCode* = distinct uint32
proc `==`*(a, b: LightPushStatusCode): bool {.borrow.}
proc `$`*(code: LightPushStatusCode): string {.borrow.}

# LightPushStatusCode (distinct uint32) as a plain varint
func supportsPacked*(T: type LightPushStatusCode, ProtoType: type ProtobufExt): bool =
  false

func computeFieldSize*(
    field: int,
    value: LightPushStatusCode,
    ProtoType: type ProtobufExt,
    skipDefault: static bool,
): int =
  computeFieldSize(field, uint32(value), puint32, skipDefault)

proc writeField*(
    stream: OutputStream,
    field: int,
    value: LightPushStatusCode,
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  writeField(stream, field, uint32(value), puint32, skipDefault)

proc readFieldInto*(
    stream: InputStream,
    value: var LightPushStatusCode,
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  var v: uint32
  if readFieldInto(stream, v, header, puint32):
    value = LightPushStatusCode(v)
    true
  else:
    false

type
  LightpushRequest* {.proto2.} = object
    requestId* {.fieldNumber: 1, required.}: string
    pubSubTopic* {.fieldNumber: 20.}: Opt[PubsubTopic]
    message* {.fieldNumber: 21, ext, required.}: WakuMessage

  LightPushResponse* {.proto2.} = object
    requestId* {.fieldNumber: 1, required.}: string
    statusCode* {.fieldNumber: 10, ext, required.}: LightPushStatusCode
    statusDesc* {.fieldNumber: 11.}: Opt[string]
    relayPeerCount* {.fieldNumber: 12, pint.}: Opt[uint32]

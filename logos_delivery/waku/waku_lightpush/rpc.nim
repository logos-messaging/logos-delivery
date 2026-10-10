{.push raises: [].}

import results, ../common/protobuf, ../waku_core

type LightPushStatusCode* = distinct uint32
proc `==`*(a, b: LightPushStatusCode): bool {.borrow.}
proc `$`*(code: LightPushStatusCode): string {.borrow.}

# The library does not encode a `distinct` type. These procs encode
# `LightPushStatusCode` as a `uint32` field.

Protobuf.extensionDefaults(LightPushStatusCode, puint32)

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
  var code: uint32
  if not readFieldInto(stream, code, header, puint32):
    return false
  value = LightPushStatusCode(code)
  true

type
  LightpushRequest* {.proto3.} = object
    requestId* {.fieldNumber: 1.}: string
    pubSubTopic* {.fieldNumber: 20.}: Opt[PubsubTopic]
    message* {.fieldNumber: 21.}: WakuMessage

  LightPushResponse* {.proto3.} = object
    requestId* {.fieldNumber: 1.}: string
    statusCode* {.fieldNumber: 10, ext.}: LightPushStatusCode
    statusDesc* {.fieldNumber: 11.}: Opt[string]
    relayPeerCount* {.fieldNumber: 12, pint.}: Opt[uint32]

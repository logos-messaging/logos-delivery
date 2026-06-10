# Extensions for libp2p's protobuf library implementation

{.push raises: [].}

import std/options, libp2p/protobuf/minprotobuf, libp2p/varint

export minprotobuf, varint

## Custom errors

type
  ProtobufErrorKind* {.pure.} = enum
    DecodeFailure
    MissingRequiredField
    InvalidLengthField

  ProtobufError* = object
    case kind*: ProtobufErrorKind
    of DecodeFailure:
      error*: minprotobuf.ProtoError
    of MissingRequiredField, InvalidLengthField:
      field*: string

  ProtobufResult*[T] = Result[T, ProtobufError]

converter toProtobufError*(err: minprotobuf.ProtoError): ProtobufError =
  case err
  of minprotobuf.ProtoError.RequiredFieldMissing:
    ProtobufError(kind: ProtobufErrorKind.MissingRequiredField, field: "unknown")
  else:
    ProtobufError(kind: ProtobufErrorKind.DecodeFailure, error: err)

proc missingRequiredField*(T: type ProtobufError, field: string): T =
  ProtobufError(kind: ProtobufErrorKind.MissingRequiredField, field: field)

proc invalidLengthField*(T: type ProtobufError, field: string): T =
  ProtobufError(kind: ProtobufErrorKind.InvalidLengthField, field: field)

## Extension methods

proc write3*(proto: var ProtoBuffer, field: int, value: auto) =
  when value is Option:
    if value.isSome():
      proto.write(field, value.get())
  else:
    proto.write(field, value)

proc finish3*(proto: var ProtoBuffer) =
  if proto.buffer.len > 0:
    proto.finish()
  else:
    proto.offset = 0

proc `==`*(a: zint64, b: zint64): bool =
  int64(a) == int64(b)

proc `$`*(err: ProtobufError): string =
  case err.kind
  of DecodeFailure:
    return $err.error ## assume that ProtoError is pure
  of MissingRequiredField:
    return "MissingRequiredField " & err.field
  of InvalidLengthField:
    return "InvalidLengthField " & err.field

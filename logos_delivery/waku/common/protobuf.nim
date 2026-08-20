# Waku protobuf result/error types.

{.push raises: [].}

import results
export results

## Custom errors

type
  ProtobufErrorKind* {.pure.} = enum
    DecodeFailure
    MissingRequiredField
    InvalidLengthField

  ProtobufError* = object
    case kind*: ProtobufErrorKind
    of DecodeFailure:
      discard
    of MissingRequiredField, InvalidLengthField:
      field*: string

  ProtobufResult*[T] = Result[T, ProtobufError]

proc missingRequiredField*(T: type ProtobufError, field: string): T =
  ProtobufError(kind: ProtobufErrorKind.MissingRequiredField, field: field)

proc invalidLengthField*(T: type ProtobufError, field: string): T =
  ProtobufError(kind: ProtobufErrorKind.InvalidLengthField, field: field)

proc `$`*(err: ProtobufError): string =
  case err.kind
  of DecodeFailure:
    "DecodeFailure"
  of MissingRequiredField:
    "MissingRequiredField " & err.field
  of InvalidLengthField:
    "InvalidLengthField " & err.field

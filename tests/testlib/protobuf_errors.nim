## Equality of `ProtobufError` values, so that a test compares the whole
## error. Nim makes no `==` for an object with a `case` part.

import logos_delivery/waku/common/protobuf

proc `==`*(a, b: ProtobufError): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of ProtobufErrorKind.DecodeFailure:
    a.error == b.error
  of ProtobufErrorKind.MissingRequiredField, ProtobufErrorKind.InvalidLengthField:
    a.field == b.field

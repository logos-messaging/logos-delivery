## Protobuf support for logos-delivery.
##
## The domain types of each codec have the `{.proto3.}` pragmas of
## `protobuf_serialization`. This module exports the library, the support for
## `Opt` and enum fields, and the error type of the codecs.

{.push raises: [].}

import results
import protobuf_serialization except ProtobufError
import protobuf_serialization/pkg/results as pb_results
import protobuf_serialization/std/enums as pb_enums

export protobuf_serialization except ProtobufError
export pb_results, pb_enums

## Custom errors

type
  ProtobufErrorKind* {.pure.} = enum
    DecodeFailure
    MissingRequiredField
    InvalidLengthField

  ProtobufError* = object
    case kind*: ProtobufErrorKind
    of DecodeFailure:
      error*: string
    of MissingRequiredField, InvalidLengthField:
      field*: string

  ProtobufResult*[T] = Result[T, ProtobufError]

proc decodeFailure*(T: type ProtobufError, error: string): T =
  ProtobufError(kind: ProtobufErrorKind.DecodeFailure, error: error)

proc missingRequiredField*(T: type ProtobufError, field: string): T =
  ProtobufError(kind: ProtobufErrorKind.MissingRequiredField, field: field)

proc invalidLengthField*(T: type ProtobufError, field: string): T =
  ProtobufError(kind: ProtobufErrorKind.InvalidLengthField, field: field)

proc `$`*(err: ProtobufError): string =
  case err.kind
  of DecodeFailure:
    return "DecodeFailure " & err.error
  of MissingRequiredField:
    return "MissingRequiredField " & err.field
  of InvalidLengthField:
    return "InvalidLengthField " & err.field

## Codec procs

template noValidation(value: untyped): ProtobufResult[void] =
  ## The validator that accepts each value, for a codec with no checks.
  ProtobufResult[void].ok()

template protobufCodec*(T: untyped, validator: untyped) =
  ## Makes `encode` and `decode` for the `{.proto3.}` type `T`. After the
  ## decode, `decode` calls `validator(value)`. The validator returns
  ## `ProtobufResult[void]`. A validator with a `var` parameter can also
  ## correct the value. `decode` calls the validator for `T` only, so the
  ## validator of an object must check the objects that it contains.
  ##
  ## `decode` has a `type` parameter, so it is generic, and Nim finds the
  ## `mixin` symbols of the library at the call site of a generic proc. The
  ## inner proc is not generic, so a caller needs no import of the library.
  proc encode*(value: T): seq[byte] =
    Protobuf.encode(value)

  proc `decodeProto3 T`(buffer: seq[byte]): ProtobufResult[T] =
    var value =
      try:
        Protobuf.decode(buffer, T)
      except SerializationError as e:
        return err(ProtobufError.decodeFailure(e.msg))
    ?validator(value)
    ok(value)

  proc decode*(_: type T, buffer: seq[byte]): ProtobufResult[T] =
    `decodeProto3 T`(buffer)

template protobufCodec*(T: untyped) =
  ## Makes `encode` and `decode` for the `{.proto3.}` type `T`, with no check
  ## after the decode.
  protobufCodec(T, noValidation)

## Fixed byte arrays

# The library does not encode `array[N, byte]`. These procs encode it as a
# `bytes` field. A field of this type must have the `ext` pragma. The decode
# procs accept only a value of exactly `N` bytes.

func supportsPacked*[N: static int](
    _: type array[N, byte], ProtoType: type ProtobufExt
): bool =
  false

func supportsPacked*[N: static int](
    _: type seq[array[N, byte]], ProtoType: type ProtobufExt
): bool =
  false

func computeFieldSize*[N: static int](
    field: int,
    value: array[N, byte],
    ProtoType: type ProtobufExt,
    skipDefault: static bool,
): int =
  computeFieldSize(field, @value, pbytes, skipDefault)

func computeFieldSize*[N: static int](
    field: int,
    value: seq[array[N, byte]],
    ProtoType: type ProtobufExt,
    skipDefault: static bool,
): int =
  var size = 0
  for item in value:
    size += computeFieldSize(field, @item, pbytes, false)
  size

proc writeField*[N: static int](
    stream: OutputStream,
    field: int,
    value: array[N, byte],
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  writeField(stream, field, @value, pbytes, skipDefault)

proc writeField*[N: static int](
    stream: OutputStream,
    field: int,
    value: seq[array[N, byte]],
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  for item in value:
    writeField(stream, field, @item, pbytes, false)

proc readFieldInto*[N: static int](
    stream: InputStream,
    value: var array[N, byte],
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  var data: seq[byte]
  if not readFieldInto(stream, data, header, pbytes):
    return false
  if data.len != N:
    raise
      (ref ProtobufValueError)(msg: "expected " & $N & " bytes, received " & $data.len)
  for i in 0 ..< N:
    value[i] = data[i]
  true

proc readFieldInto*[N: static int](
    stream: InputStream,
    value: var seq[array[N, byte]],
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  var item: array[N, byte]
  if not readFieldInto(stream, item, header, ProtoType):
    return false
  value.add(item)
  true

{.used.}

import results, testutils/unittests
import logos_delivery/waku/common/protobuf

## Fixtures

const MaxTestRpcFieldLen = 5

type
  TestRpc {.proto3.} = object
    testField {.fieldNumber: 1.}: string

  TestOtherRpc {.proto3.} = object
    otherField {.fieldNumber: 666.}: string

  TestHashRpc {.proto3.} = object
    hash {.fieldNumber: 1, ext.}: array[4, byte]
    hashes {.fieldNumber: 2, ext.}: seq[array[4, byte]]

proc init(T: type TestRpc, field: string): T =
  T(testField: field)

proc validateDecoded(rpc: TestRpc): ProtobufResult[void] =
  if rpc.testField.len == 0:
    return err(ProtobufError.missingRequiredField("test_field"))
  if rpc.testField.len > MaxTestRpcFieldLen:
    return err(ProtobufError.invalidLengthField("test_field"))
  ok()

protobufCodec(TestRpc, validateDecoded)
protobufCodec(TestOtherRpc)
protobufCodec(TestHashRpc)

## Tests

suite "Waku Common - protobuf codec":
  test "serialize and deserialize - valid length field":
    ## Given
    let field = "12345"

    let rpc = TestRpc.init(field)

    ## When
    let encodedRpc = rpc.encode()
    let decodedRpcRes = TestRpc.decode(encodedRpc)

    ## Then
    check:
      decodedRpcRes.isOk()

    let decodedRpc = decodedRpcRes.tryGet()
    check:
      decodedRpc.testField == field

  test "serialize and deserialize - missing required field":
    ## Given a message with only a field that `TestRpc` does not know
    let encodedRpc = TestOtherRpc(otherField: "12345").encode()

    ## When
    let decodedRpcRes = TestRpc.decode(encodedRpc)

    ## Then
    check:
      decodedRpcRes.isErr()

    let error = decodedRpcRes.tryError()
    check:
      error.kind == ProtobufErrorKind.MissingRequiredField
      error.field == "test_field"

  test "serialize and deserialize - invalid length field":
    ## Given
    let field = "123456" # field.len = MaxTestRpcFieldLen + 1

    let rpc = TestRpc.init(field)

    ## When
    let encodedRpc = rpc.encode()
    let decodedRpcRes = TestRpc.decode(encodedRpc)

    ## Then
    check:
      decodedRpcRes.isErr()

    let error = decodedRpcRes.tryError()
    check:
      error.kind == ProtobufErrorKind.InvalidLengthField
      error.field == "test_field"

  test "deserialize - malformed bytes":
    ## Given field 1 with a length of 5 and only 1 byte of data
    let buffer = @[byte 0x0a, 0x05, 0x31]

    ## When
    let decodedRpcRes = TestRpc.decode(buffer)

    ## Then
    check:
      decodedRpcRes.isErr()
      decodedRpcRes.tryError().kind == ProtobufErrorKind.DecodeFailure

  test "serialize and deserialize - fixed byte arrays":
    ## Given
    let rpc = TestHashRpc(
      hash: [byte 1, 2, 3, 4], hashes: @[[byte 5, 6, 7, 8], [byte 9, 10, 11, 12]]
    )

    ## When
    let encodedRpc = rpc.encode()
    let decodedRpcRes = TestHashRpc.decode(encodedRpc)

    ## Then each array is a `bytes` field, and the repeated field is not packed
    check:
      encodedRpc ==
        @[
          byte 0x0a, 0x04, 1, 2, 3, 4, 0x12, 0x04, 5, 6, 7, 8, 0x12, 0x04, 9, 10, 11, 12
        ]
      decodedRpcRes.isOk()
      decodedRpcRes.tryGet() == rpc

  test "deserialize - fixed byte array of the wrong length":
    ## Given field 1 with 3 bytes for an `array[4, byte]`
    let buffer = @[byte 0x0a, 0x03, 1, 2, 3]

    ## When
    let decodedRpcRes = TestHashRpc.decode(buffer)

    ## Then
    check:
      decodedRpcRes.isErr()
      decodedRpcRes.tryError().kind == ProtobufErrorKind.DecodeFailure

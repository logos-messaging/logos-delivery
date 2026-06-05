{.used.}

import testutils/unittests
import logos_delivery/waku/common/protobuf

## Fixtures

const MaxTestRpcFieldLen = 5

type TestRpc = object
  testField*: string

proc init(T: type TestRpc, field: string): T =
  T(testField: field)

proc encode(rpc: TestRpc): ProtoBuffer =
  var pb = initProtoBuffer()
  pb.write3(1, rpc.testField)
  pb.finish3()
  pb

proc encodeWithBadFieldId(rpc: TestRpc): ProtoBuffer =
  var pb = initProtoBuffer()
  pb.write3(666, rpc.testField)
  pb.finish3()
  pb

proc decode(T: type TestRpc, buf: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buf)

  var field: string
  if not ?pb.getField(1, field):
    return err(ProtobufError.missingRequiredField("test_field"))
  if field.len > MaxTestRpcFieldLen:
    return err(ProtobufError.invalidLengthField("test_field"))

  ok(TestRpc.init(field))

## Tests

suite "Waku Common - libp2p minprotobuf wrapper":
  test "serialize and deserialize - valid length field":
    ## Given
    let field = "12345"

    let rpc = TestRpc.init(field)

    ## When
    let encodedRpc = rpc.encode()
    let decodedRpcRes = TestRpc.decode(encodedRpc.buffer)

    ## Then
    check:
      decodedRpcRes.isOk()

    let decodedRpc = decodedRpcRes.tryGet()
    check:
      decodedRpc.testField == field

  test "serialize and deserialize - missing required field":
    ## Given
    let field = "12345"

    let rpc = TestRpc.init(field)

    ## When
    let encodedRpc = rpc.encodeWithBadFieldId()
    let decodedRpcRes = TestRpc.decode(encodedRpc.buffer)

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
    let decodedRpcRes = TestRpc.decode(encodedRpc.buffer)

    ## Then
    check:
      decodedRpcRes.isErr()

    let error = decodedRpcRes.tryError()
    check:
      error.kind == ProtobufErrorKind.InvalidLengthField
      error.field == "test_field"

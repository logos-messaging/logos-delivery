{.used.}

import results, stew/byteutils, testutils/unittests
import
  logos_delivery/waku/[common/protobuf, waku_lightpush/rpc, waku_lightpush/rpc_codec],
  ../testlib/protobuf_errors

suite "Waku Lightpush - RPC codec":
  test "a request with a nested message without a content topic is refused":
    # Request id "r", and field 21 holds a message with a payload only.
    let res = LightpushRequest.decode(hexToSeqByte("0a0172aa01030a0101"))
    check:
      res.isErr()
      res.error == ProtobufError.missingRequiredField("content_topic")

  test "a request without a message is refused":
    let res = LightpushRequest.decode(hexToSeqByte("0a0172"))
    check:
      res.isErr()
      res.error == ProtobufError.missingRequiredField("message")

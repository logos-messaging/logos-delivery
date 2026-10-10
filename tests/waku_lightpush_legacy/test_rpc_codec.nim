{.used.}

import results, stew/byteutils, testutils/unittests
import
  logos_delivery/waku/
    [common/protobuf, waku_lightpush_legacy/rpc, waku_lightpush_legacy/rpc_codec],
  ../testlib/protobuf_errors

suite "Waku Legacy Lightpush - RPC codec":
  test "a request with a nested message without a content topic is refused":
    # Request id "r", and field 2 holds a push request for "/s" with a
    # message that has a payload only.
    let res = PushRPC.decode(hexToSeqByte("0a017212090a022f7312030a0101"))
    check:
      res.isErr()
      res.error == ProtobufError.missingRequiredField("content_topic")

  test "an rpc without a request id is refused":
    let res = PushRPC.decode(
      PushRPC(response: Opt.some(PushResponse(isSuccess: true))).encode()
    )
    check:
      res.isErr()
      res.error == ProtobufError.missingRequiredField("request_id")

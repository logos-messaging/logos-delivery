{.used.}

import std/strutils, results, stew/byteutils, testutils/unittests
import
  logos_delivery/waku/[common/protobuf, waku_filter_v2/rpc, waku_filter_v2/rpc_codec],
  ../testlib/protobuf_errors

suite "Waku Filter - RPC codec":
  test "a message push without a pubsub topic is refused":
    let res = MessagePush.decode(hexToSeqByte("0a070a010112022f74"))
    check:
      res.isErr()
      res.error == ProtobufError.missingRequiredField("pubsub_topic")

  test "a message push with a nested meta of MaxMetaAttrLength + 1 bytes is refused":
    let res = MessagePush.decode(
      hexToSeqByte("0a4a0a010112022f745a41" & "00".repeat(65) & "12022f73")
    )
    check:
      res.isErr()
      res.error == ProtobufError.invalidLengthField("meta")

  test "a message push with a nested message without a content topic is refused":
    let res = MessagePush.decode(hexToSeqByte("0a030a010112022f73"))
    check:
      res.isErr()
      res.error == ProtobufError.missingRequiredField("content_topic")

  test "a subscribe type outside the enum decodes as a ping":
    # Request id "r", and subscribe type 4.
    let res = FilterSubscribeRequest.decode(hexToSeqByte("0a01721004"))
    check:
      res.isOk()
      res.get(FilterSubscribeRequest()).filterSubscribeType ==
        FilterSubscribeType.SUBSCRIBER_PING

  test "a subscribe request without a request id is refused":
    let res = FilterSubscribeRequest.decode(
      FilterSubscribeRequest(filterSubscribeType: FilterSubscribeType.SUBSCRIBE).encode()
    )
    check:
      res.isErr()
      res.error == ProtobufError.missingRequiredField("request_id")

  test "a subscribe response without a request id or a status code is refused":
    let noId =
      FilterSubscribeResponse.decode(FilterSubscribeResponse(statusCode: 200).encode())
    let noCode =
      FilterSubscribeResponse.decode(FilterSubscribeResponse(requestId: "r").encode())
    check:
      noId.isErr()
      noId.error == ProtobufError.missingRequiredField("request_id")
      noCode.isErr()
      noCode.error == ProtobufError.missingRequiredField("status_code")

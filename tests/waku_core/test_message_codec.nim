{.used.}

import results, stew/byteutils, testutils/unittests
import logos_delivery/waku/[common/protobuf, waku_core], ../testlib/protobuf_errors

suite "Waku Core - WakuMessage codec":
  test "a message with all fields encodes in field number order":
    let msg = WakuMessage(
      payload: "hi".toBytes(),
      contentTopic: "/a/1/b/c",
      version: 1,
      timestamp: 1234567890,
      meta: @[byte 0xaa, 0xbb],
      proof: @[byte 0xcc],
      ephemeral: true,
    )
    let bytes =
      hexToSeqByte("0a02686912082f612f312f622f63180150a48bb099095a02aabbaa0101ccf80101")
    check:
      msg.encode() == bytes
      WakuMessage.decode(bytes).get() == msg

  test "a message without a content topic is refused":
    # Field 1 (payload) only.
    let res = WakuMessage.decode(hexToSeqByte("0a0101"))
    check:
      res.isErr()
      res.error == ProtobufError.missingRequiredField("content_topic")

  test "a message with an empty payload decodes":
    # Field 2 (content topic) only.
    let res = WakuMessage.decode(hexToSeqByte("12022f74"))
    check:
      res.isOk()
      res.get() == WakuMessage(contentTopic: "/t")

  test "a content topic that is not valid UTF-8 is refused":
    let res = WakuMessage.decode(hexToSeqByte("1202ff74"))
    check:
      res.isErr()
      res.error.kind == ProtobufErrorKind.DecodeFailure

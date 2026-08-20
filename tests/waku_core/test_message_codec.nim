{.used.}

import std/sequtils, testutils/unittests
import logos_delivery/waku/waku_core/message/[message, codec]
import logos_delivery/waku/common/protobuf

const
  Payload = @[byte 0x68, 0x69] # "hi"
  ContentTopic = "/a/1/b/c"

# all-default optionals
const OldDefaultsBytes = @[
  byte 0x0a, 0x02, 0x68, 0x69, 0x12, 0x08, 0x2f, 0x61, 0x2f, 0x31, 0x2f, 0x62, 0x2f,
  0x63, 0x18, 0x00, 0x50, 0x00, 0x5a, 0x00, 0xaa, 0x01, 0x00, 0xf8, 0x01, 0x00,
]

# all fields set
const OldFullBytes = @[
  byte 0x0a, 0x02, 0x68, 0x69, 0x12, 0x08, 0x2f, 0x61, 0x2f, 0x31, 0x2f, 0x62, 0x2f,
  0x63, 0x18, 0x01, 0x50, 0xa4, 0x8b, 0xb0, 0x99, 0x09, 0x5a, 0x02, 0xaa, 0xbb, 0xaa,
  0x01, 0x01, 0xcc, 0xf8, 0x01, 0x01,
]

# a proto3 peer drops defaulted fields; must still decode
const CanonicalDefaultsBytes = @[
  byte 0x0a, 0x02, 0x68, 0x69, 0x12, 0x08, 0x2f, 0x61, 0x2f, 0x31, 0x2f, 0x62, 0x2f,
  0x63,
]

proc defaultsMsg(): WakuMessage =
  WakuMessage(payload: Payload, contentTopic: ContentTopic)

proc fullMsg(): WakuMessage =
  WakuMessage(
    payload: Payload,
    contentTopic: ContentTopic,
    version: 1,
    timestamp: 1234567890,
    meta: @[byte 0xaa, 0xbb],
    proof: @[byte 0xcc],
    ephemeral: true,
  )

suite "Waku Message - codec wire format":
  test "encode all-default optionals":
    check defaultsMsg().encode() == OldDefaultsBytes

  test "encode all fields set":
    check fullMsg().encode() == OldFullBytes

  test "decode all-default-optionals bytes":
    let decoded = WakuMessage.decode(OldDefaultsBytes)
    check decoded.isOk()
    check decoded.get() == defaultsMsg()

  test "decode all-fields bytes":
    let decoded = WakuMessage.decode(OldFullBytes)
    check decoded.isOk()
    check decoded.get() == fullMsg()

  test "decode tolerates omitted defaults":
    let decoded = WakuMessage.decode(CanonicalDefaultsBytes)
    check decoded.isOk()
    check decoded.get() == defaultsMsg()

  test "encode/decode round-trips":
    for msg in [defaultsMsg(), fullMsg()]:
      let decoded = WakuMessage.decode(msg.encode())
      check decoded.isOk()
      check decoded.get() == msg

  test "decode rejects meta field exceeding max length":
    var msg = defaultsMsg()
    msg.meta = toSeq(0.byte .. 66.byte) # 67 bytes > MaxMetaAttrLength (64)
    let decoded = WakuMessage.decode(msg.encode())
    check decoded.isErr()
    check decoded.error.kind == ProtobufErrorKind.InvalidLengthField

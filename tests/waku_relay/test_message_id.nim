import
  unittest,
  results,
  stew/byteutils,
  nimcrypto/sha2,
  libp2p/protocols/pubsub/rpc/messages

import logos_delivery/waku/waku_relay/message_id

suite "Message ID Provider":
  test "Non-empty string":
    let message = Message(data: "Hello, world!".toBytes())
    let result = defaultMessageIdProvider(message)
    let expected = MDigest[256].fromHex(
      "315f5bdb76d078c43b8ac0064e4a0164612b1fce77c869345bfc94c75894edd3"
    )
    check:
      result.isOk()
      result.get() == expected.data

  test "Empty string":
    let message = Message(data: "".toBytes())
    let result = defaultMessageIdProvider(message)
    let expected = MDigest[256].fromHex(
      "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
    )
    check:
      result.isOk()
      result.get() == expected.data

  test "Empty array":
    let message = Message(data: @[])
    let result = defaultMessageIdProvider(message)
    let expected = MDigest[256].fromHex(
      "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
    )
    check:
      result.isOk()
      result.get() == expected.data

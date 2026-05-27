{.used.}

import testutils/unittests
import results, waku/waku_core/message, waku/waku_core/time, ./testlib/common

suite "Waku Payload":
  test "Encode/Decode waku message with timestamp":
    ## Test encoding and decoding of the timestamp field of a WakuMessage

    ## Given
    let
      version = 0'u32
      payload = @[byte 0, 1, 2]
      timestamp = Timestamp(10)
      msg = WakuMessage(payload: payload, version: version, timestamp: timestamp)

    ## When
    let pb = msg.encode()
    let msgDecoded = WakuMessage.decode(pb.buffer)

    ## Then
    check:
      msgDecoded.isOk()

    let timestampDecoded = msgDecoded.value.timestamp
    check:
      timestampDecoded == timestamp

  test "Encode/Decode waku message without timestamp":
    ## Test the encoding and decoding of a WakuMessage with an empty timestamp field

    ## Given
    let
      version = 0'u32
      payload = @[byte 0, 1, 2]
      msg = WakuMessage(payload: payload, version: version)

    ## When
    let pb = msg.encode()
    let msgDecoded = WakuMessage.decode(pb.buffer)

    ## Then
    check:
      msgDecoded.isOk()

    let timestampDecoded = msgDecoded.value.timestamp
    check:
      timestampDecoded == Timestamp(0)

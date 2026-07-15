{.used.}

import std/times, stew/byteutils, testutils/unittests
import logos_delivery/waku/waku_core/message/message

suite "Waku Message - ref semantics":
  test "structural == on equal contents":
    let a = WakuMessage(
      payload: "\x01\x02\x03".toBytes(),
      contentTopic: "/test/1/proto",
      meta: @[byte 9],
      version: 1,
      timestamp: 42,
      ephemeral: true,
      proof: @[byte 7],
    )
    let b = WakuMessage(
      payload: "\x01\x02\x03".toBytes(),
      contentTopic: "/test/1/proto",
      meta: @[byte 9],
      version: 1,
      timestamp: 42,
      ephemeral: true,
      proof: @[byte 7],
    )
    check:
      a == b # equal by content, distinct refs
      not (a == WakuMessage(payload: "\x01\x02\x03".toBytes()))

  test "structural == nil cases":
    let nilA: WakuMessage = nil
    let nilB: WakuMessage = nil
    let nonNil = WakuMessage(payload: @[byte 1])
    check:
      nilA == nilB # both nil -> equal
      not (nilA == nonNil) # one nil -> not equal
      not (nonNil == nilB)

  test "clone is an independent deep copy":
    let orig =
      WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "/a/1", proof: @[byte 8])
    let cp = orig.clone()
    check:
      cp == orig # equal contents
      not cp.isNil()
    # mutating the clone must not touch the original
    cp.payload = @[byte 9]
    cp.proof = @[byte 0]
    check:
      orig.payload == @[byte 1, 2, 3]
      orig.proof == @[byte 8]
      not (cp == orig)

  test "clone(nil) is nil":
    let n: WakuMessage = nil
    check n.clone().isNil()

  test "ensureTimestampSet returns same ref when timestamp already set":
    let msg = WakuMessage(payload: @[byte 1], timestamp: 123)
    let res = msg.ensureTimestampSet()
    check:
      cast[pointer](res) == cast[pointer](msg) # same instance, no clone
      res.timestamp == 123

  test "ensureTimestampSet returns a fresh ref, never mutating the shared input":
    let msg = WakuMessage(payload: @[byte 1], timestamp: 0)
    let res = msg.ensureTimestampSet()
    check:
      cast[pointer](res) != cast[pointer](msg) # distinct instance
      res.timestamp != 0
      msg.timestamp == 0 # input untouched (would be a shared-state bug)
      res.payload == msg.payload

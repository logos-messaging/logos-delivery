{.used.}

import results, testutils/unittests
import
  logos_delivery/waku/waku_filter_v2/rpc,
  logos_delivery/waku/waku_filter_v2/rpc_codec,
  logos_delivery/waku/waku_core

# ping request: requestId "x" (0a 01 78) + filterSubscribeType PING=0 (10 00)
const PingRequest = @[byte 0x0a, 0x01, 0x78, 0x10, 0x00]
# same ping with field 2 omitted, as a proto3 peer sends it
const PingRequestNoType = @[byte 0x0a, 0x01, 0x78]

suite "Waku Filter v2 - codec wire format":
  test "FilterSubscribeRequest emits the enum field even for ord 0 (PING)":
    let req = FilterSubscribeRequest.ping("x")
    check req.encode() == PingRequest

  test "decode of a request omitting field 2 defaults to SUBSCRIBER_PING":
    let decoded = FilterSubscribeRequest.decode(PingRequestNoType)
    check decoded.isOk()
    check decoded.get() == FilterSubscribeRequest.ping("x")

  test "FilterSubscribeRequest round-trips (subscribe with topics)":
    let req = FilterSubscribeRequest.subscribe(
      "req-1", "/waku/2/rs/0/0", @["/a/1/b/c", "/d/2/e/f"]
    )
    let decoded = FilterSubscribeRequest.decode(req.encode())
    check decoded.isOk()
    check decoded.get() == req

  test "FilterSubscribeResponse round-trips":
    let resp = FilterSubscribeResponse.ok("req-2")
    let decoded = FilterSubscribeResponse.decode(resp.encode())
    check decoded.isOk()
    check decoded.get() == resp

  test "MessagePush round-trips with nested WakuMessage":
    let push = MessagePush(
      wakuMessage: WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "/a/1/b/c"),
      pubsubTopic: "/waku/2/rs/0/0",
    )
    let decoded = MessagePush.decode(push.encode())
    check decoded.isOk()
    check decoded.get() == push

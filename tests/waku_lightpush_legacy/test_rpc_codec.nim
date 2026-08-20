{.used.}

import results, testutils/unittests
import
  logos_delivery/waku/waku_lightpush_legacy/rpc,
  logos_delivery/waku/waku_lightpush_legacy/rpc_codec,
  logos_delivery/waku/waku_core

# PushResponse{isSuccess:false}: field 1 emitted even when false
const PushRespFalse = @[byte 0x08, 0x00]
# PushResponse{isSuccess:true}, info omitted
const PushRespTrue = @[byte 0x08, 0x01]
# PushResponse{isSuccess:false, info:"hi"}
const PushRespFalseInfo = @[byte 0x08, 0x00, 0x12, 0x02, 0x68, 0x69]
# PushRPC{requestId:"x"}, request/response omitted
const PushRpcIdOnly = @[byte 0x0a, 0x01, 0x78]

suite "Waku Legacy Lightpush - codec wire format":
  test "PushResponse always emits the required isSuccess field, even when false":
    check PushResponse(isSuccess: false, info: Opt.none(string)).encode() ==
      PushRespFalse

  test "PushResponse success, no info":
    check PushResponse(isSuccess: true, info: Opt.none(string)).encode() == PushRespTrue

  test "PushResponse failure, with info":
    check PushResponse(isSuccess: false, info: Opt.some("hi")).encode() ==
      PushRespFalseInfo

  test "PushRPC omits absent optional request/response":
    check PushRPC(
      requestId: "x", request: Opt.none(PushRequest), response: Opt.none(PushResponse)
    ).encode() == PushRpcIdOnly

  test "PushResponse round-trips":
    for r in [
      PushResponse(isSuccess: false, info: Opt.none(string)),
      PushResponse(isSuccess: true, info: Opt.some("done")),
    ]:
      let decoded = PushResponse.decode(r.encode())
      check decoded.isOk()
      check decoded.get() == r

  test "PushRPC round-trips with nested request and message":
    let rpc = PushRPC(
      requestId: "req-1",
      request: Opt.some(
        PushRequest(
          pubSubTopic: "/waku/2/rs/0/0",
          message: WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "/a/1/b/c"),
        )
      ),
      response: Opt.none(PushResponse),
    )
    let decoded = PushRPC.decode(rpc.encode())
    check decoded.isOk()
    check decoded.get() == rpc

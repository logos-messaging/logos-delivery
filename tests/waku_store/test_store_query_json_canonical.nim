{.used.}

import std/[json, options], results, testutils/unittests
import logos_delivery/waku/waku_core, logos_delivery/waku/waku_store/[
  common, eligibility_canonical, rpc_codec
]
import ../../library/store_eligibility/store_query_json

const N8ReferenceWireHex =
  "2f4c455a2f76302e312f53746f7265456c69676962696c6974792f0000000000050000007265712d3101010d0000002f77616b752f322f746f70696301000000140000002f6d792d6170702f312f636861742f70726f746f010a000000000000000002000000010101010101010101010101010101010101010101010101010101010101010102020202020202020202020202020202020202020202020202020202020202020001016400000000000000"

const E2eQueryJson = """
{
  "requestId": "req-1",
  "includeData": true,
  "pubsubTopic": "/waku/2/topic",
  "contentTopics": ["/my-app/1/chat/proto"],
  "timeStart": 10,
  "paginationForward": true,
  "paginationLimit": 100,
  "messageHashes": [
    "0101010101010101010101010101010101010101010101010101010101010101",
    "0202020202020202020202020202020202020202020202020202020202020202"
  ]
}
"""

const Step17E2eQueryJson = """
{
  "requestId": "req-1",
  "includeData": true,
  "pubsubTopic": "/waku/2/rs/0/1",
  "contentTopics": ["/lez-payment-streams/1/e2e-eligibility/proto"],
  "timeStart": 10,
  "paginationForward": true,
  "paginationLimit": 100,
  "messageHashes": []
}
"""

const Step17N8ReferenceWireHex =
  "2f4c455a2f76302e312f53746f7265456c69676962696c6974792f0000000000050000007265712d3101010e0000002f77616b752f322f72732f302f31010000002c0000002f6c657a2d7061796d656e742d73747265616d732f312f6532652d656c69676962696c6974792f70726f746f010a0000000000000000000000000001016400000000000000"

procSuite "Waku Store - store query JSON (N8)":
  test "E2E query JSON matches n8_canonical_wire_hex reference":
    let parsed = parseJson(E2eQueryJson)
    let reqRes = storeQueryRequestFromJson(parsed)
    check reqRes.isOk()
    let req = reqRes.get()
    check storeEligibilityCanonicalHex(req) == N8ReferenceWireHex

  test "Step 17 E2E query JSON matches lez-payment-streams n8 wire":
    let parsed = parseJson(Step17E2eQueryJson)
    let reqRes = storeQueryRequestFromJson(parsed)
    check reqRes.isOk()
    let req = reqRes.get()
    check storeEligibilityCanonicalHex(req) == Step17N8ReferenceWireHex

  test "Step 17 E2E query JSON protobuf roundtrip matches n8 wire":
    let parsed = parseJson(Step17E2eQueryJson)
    let reqRes = storeQueryRequestFromJson(parsed)
    check reqRes.isOk()
    var req = reqRes.get()
    req.eligibilityProof = some(@[byte(0xAB)])
    let buf = req.encode().buffer
    let decoded = StoreQueryRequest.decode(buf).get()
    check storeEligibilityCanonicalHex(decoded) == Step17N8ReferenceWireHex

  test "E2E query JSON protobuf roundtrip matches N8 reference":
    let parsed = parseJson(E2eQueryJson)
    let reqRes = storeQueryRequestFromJson(parsed)
    check reqRes.isOk()
    var req = reqRes.get()
    req.eligibilityProof = some(@[byte(0xAB), byte(0xCD)])
    let buf = req.encode().buffer
    let decoded = StoreQueryRequest.decode(buf).get()
    check storeEligibilityCanonicalHex(decoded) == N8ReferenceWireHex
    check decoded.eligibilityProof.isSome()
    check decoded.eligibilityProof.get() == @[byte(0xAB), byte(0xCD)]

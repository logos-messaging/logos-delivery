{.used.}

import std/options, testutils/unittests
import logos_delivery/waku/[common/paging, waku_core, waku_store/common, waku_store/eligibility_canonical]

const N8ReferenceWireHex =
  "2f4c455a2f76302e312f53746f7265456c69676962696c6974792f0000000000050000007265712d3101010e0000002f77616b752f322f72732f302f31010000002c0000002f6c657a2d7061796d656e742d73747265616d732f312f6532652d656c69676962696c6974792f70726f746f010a0000000000000000000000000001016400000000000000"

procSuite "Waku Store - eligibility canonical (N8)":
  test "matches lez-payment-streams-core n8_canonical_wire_hex reference":
    let query = StoreQueryRequest(
      requestId: "req-1",
      includeData: true,
      pubsubTopic: some("/waku/2/rs/0/1"),
      contentTopics: @["/lez-payment-streams/1/e2e-eligibility/proto"],
      startTime: some(Timestamp(10)),
      endTime: none(Timestamp),
      messageHashes: @[],
      paginationCursor: none(WakuMessageHash),
      paginationForward: PagingDirection.FORWARD,
      paginationLimit: some(uint64(100)),
    )

    check storeEligibilityCanonicalHex(query) == N8ReferenceWireHex

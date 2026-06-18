{.used.}

import std/options, testutils/unittests
import logos_delivery/waku/[common/paging, waku_core, waku_store/common, waku_store/eligibility_canonical]

const N8ReferenceWireHex =
  "2f4c455a2f76302e312f53746f7265456c69676962696c6974792f0000000000050000007265712d3101010d0000002f77616b752f322f746f70696301000000140000002f6d792d6170702f312f636861742f70726f746f010a000000000000000002000000010101010101010101010101010101010101010101010101010101010101010102020202020202020202020202020202020202020202020202020202020202020001016400000000000000"

procSuite "Waku Store - eligibility canonical (N8)":
  test "matches lez-payment-streams-core n8_canonical_wire_hex reference":
    let hash1 = block:
      var h: WakuMessageHash
      for i in 0 .. 31:
        h[i] = byte(1)
      h
    let hash2 = block:
      var h: WakuMessageHash
      for i in 0 .. 31:
        h[i] = byte(2)
      h

    let query = StoreQueryRequest(
      requestId: "req-1",
      includeData: true,
      pubsubTopic: some("/waku/2/topic"),
      contentTopics: @["/my-app/1/chat/proto"],
      startTime: some(Timestamp(10)),
      endTime: none(Timestamp),
      messageHashes: @[hash1, hash2],
      paginationCursor: none(WakuMessageHash),
      paginationForward: PagingDirection.FORWARD,
      paginationLimit: some(uint64(100)),
    )

    check storeEligibilityCanonicalHex(query) == N8ReferenceWireHex

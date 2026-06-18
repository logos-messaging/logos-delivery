{.used.}

import std/options, testutils/unittests, chronos, libp2p/crypto/crypto
import
  logos_delivery/waku/[common/paging, node/peer_manager, waku_core, waku_store, waku_store/common],
  logos_delivery/waku/waku_store/[eligibility_hooks, self_req_handler],
  ../testlib/[wakucore, testasync, futures],
  ./store_utils

procSuite "Store eligibility verifier wrapper":
  var serverSwitch {.threadvar.}: Switch
  var server {.threadvar.}: WakuStore
  var innerCalled {.threadvar.}: int
  var verifierCalled {.threadvar.}: int
  var lastProofHex {.threadvar.}: string
  var innerHandler {.threadvar.}: StoreQueryRequestHandler

  asyncSetup:
    innerCalled = 0
    verifierCalled = 0
    lastProofHex = ""

    innerHandler = proc(
        req: StoreQueryRequest
    ): Future[StoreQueryResult] {.async, gcsafe.} =
      innerCalled.inc()
      return ok(StoreQueryResponse(requestId: req.requestId, statusCode: 200))

    serverSwitch = newTestSwitch()
    server = await newTestWakuStore(
      serverSwitch,
      handler = innerHandler,
    )
    await serverSwitch.start()
    await sleepAsync(100.millis)

  asyncTeardown:
    await serverSwitch.stop()

  asyncTest "verifier reject skips inner handler":
    let verifierCb = proc (
        proof_hex, canonical_hex, requester_peer_id: cstring,
        out_desc: cstring, out_desc_len: csize_t, user_data: pointer
    ): cint {.cdecl, gcsafe, raises: [].} =
      verifierCalled.inc()
      if not isNil(proof_hex):
        lastProofHex = $proof_hex
      cint(ord(EligibilityStatusCode.PROOF_INVALID))

    server.requestHandler = makeEligibilityWrappedHandler(
      verifierCb, nil, innerHandler, server
    )
    server.inboundRequestPeerId = some(serverSwitch.peerInfo.peerId)

    let req = StoreQueryRequest(
      requestId: "r1",
      paginationForward: PagingDirection.FORWARD,
      eligibilityProof: some(@[byte(0xAB)]),
    )
    let res = (await server.handleSelfStoreRequest(req)).get()

    check:
      verifierCalled == 1
      innerCalled == 0
      res.statusCode == uint32(StatusCode.BAD_REQUEST)
      res.eligibilityStatus.isSome()
      res.eligibilityStatus.get().code == EligibilityStatusCode.PROOF_INVALID
      lastProofHex.len > 0

  asyncTest "verifier OK delegates to inner handler":
    innerCalled = 0
    verifierCalled = 0
    let verifierCb = proc (
        proof_hex, canonical_hex, requester_peer_id: cstring,
        out_desc: cstring, out_desc_len: csize_t, user_data: pointer
    ): cint {.cdecl, gcsafe, raises: [].} =
      verifierCalled.inc()
      cint(ord(EligibilityStatusCode.OK))

    server.requestHandler = makeEligibilityWrappedHandler(
      verifierCb, nil, innerHandler, server
    )

    let req = StoreQueryRequest(
      requestId: "r2", paginationForward: PagingDirection.FORWARD
    )
    discard (await server.handleSelfStoreRequest(req)).get()

    check:
      verifierCalled == 1
      innerCalled == 1

  asyncTest "NULL proof passes NULL proof_hex to verifier":
    innerCalled = 0
    verifierCalled = 0
    lastProofHex = "unset"
    let verifierCb = proc (
        proof_hex, canonical_hex, requester_peer_id: cstring,
        out_desc: cstring, out_desc_len: csize_t, user_data: pointer
    ): cint {.cdecl, gcsafe, raises: [].} =
      verifierCalled.inc()
      if isNil(proof_hex):
        lastProofHex = ""
      else:
        lastProofHex = $proof_hex
      cint(ord(EligibilityStatusCode.OK))

    server.requestHandler = makeEligibilityWrappedHandler(
      verifierCb, nil, innerHandler, server
    )

    let req = StoreQueryRequest(
      requestId: "r3", paginationForward: PagingDirection.FORWARD
    )
    discard (await server.handleSelfStoreRequest(req)).get()

    check:
      verifierCalled == 1
      lastProofHex == ""

{.used.}

import std/options, testutils/unittests, chronos, libp2p/crypto/crypto

import
  logos_delivery/waku/[
    common/paging,
    node/peer_manager,
    waku_core,
    waku_core/message/digest,
    waku_store,
    waku_store/client,
    waku_store/common,
  ],
  ../testlib/wakucore,
  ./store_utils

suite "Waku Store - query handler":
  asyncTest "history query handler should be called":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    let msg = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let hash = computeMessageHash(DefaultPubsubTopic, msg)
    let kv = WakuMessageKeyValue(
      messageHash: hash, message: some(msg), pubsubTopic: some(DefaultPubsubTopic)
    )

    var queryHandlerFut = newFuture[(StoreQueryRequest)]()

    let queryHandler = proc(
        req: StoreQueryRequest
    ): Future[StoreQueryResult] {.async, gcsafe.} =
      var request = req
      request.requestId = "" # Must remove the id for equality
      queryHandlerFut.complete(request)
      return ok(StoreQueryResponse(messages: @[kv]))

    let
      server = await newTestWakuStore(serverSwitch, handler = queryhandler)
      client = newTestWakuStoreClient(clientSwitch)

    let req = StoreQueryRequest(
      contentTopics: @[DefaultContentTopic], paginationForward: PagingDirection.FORWARD
    )

    ## When
    let queryRes = await client.query(req, peer = serverPeerInfo)

    ## Then
    check:
      not queryHandlerFut.failed()
      queryRes.isOk()

    let request = queryHandlerFut.read()
    check:
      request == req

    let response = queryRes.tryGet()
    check:
      response.messages.len == 1
      response.messages == @[kv]

    ## Cleanup
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "history query handler should be called and return an error":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    var queryHandlerFut = newFuture[(StoreQueryRequest)]()
    let queryHandler = proc(
        req: StoreQueryRequest
    ): Future[StoreQueryResult] {.async, gcsafe.} =
      var request = req
      request.requestId = "" # Must remove the id for equality
      queryHandlerFut.complete(request)
      return err(StoreError(kind: ErrorCode.BAD_REQUEST))

    let
      server = await newTestWakuStore(serverSwitch, handler = queryhandler)
      client = newTestWakuStoreClient(clientSwitch)

    let req = StoreQueryRequest(
      contentTopics: @[DefaultContentTopic], paginationForward: PagingDirection.FORWARD
    )

    ## When
    let queryRes = await client.query(req, peer = serverPeerInfo)

    ## Then
    check:
      not queryHandlerFut.failed()
      queryRes.isErr()

    let request = queryHandlerFut.read()
    check:
      request == req

    let error = queryRes.tryError()
    check:
      error.kind == ErrorCode.BAD_REQUEST

    ## Cleanup
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

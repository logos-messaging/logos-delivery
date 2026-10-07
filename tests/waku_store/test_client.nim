{.used.}

import results, std/[sets, sequtils], testutils/unittests, chronos, libp2p/crypto/crypto

import
  logos_delivery/waku/[
    node/peer_manager,
    waku_core,
    waku_store,
    waku_store/client,
    waku_store/rpc_codec,
    common/paging,
  ],
  ../testlib/[wakucore, testasync, futures],
  ./store_utils

suite "Store Client":
  var message1 {.threadvar.}: WakuMessage
  var message2 {.threadvar.}: WakuMessage
  var message3 {.threadvar.}: WakuMessage
  var hash1 {.threadvar.}: WakuMessageHash
  var hash2 {.threadvar.}: WakuMessageHash
  var hash3 {.threadvar.}: WakuMessageHash
  var messageSeq {.threadvar.}: seq[WakuMessageKeyValue]
  var handlerFuture {.threadvar.}: Future[StoreQueryRequest]
  var handler {.threadvar.}: StoreQueryRequestHandler
  var storeQuery {.threadvar.}: StoreQueryRequest

  var serverSwitch {.threadvar.}: Switch
  var clientSwitch {.threadvar.}: Switch

  var server {.threadvar.}: WakuStore
  var client {.threadvar.}: WakuStoreClient

  var serverPeerInfo {.threadvar.}: RemotePeerInfo
  var clientPeerInfo {.threadvar.}: RemotePeerInfo

  asyncSetup:
    message1 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    message2 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    message3 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    hash1 = computeMessageHash(DefaultPubsubTopic, message1)
    hash2 = computeMessageHash(DefaultPubsubTopic, message2)
    hash3 = computeMessageHash(DefaultPubsubTopic, message3)
    messageSeq = @[
      WakuMessageKeyValue(
        messageHash: hash1,
        message: Opt.some(message1),
        pubsubTopic: Opt.some(DefaultPubsubTopic),
      ),
      WakuMessageKeyValue(
        messageHash: hash2,
        message: Opt.some(message2),
        pubsubTopic: Opt.some(DefaultPubsubTopic),
      ),
      WakuMessageKeyValue(
        messageHash: hash3,
        message: Opt.some(message3),
        pubsubTopic: Opt.some(DefaultPubsubTopic),
      ),
    ]
    handlerFuture = newHistoryFuture()
    handler = proc(req: StoreQueryRequest): Future[StoreQueryResult] {.async, gcsafe.} =
      var request = req
      request.requestId = ""
      handlerFuture.complete(request)
      return ok(StoreQueryResponse(messages: messageSeq))
    storeQuery = StoreQueryRequest(
      pubsubTopic: Opt.some(DefaultPubsubTopic),
      contentTopics: @[DefaultContentTopic],
      paginationForward: PagingDirection.FORWARD,
    )

    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()

    server = await newTestWakuStore(serverSwitch, handler = handler)
    client = newTestWakuStoreClient(clientSwitch)

    await allFutures(serverSwitch.start(), clientSwitch.start())

    serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    clientPeerInfo = clientSwitch.peerInfo.toRemotePeerInfo()

  asyncTeardown:
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  suite "StoreQueryRequest Creation and Execution":
    asyncTest "Valid Queries":
      # When a valid query is sent to the server
      let queryResponse = await client.query(storeQuery, peer = serverPeerInfo)

      # Then the query is processed successfully
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      check:
        handlerFuture.read() == storeQuery
        queryResponse.get().messages == messageSeq

    asyncTest "Invalid Queries":
      # TODO: IMPROVE: We can't test "actual" invalid queries because 
      # it directly depends on the handler implementation, to achieve
      # proper coverage we'd need an example implementation.

      # Given some invalid queries
      let
        invalidQuery1 = StoreQueryRequest(
          pubsubTopic: Opt.some(DefaultPubsubTopic),
          contentTopics: @[],
          paginationForward: PagingDirection.FORWARD,
        )
        invalidQuery2 = StoreQueryRequest(
          pubsubTopic: Opt.none(PubsubTopic),
          contentTopics: @[DefaultContentTopic],
          paginationForward: PagingDirection.FORWARD,
        )
        invalidQuery3 = StoreQueryRequest(
          pubsubTopic: Opt.some(DefaultPubsubTopic),
          contentTopics: @[DefaultContentTopic],
          paginationLimit: Opt.some(uint64(0)),
        )
        invalidQuery4 = StoreQueryRequest(
          pubsubTopic: Opt.some(DefaultPubsubTopic),
          contentTopics: @[DefaultContentTopic],
          paginationLimit: Opt.some(uint64(0)),
        )
        invalidQuery5 = StoreQueryRequest(
          pubsubTopic: Opt.some(DefaultPubsubTopic),
          contentTopics: @[DefaultContentTopic],
          startTime: Opt.some(0.Timestamp),
          endTime: Opt.some(0.Timestamp),
        )
        invalidQuery6 = StoreQueryRequest(
          pubsubTopic: Opt.some(DefaultPubsubTopic),
          contentTopics: @[DefaultContentTopic],
          startTime: Opt.some(0.Timestamp),
          endTime: Opt.some(-1.Timestamp),
        )

      # When the query is sent to the server
      let queryResponse1 = await client.query(invalidQuery1, peer = serverPeerInfo)

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      check:
        handlerFuture.read() == invalidQuery1
        queryResponse1.get().messages == messageSeq

      # When the query is sent to the server
      handlerFuture = newHistoryFuture()
      let queryResponse2 = await client.query(invalidQuery2, peer = serverPeerInfo)

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      check:
        handlerFuture.read() == invalidQuery2
        queryResponse2.get().messages == messageSeq

      # When the query is sent to the server
      handlerFuture = newHistoryFuture()
      let queryResponse3 = await client.query(invalidQuery3, peer = serverPeerInfo)

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      check:
        handlerFuture.read() == invalidQuery3
        queryResponse3.get().messages == messageSeq

      # When the query is sent to the server
      handlerFuture = newHistoryFuture()
      let queryResponse4 = await client.query(invalidQuery4, peer = serverPeerInfo)

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      check:
        handlerFuture.read() == invalidQuery4
        queryResponse4.get().messages == messageSeq

      # When the query is sent to the server
      handlerFuture = newHistoryFuture()
      let queryResponse5 = await client.query(invalidQuery5, peer = serverPeerInfo)

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      check:
        handlerFuture.read() == invalidQuery5
        queryResponse5.get().messages == messageSeq

      # When the query is sent to the server
      handlerFuture = newHistoryFuture()
      let queryResponse6 = await client.query(invalidQuery6, peer = serverPeerInfo)

      # Then the query is not processed
      assert await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      check:
        handlerFuture.read() == invalidQuery6
        queryResponse6.get().messages == messageSeq

  suite "Verification of StoreQueryResponse Payload":
    asyncTest "Positive Responses":
      # When a valid query is sent to the server
      let queryResponse = await client.query(storeQuery, peer = serverPeerInfo)

      # Then the query is processed successfully, and is of the expected type
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        type(queryResponse.get()) is StoreQueryResponse

    asyncTest "Negative Responses - PeerDialFailure":
      # Given a stopped peer
      let
        otherServerSwitch = newTestSwitch()
        otherServerPeerInfo = otherServerSwitch.peerInfo.toRemotePeerInfo()

      # When a query is sent to the stopped peer
      let queryResponse = await client.query(storeQuery, peer = otherServerPeerInfo)

      # Then the query is not processed
      check:
        not await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        queryResponse.isErr()
        queryResponse.error.kind == ErrorCode.PEER_DIAL_FAILURE

    asyncTest "queryToAny shuffles peers across calls":
      # Register several fake store peers (no servers running) so every dial
      # fails. PEER_DIAL_FAILURE carries the peerId of the last peer tried in
      # the shuffled order, so observing different "last" peerIds across calls
      # confirms shuffle is active inside queryToAny.
      for _ in 0 ..< 3:
        let fakeSwitch = newTestSwitch()
        let peerInfo = fakeSwitch.peerInfo.toRemotePeerInfo()
        peerInfo.protocols = @[WakuStoreCodec]
        clientSwitch.peerStore.addPeer(peerInfo)

      var observedLastPeers: HashSet[string]
      for _ in 0 ..< 20:
        let res = await client.queryToAny(storeQuery)
        check:
          res.isErr()
          res.error.kind == ErrorCode.PEER_DIAL_FAILURE
        observedLastPeers.incl(res.error.address)

      check observedLastPeers.len >= 2

suite "Store Client - peers that hold their streams":
  ## Two Store peers read the request and keep their streams open until teardown.
  var serverSwitches {.threadvar.}: seq[Switch]
  var clientSwitch {.threadvar.}: Switch
  var client {.threadvar.}: WakuStoreClient
  var answer {.threadvar.}: bool
  var requests {.threadvar.}: int
  var requestSeen {.threadvar.}: AsyncEvent
  var release {.threadvar.}: AsyncEvent

  asyncSetup:
    answer = true
    requests = 0
    requestSeen = newAsyncEvent()
    release = newAsyncEvent()
    proc hold(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
      try:
        let buf = await conn.readLp(DefaultMaxRpcSize.int)
        inc requests
        if answer:
          let req = StoreQueryRequest.decode(buf).valueOr:
            return
          let resp = StoreQueryResponse(
            requestId: req.requestId, statusCode: uint32(StatusCode.SUCCESS)
          )
          await conn.writeLp(resp.encode())
      except LPStreamError:
        return
      requestSeen.fire()
      await release.wait()
      await conn.close()

    serverSwitches = @[newTestSwitch(), newTestSwitch()]
    for serverSwitch in serverSwitches:
      serverSwitch.mount(LPProtocol.new(codecs = @[WakuStoreCodec], handler = hold))
    clientSwitch = newTestSwitch()
    client = newTestWakuStoreClient(clientSwitch)
    await allFutures(serverSwitches.mapIt(it.start()) & @[clientSwitch.start()])
    for serverSwitch in serverSwitches:
      let peerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
      peerInfo.protocols = @[WakuStoreCodec]
      clientSwitch.peerStore.addPeer(peerInfo)

  asyncTeardown:
    release.fire()
    await allFutures(serverSwitches.mapIt(it.stop()) & @[clientSwitch.stop()])

  asyncTest "the query returns with the answer, without waiting for the EOF":
    let query = client.queryToAny(StoreQueryRequest(includeData: false))
    check await requestSeen.wait().withTimeout(chronos.seconds(5))

    # Apply the timeout to join() so it cannot cancel the query under test.
    check:
      await query.join().withTimeout(chronos.seconds(3))
      query.completed()
      query.read().isOk()

  asyncTest "a cancelled query ends cancelled, without asking another Store peer":
    answer = false
    let query = client.queryToAny(StoreQueryRequest(includeData: false))
    check await requestSeen.wait().withTimeout(chronos.seconds(5))

    query.cancelSoon()
    check:
      await query.join().withTimeout(chronos.seconds(3))
      query.cancelled()
      requests == 1

{.used.}

import results, testutils/unittests, chronos, libp2p/crypto/crypto

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
      messageHash: hash,
      message: Opt.some(msg),
      pubsubTopic: Opt.some(DefaultPubsubTopic),
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

  asyncTest "history query with a time range longer than 24h is rejected":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    var handlerCalls = 0
    let queryHandler = proc(
        req: StoreQueryRequest
    ): Future[StoreQueryResult] {.async, gcsafe.} =
      handlerCalls.inc()
      return ok(StoreQueryResponse())

    let
      server = await newTestWakuStore(serverSwitch, handler = queryhandler)
      client = newTestWakuStoreClient(clientSwitch)

    let endTime = now()
    var req = StoreQueryRequest(
      contentTopics: @[DefaultContentTopic],
      startTime: Opt.some(endTime - MaxQueryTimeRange - 1),
      endTime: Opt.some(endTime),
    )

    ## When
    let tooLongRes = await client.query(req, peer = serverPeerInfo)

    req.startTime = Opt.some(endTime - MaxQueryTimeRange)
    let oneDayRes = await client.query(req, peer = serverPeerInfo)

    ## Then
    check:
      tooLongRes.isErr()
      tooLongRes.tryError().kind == ErrorCode.BAD_REQUEST
      oneDayRes.isOk()
      handlerCalls == 1

    ## Cleanup
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  test "history query from -1 to the last timestamp is rejected":
    let req = StoreQueryRequest(
      startTime: Opt.some(Timestamp(-1)), endTime: Opt.some(Timestamp.high)
    )
    check req.validate().isErr()

  asyncTest "history query mixing message hashes and content filters is rejected":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    var handlerCalls = 0
    let queryHandler = proc(
        req: StoreQueryRequest
    ): Future[StoreQueryResult] {.async, gcsafe.} =
      handlerCalls.inc()
      return ok(StoreQueryResponse())

    let
      server = await newTestWakuStore(serverSwitch, handler = queryhandler)
      client = newTestWakuStoreClient(clientSwitch)

    let hash = computeMessageHash(DefaultPubsubTopic, fakeWakuMessage())

    ## When
    let withTopicsRes = await client.query(
      StoreQueryRequest(
        pubsubTopic: Opt.some(DefaultPubsubTopic),
        contentTopics: @[DefaultContentTopic],
        messageHashes: @[hash],
      ),
      peer = serverPeerInfo,
    )
    let withTimeRes = await client.query(
      StoreQueryRequest(startTime: Opt.some(now()), messageHashes: @[hash]),
      peer = serverPeerInfo,
    )
    let hashesOnlyRes = await client.query(
      StoreQueryRequest(messageHashes: @[hash]), peer = serverPeerInfo
    )

    ## Then
    check:
      withTopicsRes.isErr()
      withTopicsRes.tryError().kind == ErrorCode.BAD_REQUEST
      withTimeRes.isErr()
      withTimeRes.tryError().kind == ErrorCode.BAD_REQUEST
      hashesOnlyRes.isOk()
      handlerCalls == 1

    ## Cleanup
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

suite "Waku Store - read limits":
  asyncTest "a query above the size limit gets no answer, and the next query does":
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    await allFutures(serverSwitch.start(), clientSwitch.start())

    let queryHandler = proc(
        req: StoreQueryRequest
    ): Future[StoreQueryResult] {.async, gcsafe.} =
      return ok(StoreQueryResponse(statusCode: 200))
    let
      server = await newTestWakuStore(serverSwitch, handler = queryHandler)
      client = newTestWakuStoreClient(clientSwitch)
      serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    # A length prefix of 2^40 bytes, and no data. The server closes the stream.
    let conn = await clientSwitch.dial(
      serverPeerInfo.peerId, serverPeerInfo.addrs, WakuStoreCodec
    )
    await conn.write(@[0x80'u8, 0x80, 0x80, 0x80, 0x80, 0x20])
    let reply = catch:
      await conn.readLp(1024)
    await conn.close()

    let res = await client.query(
      StoreQueryRequest(contentTopics: @[DefaultContentTopic]), peer = serverPeerInfo
    )
    check:
      reply.isErr()
      res.isOk()

    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "a query with many message hashes gets an answer":
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    await allFutures(serverSwitch.start(), clientSwitch.start())

    var hashCount = 0
    let queryHandler = proc(
        req: StoreQueryRequest
    ): Future[StoreQueryResult] {.async, gcsafe.} =
      hashCount = req.messageHashes.len
      return ok(StoreQueryResponse(statusCode: 200))
    let
      server = await newTestWakuStore(serverSwitch, handler = queryHandler)
      client = newTestWakuStoreClient(clientSwitch)
      serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    # 50 000 hashes take about 1.7 MB.
    var hashes = newSeqOfCap[WakuMessageHash](50_000)
    for i in 0 ..< 50_000:
      var hash: WakuMessageHash
      hash[0] = byte(i and 0xff)
      hash[1] = byte((i shr 8) and 0xff)
      hash[2] = byte(i shr 16)
      hashes.add(hash)

    let res = await client.query(
      StoreQueryRequest(messageHashes: hashes), peer = serverPeerInfo
    )
    check:
      res.isOk()
      hashCount == 50_000

    await allFutures(serverSwitch.stop(), clientSwitch.stop())

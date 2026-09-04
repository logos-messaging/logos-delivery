{.used.}

import results, testutils/unittests, chronos, libp2p/crypto/crypto

import
  logos_delivery/waku/[
    node/peer_manager,
    net/bridged_backend,
    waku_core,
    waku_filter_v2,
    waku_filter_v2/client,
    waku_filter_v2/rpc,
    waku_filter_v2/rpc_codec,
    waku_store,
    waku_store/client,
    waku_store/rpc_codec,
    common/paging,
  ],
  ../testlib/[common, wakucore, testasync],
  ../waku_store/store_utils,
  ./switch_transport

suite "Bridged net backend":
  var serverSwitch {.threadvar.}: Switch
  var clientSwitch {.threadvar.}: Switch
  var client {.threadvar.}: WakuStoreClient
  var handlerFuture {.threadvar.}: Future[StoreQueryRequest]
  var serverPeerInfo {.threadvar.}: RemotePeerInfo
  var messageSeq {.threadvar.}: seq[WakuMessageKeyValue]

  asyncSetup:
    let message = fakeWakuMessage(contentTopic = DefaultContentTopic)
    messageSeq = @[
      WakuMessageKeyValue(
        messageHash: computeMessageHash(DefaultPubsubTopic, message),
        message: Opt.some(message),
        pubsubTopic: Opt.some(DefaultPubsubTopic),
      )
    ]

    handlerFuture = newFuture[StoreQueryRequest]()
    let handler = proc(
        req: StoreQueryRequest
    ): Future[StoreQueryResult] {.async, gcsafe.} =
      var request = req
      request.requestId = ""
      handlerFuture.complete(request)
      return ok(StoreQueryResponse(messages: messageSeq))

    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()

    discard await newTestWakuStore(serverSwitch, handler = handler)

    let peerManager = PeerManager.new(
      clientSwitch,
      netBackend = BridgedNetBackend.new(SwitchTransport.new(clientSwitch)),
    )
    client = WakuStoreClient.new(peerManager, common.rng())

    await allFutures(serverSwitch.start(), clientSwitch.start())
    await sleepAsync(500.millis)

    serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

  asyncTeardown:
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "a store query crosses the bridge":
    let storeQuery = StoreQueryRequest(
      pubsubTopic: Opt.some(DefaultPubsubTopic),
      contentTopics: @[DefaultContentTopic],
      paginationForward: PagingDirection.FORWARD,
    )

    let queryResponse = await client.query(storeQuery, peer = serverPeerInfo)

    assert await handlerFuture.withTimeout(chronos.seconds(5))
    check:
      handlerFuture.read().contentTopics == @[DefaultContentTopic]
      queryResponse.get().messages == messageSeq

  asyncTest "a query to an unreachable peer fails to dial":
    let unreachable = RemotePeerInfo.init(
      PeerId.init(generateEcdsaKey().getPublicKey().get()).get(),
      @[MultiAddress.init("/ip4/127.0.0.1/tcp/1").get()],
    )

    let queryResponse = await client.query(
      StoreQueryRequest(contentTopics: @[DefaultContentTopic]), peer = unreachable
    )

    check:
      queryResponse.isErr()
      queryResponse.error.kind == ErrorCode.PEER_DIAL_FAILURE

suite "Bridged connection":
  var serverSwitch {.threadvar.}: Switch
  var clientSwitch {.threadvar.}: Switch
  var backend {.threadvar.}: BridgedNetBackend

  asyncSetup:
    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()
    backend = BridgedNetBackend.new(SwitchTransport.new(clientSwitch))

    let handler = proc(
        req: StoreQueryRequest
    ): Future[StoreQueryResult] {.async, gcsafe.} =
      return ok(StoreQueryResponse(statusCode: uint32(StatusCode.SUCCESS)))

    discard await newTestWakuStore(serverSwitch, handler = handler)

    await allFutures(serverSwitch.start(), clientSwitch.start())
    await sleepAsync(500.millis)

  asyncTeardown:
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "frames cross a dialled stream":
    let peer = serverSwitch.peerInfo.toRemotePeerInfo()

    let conn = (
      await backend.dial(peer.peerId, peer.addrs, WakuStoreCodec, chronos.seconds(5))
    ).valueOr:
      raiseAssert "dial over the bridge failed"

    await conn.writeLP(StoreQueryRequest(requestId: "1").encode().buffer)
    let response = StoreQueryResponse.decode(await conn.readLp(DefaultMaxRpcSize.int))

    await conn.close()

    check:
      response.isOk()
      response.get().statusCode == uint32(StatusCode.SUCCESS)

  asyncTest "a raw write is refused":
    let peer = serverSwitch.peerInfo.toRemotePeerInfo()

    let conn = (
      await backend.dial(peer.peerId, peer.addrs, WakuStoreCodec, chronos.seconds(5))
    ).valueOr:
      raiseAssert "dial over the bridge failed"

    var refused = false
    try:
      await conn.write(@[1'u8, 2, 3])
    except LPStreamError:
      refused = true

    await conn.close()

    check refused

suite "Bridged inbound streams":
  var serverSwitch {.threadvar.}: Switch
  var clientSwitch {.threadvar.}: Switch
  var backend {.threadvar.}: BridgedNetBackend
  var pushed {.threadvar.}: Future[WakuMessage]

  asyncSetup:
    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()
    backend = BridgedNetBackend.new(SwitchTransport.new(clientSwitch))

    let peerManager = PeerManager.new(clientSwitch, netBackend = backend)
    let filterClient = WakuFilterClient.new(peerManager, common.rng())

    pushed = newFuture[WakuMessage]()
    filterClient.registerPushHandler(
      proc(pubsubTopic: PubsubTopic, message: WakuMessage) {.async, gcsafe.} =
        if not pushed.finished():
          pushed.complete(message)
    )

    backend.mountInbound(WakuFilterPushCodec, filterClient.handler)
    await backend.start()

    await allFutures(serverSwitch.start(), clientSwitch.start())
    await sleepAsync(500.millis)

  asyncTeardown:
    await backend.stop()
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "a push reaches the filter client":
    let message = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let push = MessagePush(pubsubTopic: DefaultPubsubTopic, wakuMessage: message)

    let conn = await serverSwitch.dial(
      clientSwitch.peerInfo.peerId, clientSwitch.peerInfo.addrs, WakuFilterPushCodec
    )
    await conn.writeLP(push.encode().buffer)

    check await pushed.withTimeout(chronos.seconds(5))
    check pushed.read() == message

    await conn.close()

{.used.}

import
  results,
  std/sequtils,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub
import
  logos_delivery/waku/[
    common/paging,
    waku_core,
    waku_core/message/digest,
    node/peer_manager,
    waku_archive,
    waku_filter_v2,
    waku_filter_v2/client,
    waku_store,
    waku_node,
  ],
  ../waku_store/store_utils,
  ../waku_archive/archive_utils,
  ../testlib/testasync,
  ../testlib/wakucore,
  ../testlib/wakunode

procSuite "WakuNode - Store":
  ## Fixtures
  let timeOrigin = now()
  let msgListA = @[
    fakeWakuMessage(@[byte 00], ts = ts(00, timeOrigin)),
    fakeWakuMessage(@[byte 01], ts = ts(10, timeOrigin)),
    fakeWakuMessage(@[byte 02], ts = ts(20, timeOrigin)),
    fakeWakuMessage(@[byte 03], ts = ts(30, timeOrigin)),
    fakeWakuMessage(@[byte 04], ts = ts(40, timeOrigin)),
    fakeWakuMessage(@[byte 05], ts = ts(50, timeOrigin)),
    fakeWakuMessage(@[byte 06], ts = ts(60, timeOrigin)),
    fakeWakuMessage(@[byte 07], ts = ts(70, timeOrigin)),
    fakeWakuMessage(@[byte 08], ts = ts(80, timeOrigin)),
    fakeWakuMessage(@[byte 09], ts = ts(90, timeOrigin)),
  ]

  let hashes = msgListA.mapIt(computeMessageHash(DefaultPubsubTopic, it))

  let kvs = zip(hashes, msgListA).mapIt(
      WakuMessageKeyValue(
        messageHash: it[0],
        message: Opt.some(it[1]),
        pubsubTopic: Opt.some(DefaultPubsubTopic),
      )
    )

  let archiveA = block:
    let driver = newSqliteArchiveDriver()

    for kv in kvs:
      let message = kv.message.get()
      require (waitFor driver.put(kv.messageHash, DefaultPubsubTopic, message)).isOk()

    driver

  test "Store protocol returns expected messages":
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey)
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey)

    waitFor allFutures(client.start(), server.start())

    let mountArchiveRes = server.mountArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountStore()

    client.mountStoreClient()

    ## Given
    let req =
      StoreQueryRequest(includeData: true, contentTopics: @[DefaultContentTopic])
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    let queryRes = waitFor client.query(req, peer = serverPeer)

    ## Then
    check queryRes.isOk()

    let response = queryRes.get()
    check:
      response.messages == kvs

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())

  test "Store node history response - forward pagination":
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey)
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey)

    waitFor allFutures(client.start(), server.start())

    let mountArchiveRes = server.mountArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountStore()

    client.mountStoreClient()

    ## Given
    let req = StoreQueryRequest(
      includeData: true,
      contentTopics: @[DefaultContentTopic],
      paginationForward: PagingDirection.FORWARD,
      paginationLimit: Opt.some(uint64(7)),
    )
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    var nextReq = req # copy

    var pages = newSeq[seq[WakuMessageKeyValue]](2)
    var cursors = newSeq[Opt[WakuMessageHash]](2)

    for i in 0 ..< 2:
      let res = waitFor client.query(nextReq, peer = serverPeer)
      require res.isOk()

      # Keep query response content
      let response = res.get()
      pages[i] = response.messages
      cursors[i] = response.paginationCursor

      # Set/update the request cursor
      nextReq.paginationCursor = cursors[i]

    ## Then
    check:
      cursors[0] == Opt.some(kvs[6].messageHash)
      cursors[1] == Opt.none(WakuMessageHash)

    check:
      pages[0] == kvs[0 .. 6]
      pages[1] == kvs[7 .. 9]

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())

  test "Store node history response - backward pagination":
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey)
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey)

    waitFor allFutures(client.start(), server.start())

    let mountArchiveRes = server.mountArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountStore()

    client.mountStoreClient()

    ## Given
    let req = StoreQueryRequest(
      includeData: true,
      contentTopics: @[DefaultContentTopic],
      paginationLimit: Opt.some(uint64(7)),
      paginationForward: PagingDirection.BACKWARD,
    )
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    var nextReq = req # copy

    var pages = newSeq[seq[WakuMessageKeyValue]](2)
    var cursors = newSeq[Opt[WakuMessageHash]](2)

    for i in 0 ..< 2:
      let res = waitFor client.query(nextReq, peer = serverPeer)
      require res.isOk()

      # Keep query response content
      let response = res.get()
      pages[i] = response.messages
      cursors[i] = response.paginationCursor

      # Set/update the request cursor
      nextReq.paginationCursor = cursors[i]

    ## Then
    check:
      cursors[0] == Opt.some(kvs[3].messageHash)
      cursors[1] == Opt.none(WakuMessageHash)

    check:
      pages[0] == kvs[3 .. 9]
      pages[1] == kvs[0 .. 2]

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())

  test "Store protocol returns expected message when relay is disabled and filter enabled":
    ## See nwaku issue #937: 'Store: ability to decouple store from relay'
    ## Setup
    let
      filterSourceKey = generateSecp256k1Key()
      filterSource = newTestWakuNode(filterSourceKey)
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey)
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey)

    waitFor allFutures(client.start(), server.start(), filterSource.start())

    waitFor filterSource.mountFilter()
    let driver = newSqliteArchiveDriver()

    let mountArchiveRes = server.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountStore()
    waitFor server.mountFilterClient()
    client.mountStoreClient()

    ## Given
    let message = fakeWakuMessage()
    let hash = computeMessageHash(DefaultPubSubTopic, message)
    let
      serverPeer = server.peerInfo.toRemotePeerInfo()
      filterSourcePeer = filterSource.peerInfo.toRemotePeerInfo()

    ## Then
    let filterFut = newFuture[(PubsubTopic, WakuMessage)]()
    proc filterHandler(
        pubsubTopic: PubsubTopic, msg: WakuMessage
    ) {.async, gcsafe, closure.} =
      check (await server.wakuArchive.handleMessage(pubsubTopic, msg)).isOk()
      filterFut.complete((pubsubTopic, msg))

    server.wakuFilterClient.registerPushHandler(filterHandler)
    let resp = waitFor server.filterSubscribe(
      Opt.some(DefaultPubsubTopic), DefaultContentTopic, peer = filterSourcePeer
    )

    waitFor sleepAsync(100.millis)

    waitFor filterSource.wakuFilter.handleMessage(DefaultPubsubTopic, message)

    # Wait for the server filter to receive the push message
    require waitFor filterFut.withTimeout(5.seconds)

    let req =
      StoreQueryRequest(includeData: true, contentTopics: @[DefaultContentTopic])
    let res = waitFor client.query(req, serverPeer)

    ## Then
    check res.isOk()

    let response = res.get()
    check:
      response.messages.len == 1
      response.messages[0] ==
        WakuMessageKeyValue(
          messageHash: hash,
          message: Opt.some(message),
          pubsubTopic: Opt.some(DefaultPubSubTopic),
        )

    let (handledPubsubTopic, handledMsg) = filterFut.read()
    check:
      handledPubsubTopic == DefaultPubsubTopic
      handledMsg == message

    ## Cleanup
    waitFor allFutures(client.stop(), server.stop(), filterSource.stop())

  test "history query should return INVALID_CURSOR if the cursor has empty data in the request":
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey)
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey)

    waitFor allFutures(client.start(), server.start())

    let mountArchiveRes = server.mountArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountStore()

    client.mountStoreClient()

    ## Forcing a bad cursor with empty digest data
    var cursor: WakuMessageHash = [
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0,
    ]

    ## Given
    let req = StoreQueryRequest(
      contentTopics: @[DefaultContentTopic], paginationCursor: Opt.some(cursor)
    )
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    let queryRes = waitFor client.query(req, peer = serverPeer)

    ## Then
    check queryRes.isOk()

    let response = queryRes.get()

    check response.statusCode == 400
    check response.statusDesc == "BAD_REQUEST: invalid cursor"

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())

  test "Store protocol queries does not violate request rate limitation":
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey)
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey)

    waitFor allFutures(client.start(), server.start())

    let mountArchiveRes = server.mountArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountStore((4, 500.millis))

    client.mountStoreClient()

    ## Given
    let req =
      StoreQueryRequest(includeData: true, contentTopics: @[DefaultContentTopic])
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    let requestProc = proc() {.async.} =
      let queryRes = await client.query(req, peer = serverPeer)

      assert queryRes.isOk(), queryRes.error

      let response = queryRes.get()
      check:
        response.messages.mapIt(it.message.get()) == msgListA

    for count in 0 ..< 4:
      waitFor requestProc()
      waitFor sleepAsync(20.millis)

    waitFor sleepAsync(500.millis)

    for count in 0 ..< 4:
      waitFor requestProc()
      waitFor sleepAsync(20.millis)

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())

  test "Store protocol queries overrun request rate limitation":
    # A runtime `if`: under `when`, the code after `return` is unreachable on
    # macOS and the compiler warns.
    if defined(macosx):
      # on macos CI, this test is resulting a code 200 (OK) instead of a 429 error
      # means the runner is somehow too slow to cause a request limit failure
      skip()
      return

    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey)
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey)

    waitFor allFutures(client.start(), server.start())

    let mountArchiveRes = server.mountArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountStore((3, 200.millis))

    client.mountStoreClient()

    ## Given
    let req =
      StoreQueryRequest(includeData: true, contentTopics: @[DefaultContentTopic])
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    let successProc = proc() {.async.} =
      let queryRes = await client.query(req, peer = serverPeer)

      check queryRes.isOk()
      let response = queryRes.get()
      check:
        response.messages.mapIt(it.message.get()) == msgListA

    let failsProc = proc() {.async.} =
      let queryRes = await client.query(req, peer = serverPeer)

      check queryRes.isOk()
      let response = queryRes.get()

      check response.statusCode == 429

    for count in 0 ..< 3:
      waitFor successProc()
      waitFor sleepAsync(1.millis)

    waitFor failsProc()

    waitFor sleepAsync(200.millis)

    for count in 0 ..< 3:
      waitFor successProc()
      waitFor sleepAsync(20.millis)

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())

  asyncTest "a relay node that joins a node over its inbound relay target gets its store answer":
    ## Setup
    # maxConnections 16 gives an inbound relay target of 6
    let
      server = newTestWakuNode(generateSecp256k1Key(), maxConnections = 16)
      client = newTestWakuNode(generateSecp256k1Key())
      others = toSeq(0 ..< 7).mapIt(newTestWakuNode(generateSecp256k1Key()))
      nodes = @[server, client] & others

    await allFutures(nodes.mapIt(it.start()))
    for node in nodes:
      (await node.mountRelay()).isOkOr:
        raiseAssert "failed to mount relay: " & error
      # No relay pruning or dialling: only the join of the client is under test
      node.peerManager.stop()

    server.mountArchive(archiveA).isOkOr:
      raiseAssert "failed to mount archive: " & error
    await server.mountStore()
    client.mountStoreClient()

    let serverPeer = server.peerInfo.toRemotePeerInfo()
    let clientId = client.peerInfo.peerId

    ## Given the server knows that the client speaks relay
    require await client.peerManager.connectPeer(serverPeer)
    checkUntilTimeout:
      server.peerManager.switch.peerStore.hasPeer(clientId, WakuRelayCodec)
    await client.peerManager.disconnectNode(server.peerInfo.peerId)
    checkUntilTimeout:
      not server.switch.isConnected(clientId)

    ## And the server is over its inbound relay target
    for other in others:
      require await other.peerManager.connectPeer(serverPeer)
    checkUntilTimeout:
      server.peerManager.connectedPeers(WakuRelayCodec)[0].len == 7

    ## When
    let req =
      StoreQueryRequest(includeData: true, contentTopics: @[DefaultContentTopic])
    let queryRes = await client.query(req, peer = serverPeer)

    ## Then
    check:
      queryRes.isOk()
      queryRes.get().messages == kvs

    # Cleanup
    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "a node with a full relay headroom refuses a new relay peer, keeps the connection and answers its store query":
    ## Setup
    # maxConnections 16 gives a relay peer limit of 8, and relay admits 1 peer above it
    let
      server = newTestWakuNode(generateSecp256k1Key(), maxConnections = 16)
      client = newTestWakuNode(generateSecp256k1Key())
      others = toSeq(0 ..< 9).mapIt(newTestWakuNode(generateSecp256k1Key()))
      nodes = @[server, client] & others

    await allFutures(nodes.mapIt(it.start()))
    for node in nodes:
      (await node.mountRelay()).isOkOr:
        raiseAssert "failed to mount relay: " & error
      # No relay pruning or dialling: only the relay peer limit is under test
      node.peerManager.stop()

    server.mountArchive(archiveA).isOkOr:
      raiseAssert "failed to mount archive: " & error
    await server.mountStore()
    client.mountStoreClient()

    let serverPeer = server.peerInfo.toRemotePeerInfo()
    let clientId = client.peerInfo.peerId

    ## Given the server admits no more relay peers
    for other in others:
      require await other.peerManager.connectPeer(serverPeer)
    checkUntilTimeout:
      server.peerManager.connectedPeers(WakuRelayCodec)[0].len == 9

    ## When a relay node queries the server's store
    let req =
      StoreQueryRequest(includeData: true, contentTopics: @[DefaultContentTopic])
    let queryRes = await client.query(req, peer = serverPeer)
    # Without the limit, the client's relay stream would be open by now.
    await sleepAsync(300.milliseconds)

    ## Then the server answers but does not take the client as a relay peer
    let (inRelayPeers, outRelayPeers) =
      server.peerManager.connectedPeers(WakuRelayCodec)
    check:
      queryRes.isOk()
      queryRes.get().messages == kvs
      server.switch.isConnected(clientId)
      clientId notin inRelayPeers & outRelayPeers

    # Cleanup
    await allFutures(nodes.mapIt(it.stop()))

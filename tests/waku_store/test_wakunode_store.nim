{.used.}

import
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
  waku/[
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
  ../testlib/wakucore,
  ../testlib/wakunode

procSuite "WakuNode - Store":
  ## Fixtures
  let timeOrigin = now()
  let msgListA =
    @[
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
        messageHash: it[0], message: some(it[1]), pubsubTopic: some(DefaultPubsubTopic)
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
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

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
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

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
      paginationLimit: some(uint64(7)),
    )
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    var nextReq = req # copy

    var pages = newSeq[seq[WakuMessageKeyValue]](2)
    var cursors = newSeq[Option[WakuMessageHash]](2)

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
      cursors[0] == some(kvs[6].messageHash)
      cursors[1] == none(WakuMessageHash)

    check:
      pages[0] == kvs[0 .. 6]
      pages[1] == kvs[7 .. 9]

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())

  test "Store node history response - backward pagination":
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

    waitFor allFutures(client.start(), server.start())

    let mountArchiveRes = server.mountArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountStore()

    client.mountStoreClient()

    ## Given
    let req = StoreQueryRequest(
      includeData: true,
      contentTopics: @[DefaultContentTopic],
      paginationLimit: some(uint64(7)),
      paginationForward: PagingDirection.BACKWARD,
    )
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    var nextReq = req # copy

    var pages = newSeq[seq[WakuMessageKeyValue]](2)
    var cursors = newSeq[Option[WakuMessageHash]](2)

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
      cursors[0] == some(kvs[3].messageHash)
      cursors[1] == none(WakuMessageHash)

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
      filterSource =
        newTestWakuNode(filterSourceKey, parseIpAddress("0.0.0.0"), Port(0))
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

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
      await server.wakuArchive.handleMessage(pubsubTopic, msg)
      filterFut.complete((pubsubTopic, msg))

    server.wakuFilterClient.registerPushHandler(filterHandler)
    let resp = waitFor server.filterSubscribe(
      some(DefaultPubsubTopic), DefaultContentTopic, peer = filterSourcePeer
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
          message: some(message),
          pubsubTopic: some(DefaultPubSubTopic),
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
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

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
      contentTopics: @[DefaultContentTopic], paginationCursor: some(cursor)
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
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

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
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

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

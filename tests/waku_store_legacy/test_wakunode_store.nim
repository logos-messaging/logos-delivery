{.used.}

import
  std/net,
  testutils/unittests,
  chronos,
  libp2p/crypto/crypto,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub
import
  waku/[
    common/paging,
    waku_core,
    waku_core/message/digest,
    node/peer_manager,
    waku_archive_legacy,
    waku_filter_v2,
    waku_filter_v2/client,
    waku_store_legacy,
    waku_node,
  ],
  ../waku_store_legacy/store_utils,
  ../waku_archive_legacy/archive_utils,
  ../testlib/wakucore,
  ../testlib/wakunode

procSuite "WakuNode - Store Legacy":
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

  let archiveA = block:
    let driver = newSqliteArchiveDriver()

    for msg in msgListA:
      let msg_digest = waku_archive_legacy.computeDigest(msg)
      let msg_hash = computeMessageHash(DefaultPubsubTopic, msg)
      require (
        waitFor driver.put(DefaultPubsubTopic, msg, msg_digest, msg_hash, msg.timestamp)
      ).isOk()

    driver

  test "Store protocol returns expected messages":
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

    waitFor allFutures(client.start(), server.start())

    let mountArchiveRes = server.mountLegacyArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountLegacyStore()

    client.mountLegacyStoreClient()

    ## Given
    let req = HistoryQuery(contentTopics: @[DefaultContentTopic])
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    let queryRes = waitFor client.query(req, peer = serverPeer)

    ## Then
    check queryRes.isOk()

    let response = queryRes.get()
    check:
      response.messages == msgListA

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

    let mountArchiveRes = server.mountLegacyArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountLegacyStore()

    client.mountLegacyStoreClient()

    ## Given
    let req = HistoryQuery(
      contentTopics: @[DefaultContentTopic],
      pageSize: 7,
      direction: PagingDirection.FORWARD,
    )
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    var nextReq = req # copy

    var pages = newSeq[seq[WakuMessage]](2)
    var cursors = newSeq[Option[HistoryCursor]](2)

    for i in 0 ..< 2:
      let res = waitFor client.query(nextReq, peer = serverPeer)
      require res.isOk()

      # Keep query response content
      let response = res.get()
      pages[i] = response.messages
      cursors[i] = response.cursor

      # Set/update the request cursor
      nextReq.cursor = cursors[i]

    ## Then
    check:
      cursors[0] == some(computeHistoryCursor(DefaultPubsubTopic, msgListA[6]))
      cursors[1] == none(HistoryCursor)

    check:
      pages[0] == msgListA[0 .. 6]
      pages[1] == msgListA[7 .. 9]

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

    let mountArchiveRes = server.mountLegacyArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountLegacyStore()

    client.mountLegacyStoreClient()

    ## Given
    let req = HistoryQuery(
      contentTopics: @[DefaultContentTopic],
      pageSize: 7,
      direction: PagingDirection.BACKWARD,
    )
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    var nextReq = req # copy

    var pages = newSeq[seq[WakuMessage]](2)
    var cursors = newSeq[Option[HistoryCursor]](2)

    for i in 0 ..< 2:
      let res = waitFor client.query(nextReq, peer = serverPeer)
      require res.isOk()

      # Keep query response content
      let response = res.get()
      pages[i] = response.messages
      cursors[i] = response.cursor

      # Set/update the request cursor
      nextReq.cursor = cursors[i]

    ## Then
    check:
      cursors[0] == some(computeHistoryCursor(DefaultPubsubTopic, msgListA[3]))
      cursors[1] == none(HistoryCursor)

    check:
      pages[0] == msgListA[3 .. 9]
      pages[1] == msgListA[0 .. 2]

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

    let mountArchiveRes = server.mountLegacyArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountLegacyStore()
    waitFor server.mountFilterClient()
    client.mountLegacyStoreClient()

    ## Given
    let message = fakeWakuMessage()
    let
      serverPeer = server.peerInfo.toRemotePeerInfo()
      filterSourcePeer = filterSource.peerInfo.toRemotePeerInfo()

    ## Then
    let filterFut = newFuture[(PubsubTopic, WakuMessage)]()
    proc filterHandler(
        pubsubTopic: PubsubTopic, msg: WakuMessage
    ) {.async, gcsafe, closure.} =
      await server.wakuLegacyArchive.handleMessage(pubsubTopic, msg)
      filterFut.complete((pubsubTopic, msg))

    server.wakuFilterClient.registerPushHandler(filterHandler)
    let resp = waitFor server.filterSubscribe(
      some(DefaultPubsubTopic), DefaultContentTopic, peer = filterSourcePeer
    )

    waitFor sleepAsync(100.millis)

    waitFor filterSource.wakuFilter.handleMessage(DefaultPubsubTopic, message)

    # Wait for the server filter to receive the push message
    require waitFor filterFut.withTimeout(5.seconds)

    let res = waitFor client.query(
      HistoryQuery(contentTopics: @[DefaultContentTopic]), peer = serverPeer
    )

    ## Then
    check res.isOk()

    let response = res.get()
    check:
      response.messages.len == 1
      response.messages[0] == message

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

    let mountArchiveRes = server.mountLegacyArchive(archiveA)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    waitFor server.mountLegacyStore()

    client.mountLegacyStoreClient()

    ## Forcing a bad cursor with empty digest data
    var data: array[32, byte] = [
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0,
    ]
    let cursor = HistoryCursor(
      pubsubTopic: "pubsubTopic",
      senderTime: now(),
      storeTime: now(),
      digest: waku_archive_legacy.MessageDigest(data: data),
    )

    ## Given
    let req = HistoryQuery(contentTopics: @[DefaultContentTopic], cursor: some(cursor))
    let serverPeer = server.peerInfo.toRemotePeerInfo()

    ## When
    let queryRes = waitFor client.query(req, peer = serverPeer)

    ## Then
    check not queryRes.isOk()

    check queryRes.error ==
      "legacy store client query error: BAD_REQUEST: invalid cursor"

    # Cleanup
    waitFor allFutures(client.stop(), server.stop())

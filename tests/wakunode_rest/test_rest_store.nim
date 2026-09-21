{.used.}

import
  results,
  std/[json, sequtils, strutils, sugar],
  chronicles,
  chronos/timer,
  testutils/unittests,
  eth/keys,
  presto,
  presto/client as presto_client,
  libp2p/crypto/crypto
import
  logos_delivery/waku/[
    waku_core/message,
    waku_core/message/digest,
    waku_core/topics,
    waku_node,
    node/peer_manager,
    rest_api/endpoint/server,
    rest_api/endpoint/client,
    rest_api/endpoint/responses,
    rest_api/endpoint/store/handlers as store_rest_interface,
    rest_api/endpoint/store/client as store_rest_client,
    rest_api/endpoint/store/types,
    waku_archive,
    waku_archive/driver/queue_driver,
    waku_archive/driver/sqlite_driver,
    common/databases/db_sqlite,
    waku_store as waku_store,
  ],
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../testlib/rest_requests,
  ../waku_archive/archive_utils

logScope:
  topics = "waku node rest store_rest_interface test"

proc put(
    store: ArchiveDriver, pubsubTopic: PubsubTopic, message: WakuMessage
): Future[Result[void, string]] =
  let msgHash = computeMessageHash(pubsubTopic, message)

  store.put(msgHash, pubsubTopic, message)

# Creates a new WakuNode
proc testWakuNode(): WakuNode =
  let
    privkey = generateSecp256k1Key()
    bindIp = parseIpAddress("0.0.0.0")
    extIp = parseIpAddress("127.0.0.1")
    port = Port(0)

  return newTestWakuNode(privkey, bindIp, port, Opt.some(extIp), Opt.some(port))

type RestStoreTest = object
  node: WakuNode
  driver: ArchiveDriver
  restServer: WakuRestServerRef
  client: RestClientRef
  hashes: seq[WakuMessageHash]

proc defaultSeed(): seq[WakuMessage] =
  @[
    fakeWakuMessage(@[byte 1], ts = 1),
    fakeWakuMessage(@[byte 2], ts = 2),
    fakeWakuMessage(@[byte 3], ts = 3),
  ]

proc init(
    T: type RestStoreTest, msgs: seq[WakuMessage], driver: ArchiveDriver
): Future[RestStoreTest] {.async.} =
  var t = RestStoreTest(node: testWakuNode(), driver: driver)
  await t.node.start()

  t.node.mountArchive(t.driver).isOkOr:
    assert false, "failed to mount archive: " & error

  await t.node.mountStore()

  let restAddress = parseIpAddress("0.0.0.0")
  t.restServer = WakuRestServerRef.init(restAddress, Port(0)).tryGet()
  installStoreApiHandlers(t.restServer.router, t.node)
  t.restServer.start()

  t.client =
    newRestHttpClient(initTAddress(restAddress, t.restServer.httpServer.address.port))

  for msg in msgs:
    let hash = computeMessageHash(DefaultPubsubTopic, msg)
    let putRes = await t.driver.put(hash, DefaultPubsubTopic, msg)
    assert putRes.isOk(), "failed to seed the archive: " & putRes.error
    t.hashes.add(hash)

  return t

proc init(
    T: type RestStoreTest, msgs: seq[WakuMessage] = defaultSeed()
): Future[RestStoreTest] =
  RestStoreTest.init(msgs, QueueDriver.new())

proc shutdown(t: RestStoreTest) {.async.} =
  await t.restServer.stop()
  await t.restServer.closeWait()
  await t.node.stop()

################################################################################
# Beginning of the tests
################################################################################
procSuite "Waku Rest API - Store v3":
  asyncTest "MessageHash <-> string conversions":
    # Validate MessageHash conversion from a WakuMessage obj
    let wakuMsg = WakuMessage(
      contentTopic: "Test content topic", payload: @[byte('H'), byte('i'), byte('!')]
    )

    let messageHash = computeMessageHash(DefaultPubsubTopic, wakuMsg)
    let restMsgHash = Opt.some(messageHash.toRestStringWakuMessageHash())

    let parsedMsgHashRes = parseHash(restMsgHash)
    assert parsedMsgHashRes.isOk(), $parsedMsgHashRes.error

    check:
      messageHash == parsedMsgHashRes.get().get()

    # Random validation. Obtained the raw values manually
    let expected =
      Opt.some("0x9e0ea917677a3d2b8610b0126986d89824b6acf76008b5fb9aa8b99ac906c1a7")

    let msgHashRes = parseHash(expected)
    assert msgHashRes.isOk(), $msgHashRes.error

    check:
      expected.get() == msgHashRes.get().get().toRestStringWakuMessageHash()

  asyncTest "invalid cursor":
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      error "failed to mount relay", error = error

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let db: SqliteDatabase =
      SqliteDatabase.new(Opt.none(string).get(":memory:")).expect("valid DB")
    let driver: ArchiveDriver = SqliteDriver.new(db).expect("valid driver")
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()
    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(Opt.some(key))
    await peerSwitch.start()

    peerSwitch.mount(node.wakuStore)

    await sleepAsync(1.seconds())

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(@[byte 0], contentTopic = ContentTopic("ct1"), ts = 0),
      fakeWakuMessage(@[byte 1], ts = 1),
      fakeWakuMessage(@[byte 1, byte 2], ts = 2),
      fakeWakuMessage(@[byte 1], ts = 3),
      fakeWakuMessage(@[byte 1], ts = 4),
      fakeWakuMessage(@[byte 1], ts = 5),
      fakeWakuMessage(@[byte 1], ts = 6),
      fakeWakuMessage(@[byte 9], contentTopic = ContentTopic("c2"), ts = 9),
    ]
    for msg in msgList:
      require (await driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] & "/p2p/" & $remotePeerInfo.peerId

    await sleepAsync(1.seconds())

    let fakeCursor = computeMessageHash(DefaultPubsubTopic, fakeWakuMessage())
    let encodedCursor = fakeCursor.toRestStringWakuMessageHash()

    # Apply filter by start and end timestamps
    var response = await client.getStoreMessagesV3(
      encodeUrl(fullAddr),
      "true", # include data
      "", # pubsub topic
      "ct1,c2", # empty content topics.
      "", # start time
      "", # end time
      "", # hashes
      encodedCursor, # hex-encoded hash
      "true", # ascending
      "5", # empty implies default page size
    )

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 0

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Filter by start and end time":
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      error "failed to mount relay", error = error

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()
    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(Opt.some(key))
    await peerSwitch.start()

    peerSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(@[byte 0], contentTopic = ContentTopic("ct1"), ts = 0),
      fakeWakuMessage(@[byte 1], ts = 1),
      fakeWakuMessage(@[byte 1, byte 2], ts = 2),
      fakeWakuMessage(@[byte 1], ts = 3),
      fakeWakuMessage(@[byte 1], ts = 4),
      fakeWakuMessage(@[byte 1], ts = 5),
      fakeWakuMessage(@[byte 1], ts = 6),
      fakeWakuMessage(@[byte 9], contentTopic = ContentTopic("c2"), ts = 9),
    ]
    for msg in msgList:
      require (await driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] & "/p2p/" & $remotePeerInfo.peerId

    # Apply filter by start and end timestamps
    var response = await client.getStoreMessagesV3(
      encodeUrl(fullAddr),
      "true", # include data
      encodeUrl(DefaultPubsubTopic),
      "", # empty content topics. Don't filter by this field
      "3", # start time
      "6", # end time
      "", # hashes
      "", # hex-encoded hash
      "true", # ascending
      "", # empty implies default page size
    )

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 4

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Store node history response - forward pagination":
    # Test adapted from the analogous present at waku_store/test_wakunode_store.nim
    let node = testWakuNode()
    await node.start()

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()
    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(Opt.some(key))
    await peerSwitch.start()

    peerSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let timeOrigin = wakucore.now()
    let msgList = @[
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
    for msg in msgList:
      require (await driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] & "/p2p/" & $remotePeerInfo.peerId

    var pages = newSeq[seq[WakuMessage]](2)

    var reqHash = Opt.none(string)

    for i in 0 ..< 2:
      let response = await client.getStoreMessagesV3(
        encodeUrl(fullAddr),
        "true", # include data
        encodeUrl(DefaultPubsubTopic),
        "", # content topics. Empty ignores the field.
        "", # start time. Empty ignores the field.
        "", # end time. Empty ignores the field.
        "", # hashes
        if reqHash.isSome():
          reqHash.get()
        else:
          "", # hex-encoded digest. Empty ignores the field.
        "true", # ascending
        "7", # page size. Empty implies default page size.
      )

      let wakuMessages = collect(newSeq):
        for element in response.data.messages:
          if element.message.isSome():
            element.message.get()

      pages[i] = wakuMessages

      # populate the cursor for next page
      if response.data.paginationCursor.isSome():
        reqHash = Opt.some(response.data.paginationCursor.get())

      check:
        response.status == 200
        $response.contentType == $MIMETYPE_JSON

    check:
      pages[0] == msgList[0 .. 6]
      pages[1] == msgList[7 .. 9]

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "query a node and retrieve historical messages filtered by pubsub topic":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      error "failed to mount relay", error = error

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()
    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(Opt.some(key))
    await peerSwitch.start()

    peerSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(@[byte 0], contentTopic = ContentTopic("2"), ts = 0),
      fakeWakuMessage(@[byte 1], ts = 1),
      fakeWakuMessage(@[byte 9], contentTopic = ContentTopic("2"), ts = 9),
    ]
    for msg in msgList:
      require (await driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] & "/p2p/" & $remotePeerInfo.peerId

    # Filtering by a known pubsub topic
    var response = await client.getStoreMessagesV3(
      encodeUrl($fullAddr), "true", encodeUrl(DefaultPubsubTopic)
    )

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Get all the messages by specifying an empty pubsub topic
    response = await client.getStoreMessagesV3(encodeUrl($fullAddr), "true")
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Receiving no messages by filtering with a random pubsub topic
    response = await client.getStoreMessagesV3(
      encodeUrl($fullAddr), "true", encodeUrl("random pubsub topic")
    )
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 0

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "retrieve historical messages from a provided store node address":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      error "failed to mount relay", error = error

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()
    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(Opt.some(key))
    await peerSwitch.start()

    peerSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(@[byte 0], contentTopic = ContentTopic("ct1"), ts = 0),
      fakeWakuMessage(@[byte 1], ts = 1),
      fakeWakuMessage(@[byte 9], contentTopic = ContentTopic("ct2"), ts = 9),
    ]
    for msg in msgList:
      require (await driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] & "/p2p/" & $remotePeerInfo.peerId

    # Filtering by a known pubsub topic.
    # We also pass the store-node address in the request.
    var response = await client.getStoreMessagesV3(
      encodeUrl(fullAddr), "true", encodeUrl(DefaultPubsubTopic)
    )
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Get all the messages by specifying an empty pubsub topic
    # We also pass the store-node address in the request.
    response =
      await client.getStoreMessagesV3(encodeUrl(fullAddr), "true", encodeUrl(""))
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Receiving no messages by filtering with a random pubsub topic
    # We also pass the store-node address in the request.
    response = await client.getStoreMessagesV3(
      encodeUrl(fullAddr), "true", encodeUrl("random pubsub topic")
    )
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 0

    # Receiving 400 response if setting wrong store-node address
    response = await client.getStoreMessagesV3(
      encodeUrl("incorrect multi address format"),
      "true",
      encodeUrl("random pubsub topic"),
    )
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.messages.len == 0
      response.data.statusDesc ==
        "Failed parsing remote peer info: MultiAddress.init [multiaddress: Invalid MultiAddress, must start with `/`]"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "filter historical messages by content topic":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      error "failed to mount relay", error = error

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()
    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(Opt.some(key))
    await peerSwitch.start()

    peerSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(@[byte 0], contentTopic = ContentTopic("ct1"), ts = 0),
      fakeWakuMessage(@[byte 1], ts = 1),
      fakeWakuMessage(@[byte 9], contentTopic = ContentTopic("ct2"), ts = 9),
    ]
    for msg in msgList:
      require (await driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] & "/p2p/" & $remotePeerInfo.peerId

    # Filtering by content topic
    let response = await client.getStoreMessagesV3(
      encodeUrl(fullAddr), "true", encodeUrl(DefaultPubsubTopic), encodeUrl("ct1,ct2")
    )
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 2

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "precondition failed":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      error "failed to mount relay", error = error

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(Opt.some(key))
    await peerSwitch.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()

    # Sending no peer-store node address
    var response = await client.getStoreMessagesV3(
      encodeUrl(""), "true", encodeUrl(DefaultPubsubTopic)
    )
    check:
      response.status == 412
      $response.contentType == $MIMETYPE_TEXT
      response.data.messages.len == 0
      response.data.statusDesc == NoPeerNoDiscError.errobj.message

    # Now add the storenode from "config"
    node.peerManager.addServicePeer(remotePeerInfo, WakuStoreCodec)

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(@[byte 0], contentTopic = ContentTopic("ct1"), ts = 0),
      fakeWakuMessage(@[byte 1], ts = 1),
      fakeWakuMessage(@[byte 9], contentTopic = ContentTopic("ct2"), ts = 9),
    ]
    for msg in msgList:
      require (await driver.put(DefaultPubsubTopic, msg)).isOk()

    # Sending no peer-store node address
    response = await client.getStoreMessagesV3(
      encodeUrl(""), "true", encodeUrl(DefaultPubsubTopic)
    )
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "retrieve historical messages from a self-store-node":
    ## This test aims to validate the correct message retrieval for a store-node which exposes
    ## a REST server.

    # Given
    let node = testWakuNode()
    await node.start()

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(
        @[byte 0], contentTopic = ContentTopic("ct1"), ts = 0, meta = (@[byte 8])
      ),
      fakeWakuMessage(@[byte 1], ts = 1),
      fakeWakuMessage(@[byte 9], contentTopic = ContentTopic("ct2"), ts = 9),
    ]
    for msg in msgList:
      require (await driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    # Filtering by a known pubsub topic.
    var response = await client.getStoreMessagesV3(
      includeData = "true", pubsubTopic = encodeUrl(DefaultPubsubTopic)
    )

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Get all the messages by specifying an empty pubsub topic
    response =
      await client.getStoreMessagesV3(includeData = "true", pubsubTopic = encodeUrl(""))
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3

    # Receiving no messages by filtering with a random pubsub topic
    response = await client.getStoreMessagesV3(
      includeData = "true", pubsubTopic = encodeUrl("random pubsub topic")
    )
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 0

  asyncTest "correct message fields are returned":
    # Given
    let node = testWakuNode()
    await node.start()

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()

    # Now prime it with some history before tests
    let msg = fakeWakuMessage(
      @[byte 0], contentTopic = ContentTopic("ct1"), ts = 0, meta = (@[byte 8])
    )
    require (await driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    # Filtering by a known pubsub topic.
    var response = await client.getStoreMessagesV3(
      includeData = "true", pubsubTopic = encodeUrl(DefaultPubsubTopic)
    )

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 1

    let storeMessage = response.data.messages[0].message.get()

    check:
      storeMessage.payload == msg.payload
      storeMessage.contentTopic == msg.contentTopic
      storeMessage.version == msg.version
      storeMessage.timestamp == msg.timestamp
      storeMessage.ephemeral == msg.ephemeral
      storeMessage.meta == msg.meta

  asyncTest "Rate limit store node store query":
    # Test adapted from the analogous present at waku_store/test_wakunode_store.nim
    let node = testWakuNode()
    await node.start()

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installStoreApiHandlers(restServer.router, node)
    restServer.start()

    # WakuStore setup
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    # bucket refills 4 tokens/s: the 429 below needs all 3 requests within 250ms
    await node.mountStore((2, 500.millis))
    node.mountStoreClient()

    let key = generateEcdsaKey()
    var peerSwitch = newStandardSwitch(Opt.some(key))
    await peerSwitch.start()

    peerSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let timeOrigin = wakucore.now()
    let msgList = @[
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
    for msg in msgList:
      require (await driver.put(DefaultPubsubTopic, msg)).isOk()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] & "/p2p/" & $remotePeerInfo.peerId

    var pages = newSeq[seq[WakuMessage]](2)

    var reqPubsubTopic = DefaultPubsubTopic
    var reqHash = Opt.none(string)

    for i in 0 ..< 2:
      let response = await client.getStoreMessagesV3(
        encodeUrl(fullAddr),
        "true", # include data
        encodeUrl(reqPubsubTopic),
        "", # content topics. Empty ignores the field.
        "", # start time. Empty ignores the field.
        "", # end time. Empty ignores the field.
        "", # hashes
        if reqHash.isSome():
          reqHash.get()
        else:
          "", # hex-encoded digest. Empty ignores the field.
        "true", # ascending
        "3", # page size. Empty implies default page size.
      )

      let wakuMessages = collect(newSeq):
        for element in response.data.messages:
          if element.message.isSome():
            element.message.get()

      pages[i] = wakuMessages

      # populate the cursor for next page
      if response.data.paginationCursor.isSome():
        reqHash = response.data.paginationCursor

      check:
        response.status == 200
        $response.contentType == $MIMETYPE_JSON

    check:
      pages[0] == msgList[0 .. 2]
      pages[1] == msgList[3 .. 5]

    # request last third will lead to rate limit rejection
    var response = await client.getStoreMessagesV3(
      encodeUrl(fullAddr),
      "true", # include data
      encodeUrl(reqPubsubTopic),
      "", # content topics. Empty ignores the field.
      "", # start time. Empty ignores the field.
      "", # end time. Empty ignores the field.
      "", # hashes
      if reqHash.isSome():
        reqHash.get()
      else:
        "", # hex-encoded digest. Empty ignores the field.
    )

    check:
      response.status == 429
      $response.contentType == $MIMETYPE_TEXT
      response.data.statusDesc == "Request rate limit reached"

    await sleepAsync(500.millis)

    # retry after respective amount of time shall succeed
    response = await client.getStoreMessagesV3(
      encodeUrl(fullAddr),
      "true", # include data
      encodeUrl(reqPubsubTopic),
      "", # content topics. Empty ignores the field.
      "", # start time. Empty ignores the field.
      "", # end time. Empty ignores the field.
      "", # hashes
      if reqHash.isSome():
        reqHash.get()
      else:
        "", # hex-encoded digest. Empty ignores the field.
      "true", # ascending
      "5", # page size. Empty implies default page size.
    )

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON

    let wakuMessages = collect(newSeq):
      for element in response.data.messages:
        if element.message.isSome():
          element.message.get()

    check wakuMessages == msgList[6 .. 9]

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "hashes filter: each hash list returns exactly its messages":
    let t = await RestStoreTest.init()
    defer:
      await t.shutdown()
    let secondHash = t.hashes[1].toRestStringWakuMessageHash()

    var response = await t.client.getStoreMessagesV3(hashes = secondHash)
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.statusCode == 200
      response.data.statusDesc == "OK"
      response.data.messages.mapIt(it.messageHash) == @[secondHash]

    response = await t.client.getStoreMessagesV3(hashes = secondHash & "," & secondHash)
    check:
      response.status == 200
      response.data.messages.mapIt(it.messageHash) == @[secondHash]

    response = await t.client.getStoreMessagesV3(hashes = secondHash & ",")
    check:
      response.status == 200
      response.data.messages.mapIt(it.messageHash) == @[secondHash]

    let absentHash = computeMessageHash(
        DefaultPubsubTopic, fakeWakuMessage(@[byte 42], ts = 42)
      )
      .toRestStringWakuMessageHash()

    response = await t.client.getStoreMessagesV3(hashes = absentHash)
    check:
      response.status == 200
      response.data.messages.len == 0

  asyncTest "hashes filter: comma-separated hashes return exactly those messages in chronological order":
    let t = await RestStoreTest.init()
    defer:
      await t.shutdown()
    let requested =
      t.hashes[2].toRestStringWakuMessageHash() & "," &
      t.hashes[0].toRestStringWakuMessageHash()

    let response = await t.client.getStoreMessagesV3(hashes = requested)
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 2
      response.data.messages.mapIt(it.messageHash) ==
        @[
          t.hashes[0].toRestStringWakuMessageHash(),
          t.hashes[2].toRestStringWakuMessageHash(),
        ]

  asyncTest "hashes filter: non-hex and wrong-length hashes are rejected with 400":
    let t = await RestStoreTest.init()
    defer:
      await t.shutdown()

    var response = await t.client.getStoreMessagesV3(hashes = "zzzz")
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.statusDesc.contains("Exception converting hex string to bytes")

    response = await t.client.getStoreMessagesV3(hashes = "0xabcd")
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.statusDesc.contains("invalid hash length")

  asyncTest "ascending=false returns the tail page in chronological order":
    let t = await RestStoreTest.init(
      @[
        fakeWakuMessage(@[byte 1], ts = 1),
        fakeWakuMessage(@[byte 2], ts = 2),
        fakeWakuMessage(@[byte 3], ts = 3),
        fakeWakuMessage(@[byte 4], ts = 4),
        fakeWakuMessage(@[byte 5], ts = 5),
      ]
    )
    defer:
      await t.shutdown()

    let response =
      await t.client.getStoreMessagesV3(ascending = "false", pageSize = "2")
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.mapIt(it.messageHash) ==
        @[
          t.hashes[3].toRestStringWakuMessageHash(),
          t.hashes[4].toRestStringWakuMessageHash(),
        ]

  asyncTest "includeData toggles message and pubsubTopic in the response":
    let t = await RestStoreTest.init()
    defer:
      await t.shutdown()

    var response = await t.client.getStoreMessagesV3(includeData = "true")
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.messages.len == 3
      response.data.messages.allIt(it.message.isSome())
      response.data.messages.allIt(it.pubsubTopic.isSome())

    response = await t.client.getStoreMessagesV3(includeData = "false")
    check:
      response.status == 200
      response.data.messages.allIt(it.message.isNone())
      response.data.messages.allIt(it.pubsubTopic.isNone())
      response.data.messages.mapIt(it.messageHash) ==
        t.hashes.mapIt(it.toRestStringWakuMessageHash())

  asyncTest "malformed pageSize, startTime, includeData and cursor are each rejected with 400":
    let t = await RestStoreTest.init()
    defer:
      await t.shutdown()

    var response = await t.client.getStoreMessagesV3(pageSize = "$2")
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.statusDesc.contains("page size parsing error")

    response = await t.client.getStoreMessagesV3(startTime = "abc")
    check:
      response.status == 400
      response.data.statusDesc.contains("time parsing error")

    response = await t.client.getStoreMessagesV3(includeData = "banana")
    check:
      response.status == 400
      response.data.statusDesc.contains("include data parsing error")

    response = await t.client.getStoreMessagesV3(cursor = "zzzz")
    check:
      response.status == 400
      response.data.statusDesc.contains("Exception converting hex string to bytes")

    response = await t.client.getStoreMessagesV3(cursor = "0xabcd")
    check:
      response.status == 400
      response.data.statusDesc.contains("invalid hash length")

  asyncTest "peerAddr without a transport is rejected with 400":
    let t = await RestStoreTest.init()
    defer:
      await t.shutdown()
    let peerAddr = "/ip4/127.0.0.1/p2p/" & $t.node.peerInfo.peerId

    let response = await t.client.getStoreMessagesV3(peerAddr = encodeUrl(peerAddr))
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.statusDesc.contains("no supported transport found")

  asyncTest "peerAddr with a corrupt peer id is rejected with 400":
    let t = await RestStoreTest.init()
    defer:
      await t.shutdown()
    let corruptPeerId = ($t.node.peerInfo.peerId)[0 ..^ 2] & "0"
    let peerAddr = "/ip4/127.0.0.1/tcp/60000/p2p/" & corruptPeerId

    let response = await t.client.getStoreMessagesV3(peerAddr = encodeUrl(peerAddr))
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.statusDesc.contains("Failed parsing remote peer info")
      response.data.statusDesc.contains("Error encoding `p2p/")

  asyncTest "pageSize: over 100 returns 100, empty returns 20, negative returns 100":
    let t = await RestStoreTest.init(
      toSeq(1 .. 101).mapIt(fakeWakuMessage(@[byte(it)], ts = int64(it)))
    )
    defer:
      await t.shutdown()
    let allHashes = t.hashes.mapIt(it.toRestStringWakuMessageHash())

    var response = await t.client.getStoreMessagesV3(pageSize = "200")
    check:
      response.status == 200
      response.data.messages.mapIt(it.messageHash) == allHashes[0 ..< 100]

    response = await t.client.getStoreMessagesV3(pageSize = "")
    check:
      response.status == 200
      response.data.messages.mapIt(it.messageHash) == allHashes[0 ..< 20]

    # A negative pageSize wraps to a value over the maximum instead of being rejected.
    response = await t.client.getStoreMessagesV3(pageSize = "-1")
    check:
      response.status == 200
      response.data.messages.mapIt(it.messageHash) == allHashes[0 ..< 100]

  asyncTest "startTime and endTime of zero or less are ignored":
    let t =
      await RestStoreTest.init(@[fakeWakuMessage(@[byte 0], ts = -5)] & defaultSeed())
    defer:
      await t.shutdown()
    let allHashes = t.hashes.mapIt(it.toRestStringWakuMessageHash())

    # Unlike a non-numeric time, a time of zero or less is not rejected but ignored.
    for time in ["0", "-1"]:
      let startResponse = await t.client.getStoreMessagesV3(startTime = time)
      let endResponse = await t.client.getStoreMessagesV3(endTime = time)
      let bothResponse =
        await t.client.getStoreMessagesV3(startTime = time, endTime = time)
      check:
        startResponse.status == 200
        startResponse.data.messages.mapIt(it.messageHash) == allHashes
        endResponse.status == 200
        endResponse.data.messages.mapIt(it.messageHash) == allHashes
        bothResponse.status == 200
        bothResponse.data.messages.mapIt(it.messageHash) == allHashes

    let response = await t.client.getStoreMessagesV3(endTime = "1")
    check:
      response.status == 200
      response.data.messages.mapIt(it.messageHash) == allHashes[0 .. 1]

  asyncTest "an unparseable ascending returns the tail page, as ascending=false does":
    let t = await RestStoreTest.init(
      @[
        fakeWakuMessage(@[byte 1], ts = 1),
        fakeWakuMessage(@[byte 2], ts = 2),
        fakeWakuMessage(@[byte 3], ts = 3),
        fakeWakuMessage(@[byte 4], ts = 4),
        fakeWakuMessage(@[byte 5], ts = 5),
      ]
    )
    defer:
      await t.shutdown()

    # Unlike includeData, an unparseable ascending is not rejected but read as false.
    let response =
      await t.client.getStoreMessagesV3(ascending = "banana", pageSize = "2")
    check:
      response.status == 200
      response.data.messages.mapIt(it.messageHash) ==
        @[
          t.hashes[3].toRestStringWakuMessageHash(),
          t.hashes[4].toRestStringWakuMessageHash(),
        ]

  asyncTest "an undeclared paginationCursor parameter is ignored":
    let t = await RestStoreTest.init()
    defer:
      await t.shutdown()
    let allHashes = t.hashes.mapIt(it.toRestStringWakuMessageHash())

    let ignored = await issueRequest(
      t.restServer.getAddress("/store/v3/messages?paginationCursor=" & allHashes[0])
    )
    let paged = await issueRequest(
      t.restServer.getAddress("/store/v3/messages?cursor=" & allHashes[0])
    )
    check:
      ignored.status == 200
      parseJson(ignored.data)["messages"].getElems().mapIt(it["messageHash"].getStr()) ==
        allHashes
      paged.status == 200
      parseJson(paged.data)["messages"].getElems().mapIt(it["messageHash"].getStr()) ==
        allHashes[1 .. 2]

  asyncTest "an absent cursor is answered 500 by the self-store node and 200 through a store peer":
    let t = await RestStoreTest.init(defaultSeed(), newSqliteArchiveDriver())
    defer:
      await t.shutdown()
    t.node.mountStoreClient()

    let peerSwitch = newStandardSwitch(Opt.some(generateEcdsaKey()))
    await peerSwitch.start()
    defer:
      await peerSwitch.stop()
    peerSwitch.mount(t.node.wakuStore)

    let remotePeerInfo = peerSwitch.peerInfo.toRemotePeerInfo()
    let fullAddr = $remotePeerInfo.addrs[0] & "/p2p/" & $remotePeerInfo.peerId
    let absentCursor = computeMessageHash(
        DefaultPubsubTopic, fakeWakuMessage(@[byte 42], ts = 42)
      )
      .toRestStringWakuMessageHash()

    var response = await t.client.getStoreMessagesV3(cursor = absentCursor)
    check:
      response.status == 500
      $response.contentType == $MIMETYPE_TEXT
      response.data.statusDesc.contains("cursor not found")

    response = await t.client.getStoreMessagesV3(
      peerAddr = encodeUrl(fullAddr), cursor = absentCursor
    )
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.statusCode == 300
      response.data.statusDesc.contains("cursor not found")
      response.data.messages.len == 0

  asyncTest "a failed dial to the store peer is answered 200 with statusCode 504":
    let node = testWakuNode()
    await node.start()
    defer:
      await node.stop()

    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, Port(0)).tryGet()
    installStoreApiHandlers(restServer.router, node)
    restServer.start()
    defer:
      await restServer.stop()
      await restServer.closeWait()

    node.mountStoreClient()

    let peerSwitch = newStandardSwitch(Opt.some(generateEcdsaKey()))
    await peerSwitch.start()
    defer:
      await peerSwitch.stop()
    node.peerManager.addServicePeer(
      peerSwitch.peerInfo.toRemotePeerInfo(), WakuStoreCodec
    )

    let client =
      newRestHttpClient(initTAddress(restAddress, restServer.httpServer.address.port))

    let response =
      await client.getStoreMessagesV3(pubsubTopic = encodeUrl(DefaultPubsubTopic))
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.statusCode == 504
      response.data.statusDesc.startsWith("PEER_DIAL_FAILURE: ")
      response.data.messages.len == 0

  asyncTest "a query string over the request headers size limit is rejected with 431":
    let t = await RestStoreTest.init()
    defer:
      await t.shutdown()
    let maxHeadersSize = RestServerConf.default().maxRequestHeadersSize * 1024

    let underLimit = await issueRequest(
      t.restServer.getAddress(
        "/store/v3/messages?pubsubTopic=" & 'a'.repeat(maxHeadersSize - 1024)
      )
    )
    let overLimit = await issueRequest(
      t.restServer.getAddress(
        "/store/v3/messages?pubsubTopic=" & 'a'.repeat(maxHeadersSize)
      )
    )
    check:
      underLimit.status == 200
      overLimit.status == 431

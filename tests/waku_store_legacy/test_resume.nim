{.used.}

when defined(waku_exp_store_resume):
  # TODO: Review store resume test cases (#1282)
  # Ongoing changes to test code base had ruin this test meanwhile, need to investigate and fix

  import
    std/[options, tables, sets],
    testutils/unittests,
    chronos,
    chronicles,
    libp2p/crypto/crypto
  import
    waku/[
      common/databases/db_sqlite,
      waku_archive_legacy/driver,
      waku_archive_legacy/driver/sqlite_driver/sqlite_driver,
      node/peer_manager,
      waku_core,
      waku_core/message/digest,
      waku_store_legacy,
    ],
    ../waku_store_legacy/store_utils,
    ../waku_archive_legacy/archive_utils,
    ./testlib/common,
    ./testlib/switch

  procSuite "Waku Store - resume store":
    ## Fixtures
    let storeA = block:
      let store = newTestMessageStore()
      let msgList = @[
        fakeWakuMessage(
          payload = @[byte 0], contentTopic = ContentTopic("2"), ts = ts(0)
        ),
        fakeWakuMessage(
          payload = @[byte 1], contentTopic = ContentTopic("1"), ts = ts(1)
        ),
        fakeWakuMessage(
          payload = @[byte 2], contentTopic = ContentTopic("2"), ts = ts(2)
        ),
        fakeWakuMessage(
          payload = @[byte 3], contentTopic = ContentTopic("1"), ts = ts(3)
        ),
        fakeWakuMessage(
          payload = @[byte 4], contentTopic = ContentTopic("2"), ts = ts(4)
        ),
        fakeWakuMessage(
          payload = @[byte 5], contentTopic = ContentTopic("1"), ts = ts(5)
        ),
        fakeWakuMessage(
          payload = @[byte 6], contentTopic = ContentTopic("2"), ts = ts(6)
        ),
        fakeWakuMessage(
          payload = @[byte 7], contentTopic = ContentTopic("1"), ts = ts(7)
        ),
        fakeWakuMessage(
          payload = @[byte 8], contentTopic = ContentTopic("2"), ts = ts(8)
        ),
        fakeWakuMessage(
          payload = @[byte 9], contentTopic = ContentTopic("1"), ts = ts(9)
        ),
      ]

      for msg in msgList:
        require store
          .put(
            DefaultPubsubTopic,
            msg,
            computeDigest(msg),
            computeMessageHash(DefaultPubsubTopic, msg),
            msg.timestamp,
          )
          .isOk()

      store

    let storeB = block:
      let store = newTestMessageStore()
      let msgList2 = @[
        fakeWakuMessage(
          payload = @[byte 0], contentTopic = ContentTopic("2"), ts = ts(0)
        ),
        fakeWakuMessage(
          payload = @[byte 11], contentTopic = ContentTopic("1"), ts = ts(1)
        ),
        fakeWakuMessage(
          payload = @[byte 12], contentTopic = ContentTopic("2"), ts = ts(2)
        ),
        fakeWakuMessage(
          payload = @[byte 3], contentTopic = ContentTopic("1"), ts = ts(3)
        ),
        fakeWakuMessage(
          payload = @[byte 4], contentTopic = ContentTopic("2"), ts = ts(4)
        ),
        fakeWakuMessage(
          payload = @[byte 5], contentTopic = ContentTopic("1"), ts = ts(5)
        ),
        fakeWakuMessage(
          payload = @[byte 13], contentTopic = ContentTopic("2"), ts = ts(6)
        ),
        fakeWakuMessage(
          payload = @[byte 14], contentTopic = ContentTopic("1"), ts = ts(7)
        ),
      ]

      for msg in msgList2:
        require store
          .put(
            DefaultPubsubTopic,
            msg,
            computeDigest(msg),
            computeMessageHash(DefaultPubsubTopic, msg),
            msg.timestamp,
          )
          .isOk()

      store

    asyncTest "multiple query to multiple peers with pagination":
      ## Setup
      let
        serverSwitchA = newTestSwitch()
        serverSwitchB = newTestSwitch()
        clientSwitch = newTestSwitch()

      await allFutures(
        serverSwitchA.start(), serverSwitchB.start(), clientSwitch.start()
      )

      let
        serverA = await newTestWakuStoreNode(serverSwitchA, store = testStore)
        serverB = await newTestWakuStoreNode(serverSwitchB, store = testStore)
        client = newTestWakuStoreClient(clientSwitch)

      ## Given
      let peers = @[
        serverSwitchA.peerInfo.toRemotePeerInfo(),
        serverSwitchB.peerInfo.toRemotePeerInfo(),
      ]
      let req = HistoryQuery(contentTopics: @[DefaultContentTopic], pageSize: 5)

      ## When
      let res = await client.queryLoop(req, peers)

      ## Then
      check:
        res.isOk()

      let response = res.tryGet()
      check:
        response.len == 10

      ## Cleanup
      await allFutures(clientSwitch.stop(), serverSwitchA.stop(), serverSwitchB.stop())

    asyncTest "resume message history":
      ## Setup
      let
        serverSwitch = newTestSwitch()
        clientSwitch = newTestSwitch()

      await allFutures(serverSwitch.start(), clientSwitch.start())

      let
        server = await newTestWakuStore(serverSwitch, store = storeA)
        client = await newTestWakuStore(clientSwitch)

      client.setPeer(serverSwitch.peerInfo.toRemotePeerInfo())

      ## When
      let res = await client.resume()

      ## Then
      check res.isOk()

      let resumedMessagesCount = res.tryGet()
      let storedMessagesCount = client.store.getMessagesCount().tryGet()
      check:
        resumedMessagesCount == 10
        storedMessagesCount == 10

      ## Cleanup
      await allFutures(clientSwitch.stop(), serverSwitch.stop())

    asyncTest "resume history from a list of candidates - offline peer":
      ## Setup
      let
        clientSwitch = newTestSwitch()
        offlineSwitch = newTestSwitch()

      await clientSwitch.start()

      let client = await newTestWakuStore(clientSwitch)

      ## Given
      let peers = @[offlineSwitch.peerInfo.toRemotePeerInfo()]

      ## When
      let res = await client.resume(some(peers))

      ## Then
      check res.isErr()

      ## Cleanup
      await clientSwitch.stop()

    asyncTest "resume history from a list of candidates - online and offline peers":
      ## Setup
      let
        offlineSwitch = newTestSwitch()
        serverASwitch = newTestSwitch()
        serverBSwitch = newTestSwitch()
        clientSwitch = newTestSwitch()

      await allFutures(
        serverASwitch.start(), serverBSwitch.start(), clientSwitch.start()
      )

      let
        serverA = await newTestWakuStore(serverASwitch, store = storeA)
        serverB = await newTestWakuStore(serverBSwitch, store = storeB)
        client = await newTestWakuStore(clientSwitch)

      ## Given
      let peers = @[
        offlineSwitch.peerInfo.toRemotePeerInfo(),
        serverASwitch.peerInfo.toRemotePeerInfo(),
        serverBSwitch.peerInfo.toRemotePeerInfo(),
      ]

      ## When
      let res = await client.resume(some(peers))

      ## Then
      # `client` is expected to retrieve 14 messages:
      # - The store mounted on `serverB` holds 10 messages (see `storeA` fixture)
      # - The store mounted on `serverB` holds 7 messages (see `storeB` fixture)
      # Both stores share 3 messages, resulting in 14 unique messages in total
      check res.isOk()

      let restoredMessagesCount = res.tryGet()
      let storedMessagesCount = client.store.getMessagesCount().tryGet()
      check:
        restoredMessagesCount == 14
        storedMessagesCount == 14

      ## Cleanup
      await allFutures(serverASwitch.stop(), serverBSwitch.stop(), clientSwitch.stop())

  suite "WakuNode - waku store":
    asyncTest "Resume proc fetches the history":
      ## Setup
      let
        serverKey = generateSecp256k1Key()
        server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
        clientKey = generateSecp256k1Key()
        client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

      await allFutures(client.start(), server.start())

      let driver = newSqliteArchiveDriver()
      server.mountArchive(some(driver), none(MessageValidator), none(RetentionPolicy))
      await server.mountStore()

      let clientStore = StoreQueueRef.new()
      await client.mountStore(store = clientStore)
      client.mountStoreClient(store = clientStore)

      ## Given
      let message = fakeWakuMessage()
      require server.wakuStore.store.put(DefaultPubsubTopic, message).isOk()

      let serverPeer = server.peerInfo.toRemotePeerInfo()

      ## When
      await client.resume(some(@[serverPeer]))

      # Then
      check:
        client.wakuStore.store.getMessagesCount().tryGet() == 1

      ## Cleanup
      await allFutures(client.stop(), server.stop())

    asyncTest "Resume proc discards duplicate messages":
      ## Setup
      let
        serverKey = generateSecp256k1Key()
        server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
        clientKey = generateSecp256k1Key()
        client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

      await allFutures(server.start(), client.start())
      await server.mountStore(store = StoreQueueRef.new())

      let clientStore = StoreQueueRef.new()
      await client.mountStore(store = clientStore)
      client.mountStoreClient(store = clientStore)

      ## Given
      let timeOrigin = now()
      let
        msg1 = fakeWakuMessage(
          payload = "hello world1", ts = (timeOrigin + getNanoSecondTime(1))
        )
        msg2 = fakeWakuMessage(
          payload = "hello world2", ts = (timeOrigin + getNanoSecondTime(2))
        )
        msg3 = fakeWakuMessage(
          payload = "hello world3", ts = (timeOrigin + getNanoSecondTime(3))
        )

      require server.wakuStore.store.put(DefaultPubsubTopic, msg1).isOk()
      require server.wakuStore.store.put(DefaultPubsubTopic, msg2).isOk()

      # Insert the same message in both node's store
      let
        receivedTime3 = now() + getNanosecondTime(10)
        digest3 = computeDigest(msg3)
      require server.wakuStore.store
        .put(DefaultPubsubTopic, msg3, digest3, receivedTime3)
        .isOk()
      require client.wakuStore.store
        .put(DefaultPubsubTopic, msg3, digest3, receivedTime3)
        .isOk()

      let serverPeer = server.peerInfo.toRemotePeerInfo()

      ## When
      await client.resume(some(@[serverPeer]))

      ## Then
      check:
        # If the duplicates are discarded properly, then the total number of messages after resume should be 3
        client.wakuStore.store.getMessagesCount().tryGet() == 3

      await allFutures(client.stop(), server.stop())

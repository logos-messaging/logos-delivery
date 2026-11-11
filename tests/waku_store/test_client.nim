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

type FakeStore = ref object ## A store node that counts its queries.
  switch: Switch
  queries: int
  failing: bool ## answers with an error
  allowAnswer: Future[void] ## answers after it completes, nil for no wait

proc newFakeStore(): Future[FakeStore] {.async.} =
  let store = FakeStore(switch: newTestSwitch())
  let handler = proc(
      req: StoreQueryRequest
  ): Future[StoreQueryResult] {.async, gcsafe.} =
    inc store.queries
    if not store.allowAnswer.isNil():
      await store.allowAnswer
    if store.failing:
      return err(StoreError(kind: ErrorCode.BAD_REQUEST, cause: "test"))
    return ok(StoreQueryResponse())
  discard await newTestWakuStore(store.switch, handler = handler)
  await store.switch.start()
  return store

proc addStorePeer(client: Switch, store: FakeStore, shards: seq[uint16] = @[]) =
  ## Makes `store` a known store peer of `client`. With `shards`, the peer
  ## announced them.
  let peerInfo = store.switch.peerInfo.toRemotePeerInfo()
  peerInfo.protocols = @[WakuStoreCodec]
  client.peerStore.addPeer(peerInfo)
  if shards.len > 0:
    client.peerStore.setShardInfo(peerInfo.peerId, shards)

proc connectTo(client: Switch, store: FakeStore) {.async.} =
  await client.connect(store.switch.peerInfo.peerId, store.switch.peerInfo.addrs)

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

    asyncTest "queryToAny asks a connected store peer of the shard first":
      # Five store peers announced the shard of the query, and one announced
      # another shard. The client has a connection to one peer of the shard
      # and to the peer of the other shard.
      let shard = RelayShard.parse(DefaultPubsubTopic).get().shardId
      let connectedStore = await newFakeStore()
      let otherShardStore = await newFakeStore()
      var notConnectedStores: seq[FakeStore]
      for _ in 0 ..< 4:
        notConnectedStores.add(await newFakeStore())
      defer:
        await allFutures(
          @[connectedStore.switch.stop(), otherShardStore.switch.stop()] &
            notConnectedStores.mapIt(it.switch.stop())
        )
      clientSwitch.addStorePeer(connectedStore, @[shard])
      clientSwitch.addStorePeer(otherShardStore, @[shard + 1])
      for store in notConnectedStores:
        clientSwitch.addStorePeer(store, @[shard])
      await clientSwitch.connectTo(connectedStore)
      await clientSwitch.connectTo(otherShardStore)
      proc notConnectedQueries(): int =
        notConnectedStores.mapIt(it.queries).foldl(a + b, 0)

      # Queries at the same time use the same connection.
      connectedStore.allowAnswer = newFuture[void]("allow answer")
      var atTheSameTime: seq[Future[StoreQueryResult]]
      for _ in 0 ..< 8:
        atTheSameTime.add(client.queryToAny(storeQuery))
      connectedStore.allowAnswer.complete()
      for query in atTheSameTime:
        check (await query).isOk()
      check:
        connectedStore.queries == 8
        notConnectedQueries() == 0

      # A query with only hashes has its shard in the `shards` argument.
      # Without the argument, the choice is random among the six peers.
      let hashQuery = StoreQueryRequest(messageHashes: @[hash1])
      for i in 0 ..< 10:
        let response =
          if i mod 2 == 0:
            await client.queryToAny(storeQuery)
          else:
            await client.queryToAny(hashQuery, shards = @[DefaultPubsubTopic])
        check response.isOk()
      check:
        connectedStore.queries == 18
        notConnectedQueries() == 0
        otherShardStore.queries == 0

      # A query fails on the connected peer, and another peer of the shard
      # answers it. The peer that failed is last in the next queries, so it
      # gets no query.
      connectedStore.failing = true
      check (await client.queryToAny(storeQuery)).isOk()
      connectedStore.failing = false
      check connectedStore.queries == 19
      for _ in 0 ..< 20:
        check (await client.queryToAny(storeQuery)).isOk()
      check:
        connectedStore.queries == 19
        otherShardStore.queries == 0

      # The four other peers of the shard fail a query, so the query gets to
      # the last peer, which answers. That success ends its backoff. It is
      # then the only peer of the shard that is not in a backoff.
      for store in notConnectedStores:
        store.failing = true
      check (await client.queryToAny(storeQuery)).isOk()
      for store in notConnectedStores:
        store.failing = false
      check connectedStore.queries == 20
      let otherQueries = notConnectedQueries()
      for _ in 0 ..< 10:
        check (await client.queryToAny(storeQuery)).isOk()
      check:
        connectedStore.queries == 30
        notConnectedQueries() == otherQueries

      # A backoff also ends after `failedPeerBackoff`. The four peers are then
      # of the same rank as the connected peer again.
      client.failedPeerBackoff = chronos.milliseconds(100)
      await sleepAsync(chronos.milliseconds(200))
      for _ in 0 ..< 30:
        check (await client.queryToAny(storeQuery)).isOk()
      check:
        notConnectedQueries() > otherQueries
        otherShardStore.queries == 0

    asyncTest "queryToAny asks a store peer with no known shards, and asks last a peer that did not answer":
      let clusterId = RelayShard.parse(DefaultPubsubTopic).get().clusterId
      let shard = RelayShard.parse(DefaultPubsubTopic).get().shardId
      let noShardsStore = await newFakeStore()
      let otherShardStore = await newFakeStore()
      let ofShardStore = await newFakeStore()
      defer:
        await allFutures(
          noShardsStore.switch.stop(),
          otherShardStore.switch.stop(),
          ofShardStore.switch.stop(),
        )

      # A peer with no known shards can have the shard. A peer that announced
      # another shard cannot.
      clientSwitch.addStorePeer(noShardsStore)
      clientSwitch.addStorePeer(otherShardStore, @[shard + 1])
      await clientSwitch.connectTo(noShardsStore)
      await clientSwitch.connectTo(otherShardStore)
      for _ in 0 ..< 4:
        check (await client.queryToAny(storeQuery)).isOk()
      # It can have each shard, so one query can ask it about two shards. The
      # other peer announced only one of the two, so it gets no such query.
      let otherTopic =
        PubsubTopic($RelayShard(clusterId: clusterId, shardId: shard + 1))
      let topics = @[DefaultPubsubTopic, otherTopic]
      for _ in 0 ..< 5:
        check (
          await client.queryToAny(
            StoreQueryRequest(messageHashes: @[hash1]), shards = topics
          )
        ).isOk()
      check:
        noShardsStore.queries == 9
        otherShardStore.queries == 0

      # The connected peer does not answer in the timeout of the query.
      # The next queries go to the other connected peer of the shard.
      clientSwitch.addStorePeer(ofShardStore, @[shard])
      noShardsStore.allowAnswer = newFuture[void]("allow answer")
      let noAnswer = await client.queryToAny(storeQuery, timeout = 300.milliseconds)
      check noAnswer.isErr()
      noShardsStore.allowAnswer.complete()
      await clientSwitch.connectTo(ofShardStore)
      for _ in 0 ..< 5:
        check (await client.queryToAny(storeQuery)).isOk()
      check:
        noShardsStore.queries == 10
        ofShardStore.queries == 5
        otherShardStore.queries == 0

    asyncTest "queryToAny counts no failure of a store peer when the caller cancels the query":
      ## A service that stops cancels its Store query.
      ## The store peer did not fail, so the next queries must still use its connection.
      let shard = RelayShard.parse(DefaultPubsubTopic).get().shardId
      let connectedStore = await newFakeStore()
      let notConnectedStore = await newFakeStore()
      defer:
        await allFutures(connectedStore.switch.stop(), notConnectedStore.switch.stop())
      clientSwitch.addStorePeer(connectedStore, @[shard])
      clientSwitch.addStorePeer(notConnectedStore, @[shard])
      await clientSwitch.connectTo(connectedStore)

      connectedStore.allowAnswer = newFuture[void]("allow answer")
      let query = client.queryToAny(storeQuery)
      checkUntilTimeout:
        connectedStore.queries == 1
      await query.cancelAndWait()
      connectedStore.allowAnswer.complete()

      for _ in 0 ..< 5:
        check (await client.queryToAny(storeQuery)).isOk()
      check:
        connectedStore.queries == 6
        notConnectedStore.queries == 0

    asyncTest "queryToAny asks only the exclusive store peers":
      let peerManager = PeerManager.new(clientSwitch)
      let exclusiveClient = WakuStoreClient.new(peerManager, crypto.newRng())
      for _ in 0 ..< 3:
        let discovered = newTestSwitch().peerInfo.toRemotePeerInfo()
        discovered.protocols = @[WakuStoreCodec]
        clientSwitch.peerStore.addPeer(discovered)
      let exclusive = newTestSwitch().peerInfo.toRemotePeerInfo()
      peerManager.setExclusivePeers(WakuStoreCodec, @[exclusive])

      for _ in 0 ..< 5:
        let res = await exclusiveClient.queryToAny(storeQuery)
        check:
          res.isErr()
          res.error.kind == ErrorCode.PEER_DIAL_FAILURE
          res.error.address == $exclusive

      # A connection gives no preference among the exclusive store peers.
      let connectedStore = await newFakeStore()
      let notConnectedStore = await newFakeStore()
      defer:
        await allFutures(connectedStore.switch.stop(), notConnectedStore.switch.stop())
      peerManager.setExclusivePeers(
        WakuStoreCodec,
        @[
          connectedStore.switch.peerInfo.toRemotePeerInfo(),
          notConnectedStore.switch.peerInfo.toRemotePeerInfo(),
        ],
      )
      await clientSwitch.connectTo(connectedStore)
      for _ in 0 ..< 30:
        check (await exclusiveClient.queryToAny(storeQuery)).isOk()
      check:
        connectedStore.queries > 0
        notConnectedStore.queries > 0

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
        let buf = await conn.readLp(DefaultMaxQuerySize)
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

suite "Store Client - response size":
  asyncTest "the client reads a response up to its own limit":
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    proc reply(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
      try:
        let buf = await conn.readLp(DefaultMaxQuerySize)
        let req = StoreQueryRequest.decode(buf).valueOr:
          return
        let message = fakeWakuMessage(payload = newSeq[byte](2000))
        let resp = StoreQueryResponse(
          requestId: req.requestId,
          statusCode: uint32(StatusCode.SUCCESS),
          messages: @[
            WakuMessageKeyValue(
              messageHash: computeMessageHash(DefaultPubsubTopic, message),
              message: Opt.some(message),
              pubsubTopic: Opt.some(DefaultPubsubTopic),
            )
          ],
        )
        await conn.writeLp(resp.encode())
      except LPStreamError:
        return

    serverSwitch.mount(LPProtocol.new(codecs = @[WakuStoreCodec], handler = reply))
    await allFutures(serverSwitch.start(), clientSwitch.start())
    let
      serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
      peerManager = PeerManager.new(clientSwitch)
      small = WakuStoreClient.new(peerManager, crypto.newRng(), maxResponseSize = 1000)
      default = WakuStoreClient.new(peerManager, crypto.newRng())
      request = StoreQueryRequest(contentTopics: @[DefaultContentTopic])

    let tooLarge = await small.query(request, peer = serverPeerInfo)
    let fits = await default.query(request, peer = serverPeerInfo)
    check:
      tooLarge.isErr()
      tooLarge.error.kind == ErrorCode.BAD_RESPONSE
      fits.isOk()

    await allFutures(clientSwitch.stop(), serverSwitch.stop())

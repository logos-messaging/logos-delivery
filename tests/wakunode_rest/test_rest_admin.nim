{.used.}

import
  std/[sequtils, net],
  testutils/unittests,
  presto,
  presto/client as presto_client,
  presto /../ tests/helpers,
  libp2p/crypto/crypto

import
  waku/[
    waku_core,
    waku_node,
    waku_filter_v2/client,
    node/peer_manager,
    rest_api/endpoint/server,
    rest_api/endpoint/client,
    rest_api/endpoint/responses,
    rest_api/endpoint/admin/types,
    rest_api/endpoint/admin/handlers as admin_rest_interface,
    rest_api/endpoint/admin/client as admin_rest_client,
    waku_relay,
    waku_peer_exchange,
  ],
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../testlib/testasync

suite "Waku v2 Rest API - Admin":
  var node1 {.threadvar.}: WakuNode
  var node2 {.threadvar.}: WakuNode
  var node3 {.threadvar.}: WakuNode
  var peerInfo1 {.threadvar.}: RemotePeerInfo
  var peerInfo2 {.threadvar.}: RemotePeerInfo
  var peerInfo3 {.threadvar.}: RemotePeerInfo
  var restServer {.threadvar.}: WakuRestServerRef
  var client {.threadvar.}: RestClientRef

  asyncSetup:
    node1 = newTestWakuNode(generateSecp256k1Key(), getPrimaryIPAddr(), Port(60600))
    node2 = newTestWakuNode(generateSecp256k1Key(), getPrimaryIPAddr(), Port(60602))
    node3 = newTestWakuNode(generateSecp256k1Key(), getPrimaryIPAddr(), Port(60604))

    let clusterId = 1.uint16
    let shards: seq[uint16] = @[0]
    node1.mountMetadata(clusterId, shards).isOkOr:
      assert false, "Failed to mount metadata: " & $error
    node2.mountMetadata(clusterId, shards).isOkOr:
      assert false, "Failed to mount metadata: " & $error
    node3.mountMetadata(clusterId, shards).isOkOr:
      assert false, "Failed to mount metadata: " & $error

    await allFutures(node1.start(), node2.start(), node3.start())
    await allFutures(
      node1.mountRelay(),
      node2.mountRelay(),
      node3.mountRelay(),
      node3.mountPeerExchange(),
    )

    # The three nodes should be subscribed to the same shard
    proc simpleHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    let shard = RelayShard(clusterId: clusterId, shardId: 5)
    node1.subscribe((kind: PubsubSub, topic: $shard), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to topic: " & $error
    node2.subscribe((kind: PubsubSub, topic: $shard), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to topic: " & $error
    node3.subscribe((kind: PubsubSub, topic: $shard), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to topic: " & $error

    peerInfo1 = node1.switch.peerInfo
    peerInfo2 = node2.switch.peerInfo
    peerInfo3 = node3.switch.peerInfo

    var restPort = Port(0)
    let restAddress = parseIpAddress("127.0.0.1")
    restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installAdminApiHandlers(restServer.router, node1)

    restServer.start()

    client = newRestHttpClient(initTAddress(restAddress, restPort))

  asyncTearDown:
    await restServer.stop()
    await restServer.closeWait()
    await allFutures(node1.stop(), node2.stop(), node3.stop())

  asyncTest "Set and get remote peers":
    # Connect to nodes 2 and 3 using the Admin API
    let postRes = await client.postPeers(
      @[constructMultiaddrStr(peerInfo2), constructMultiaddrStr(peerInfo3)]
    )

    check:
      postRes.status == 200

    # Verify that newly connected peers are being managed
    let getRes = await client.getPeers()

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 2
      # Check peer 2
      getRes.data.anyIt(
        it.protocols.find(WakuRelayCodec) >= 0 and
          it.multiaddr == constructMultiaddrStr(peerInfo2)
      )
      # Check peer 3
      getRes.data.anyIt(
        it.protocols.find(WakuRelayCodec) >= 0 and
          it.multiaddr == constructMultiaddrStr(peerInfo3)
      )

      # Check peer 3
      getRes.data.anyIt(
        it.protocols.find(WakuPeerExchangeCodec) >= 0 and
          it.multiaddr == constructMultiaddrStr(peerInfo3)
      )

  asyncTest "Set wrong peer":
    let nonExistentPeer =
      "/ip4/0.0.0.0/tcp/10000/p2p/16Uiu2HAm6HZZr7aToTvEBPpiys4UxajCTU97zj5v7RNR2gbniy1D"
    let postRes = await client.postPeers(@[nonExistentPeer])

    check:
      postRes.status == 400
      $postRes.contentType == $MIMETYPE_TEXT
      postRes.data == "Failed to connect to peer at index: 0 - " & nonExistentPeer

    # Verify that newly connected peers are being managed
    let getRes = await client.getPeers()

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 1
      getRes.data[0].multiaddr == nonExistentPeer
      getRes.data[0].connected == CannotConnect

  asyncTest "Get filter data":
    await allFutures(
      node1.mountFilter(), node2.mountFilterClient(), node3.mountFilterClient()
    )

    let
      contentFiltersNode2 = @[DefaultContentTopic, ContentTopic("2"), ContentTopic("3")]
      contentFiltersNode3 = @[ContentTopic("3"), ContentTopic("4")]
      pubsubTopicNode2 = DefaultPubsubTopic
      pubsubTopicNode3 = PubsubTopic("/waku/2/custom-waku/proto")

    let
      subscribeResponse2 = await node2.wakuFilterClient.subscribe(
        peerInfo1, pubsubTopicNode2, contentFiltersNode2
      )
      subscribeResponse3 = await node3.wakuFilterClient.subscribe(
        peerInfo1, pubsubTopicNode3, contentFiltersNode3
      )

    assert subscribeResponse2.isOk(), $subscribeResponse2.error
    assert subscribeResponse3.isOk(), $subscribeResponse3.error

    let getRes = await client.getFilterSubscriptions()

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 2

    let
      peers = @[getRes.data[0].peerId, getRes.data[1].peerId]
      numCriteria =
        @[getRes.data[0].filterCriteria.len, getRes.data[1].filterCriteria.len]

    check:
      $peerInfo2 in peers
      $peerInfo3 in peers
      2 in numCriteria
      3 in numCriteria

  asyncTest "Get filter data - no filter subscribers":
    await node1.mountFilter()

    let getRes = await client.getFilterSubscriptions()

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 0

  asyncTest "Get filter data - filter not mounted":
    let getRes = await client.getFilterSubscriptionsFilterNotMounted()

    check:
      getRes.status == 400
      getRes.data == "Error: Filter Protocol is not mounted to the node"

  asyncTest "Get peer origin":
    # Adding peers to the Peer Store
    node1.peerManager.addPeer(peerInfo2, Discv5)
    node1.peerManager.addPeer(peerInfo3, PeerExchange)

    # Connecting to both peers
    let conn2 = await node1.peerManager.connectPeer(peerInfo2)
    let conn3 = await node1.peerManager.connectPeer(peerInfo3)

    var count = 0
    while count < 20:
      ## Wait ~1s at most for the peer store to update shard info
      let getRes = await client.getPeers()
      if getRes.data.allIt(it.shards == @[5.uint16]):
        break

      count.inc()
      await sleepAsync(50.milliseconds)

    assert count < 20, "Timeout waiting for shards to be updated in peer store"

    # Check successful connections
    check:
      conn2 == true
      conn3 == true

    # Query peers REST endpoint
    let getRes = await client.getPeers()

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 2
      # Check peer 2
      getRes.data.anyIt(it.origin == Discv5)
      # Check peer 3
      getRes.data.anyIt(it.origin == PeerExchange)

  asyncTest "get peers by id":
    # Connect to nodes 2 and 3 using the Admin API
    let postRes = await client.postPeers(
      @[constructMultiaddrStr(peerInfo2), constructMultiaddrStr(peerInfo3)]
    )

    check:
      postRes.status == 200

    let getRes = await client.getPeerById($peerInfo2.peerId)

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.protocols.find(WakuRelayCodec) >= 0
      getRes.data.multiaddr == constructMultiaddrStr(peerInfo2)

    ## nim-presto library's RestClient does not support text error case decode if
    ## the RestResponse expects a JSON with complex type
    # let getRes2 = await client.getPeerById("bad peer id")
    let getRes2 = await httpClient(
      restServer.httpServer.address, MethodGet, "/admin/v1/peer/bad+peer+id", ""
    )
    check:
      getRes2.status == 400
      getRes2.data == "Invalid argument:peerid: incorrect PeerId string"

  asyncTest "get connected peers":
    # Connect to nodes 2 and 3 using the Admin API
    let postRes = await client.postPeers(
      @[constructMultiaddrStr(peerInfo2), constructMultiaddrStr(peerInfo3)]
    )

    check:
      postRes.status == 200

    let getRes = await client.getConnectedPeers()

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 2
      # Check peer 2
      getRes.data.anyIt(it.multiaddr == constructMultiaddrStr(peerInfo2))
      # Check peer 3
      getRes.data.anyIt(it.multiaddr == constructMultiaddrStr(peerInfo3))

    # Seems shard info is not available in the peer manager
    # let getRes2 = await client.getConnectedPeersByShard(0)
    # check:
    #   getRes2.status == 200
    #   $getRes2.contentType == $MIMETYPE_JSON
    #   getRes2.data.len() == 2

    let getRes3 = await client.getConnectedPeersByShard(99)
    check:
      getRes3.status == 200
      $getRes3.contentType == $MIMETYPE_JSON
      getRes3.data.len() == 0

  asyncTest "get relay peers":
    # Connect to nodes 2 and 3 using the Admin API
    let postRes = await client.postPeers(
      @[constructMultiaddrStr(peerInfo2), constructMultiaddrStr(peerInfo3)]
    )

    check:
      postRes.status == 200

    let getRes = await client.getRelayPeers()

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
    require getRes.data.len() == 1 # Check peer 2
    check getRes.data[0].peers.anyIt(it.multiaddr == constructMultiaddrStr(peerInfo2))
      # Check peer 2
    check getRes.data[0].peers.anyIt(it.multiaddr == constructMultiaddrStr(peerInfo3))
      # Check peer 3

    # Todo: investigate why the test setup missing remote peer's shard info
    # let getRes2 = await client.getRelayPeersByShard(0)
    # check:
    #   getRes2.status == 200
    #   $getRes2.contentType == $MIMETYPE_JSON
    #   getRes2.data.peers.len() == 2

    let getRes3 = await client.getRelayPeersByShard(99)
    check:
      getRes3.status == 200
      $getRes3.contentType == $MIMETYPE_JSON
      getRes3.data.peers.len() == 0

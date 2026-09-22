{.used.}

import
  std/[algorithm, sequtils, sets, strutils, tables, net],
  chronicles,
  chronicles/topics_registry,
  testutils/unittests,
  presto,
  presto/client as presto_client,
  libp2p/crypto/crypto

import
  logos_delivery/waku/[
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
    waku_archive,
    waku_archive/driver/queue_driver,
    waku_relay,
    waku_peer_exchange,
    waku_store,
  ],
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../testlib/rest_requests,
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
    node1 = newTestWakuNode(generateSecp256k1Key(), getPrimaryIPAddr(), Port(0))
    node2 = newTestWakuNode(generateSecp256k1Key(), getPrimaryIPAddr(), Port(0))
    node3 = newTestWakuNode(generateSecp256k1Key(), getPrimaryIPAddr(), Port(0))

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

  asyncTest "get peers lists an inbound peer at a port it does not listen on":
    let
      primaryIp = $getPrimaryIPAddr()
      node1TcpAddr =
        "/ip4/" & primaryIp & "/tcp/" & $node1.boundTcpPort() & "/p2p/" &
        $peerInfo1.peerId
      node2ListenAddr =
        "/ip4/" & primaryIp & "/tcp/" & $node2.boundTcpPort() & "/p2p/" &
        $peerInfo2.peerId

    let connected =
      await node2.peerManager.connectPeer(parsePeerInfo(node1TcpAddr).tryGet())

    checkUntilTimeout:
      node1.peerManager.switch.peerStore.isConnected(peerInfo2.peerId)
      node1.peerManager.switch.peerStore.peerExists(peerInfo2.peerId)

    let peersResponse = await client.getPeers()
    let listedAddrs = peersResponse.data.mapIt(it.multiaddr)

    # An inbound peer is listed at the address its connection came from, which nothing listens on.
    check:
      connected
      peersResponse.status == 200
      listedAddrs.len == 1
      listedAddrs.allIt(
        it.startsWith("/ip4/" & primaryIp & "/tcp/") and
          it.endsWith("/p2p/" & $peerInfo2.peerId)
      )
      node2ListenAddr notin listedAddrs

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

    let
      criteriaNode2 = contentFiltersNode2
        .mapIt(FilterTopic(pubsubTopic: pubsubTopicNode2, contentTopic: it))
        .toHashSet()
      criteriaNode3 = contentFiltersNode3
        .mapIt(FilterTopic(pubsubTopic: pubsubTopicNode3, contentTopic: it))
        .toHashSet()
      subscriptions = getRes.data.mapIt((it.peerId, it.filterCriteria.toHashSet()))

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 2
      ($peerInfo2.peerId, criteriaNode2) in subscriptions
      ($peerInfo3.peerId, criteriaNode3) in subscriptions

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

    let getRes2 =
      await issueRequest(restServer.getAddress("/admin/v1/peer/bad+peer+id"))
    check:
      getRes2.status == 400
      getRes2.data == "Invalid argument:peerid: incorrect PeerId string"

    let unknownPeerId = "16Uiu2HAm6HZZr7aToTvEBPpiys4UxajCTU97zj5v7RNR2gbniy1D"
    let getRes3 =
      await issueRequest(restServer.getAddress("/admin/v1/peer/" & unknownPeerId))
    # The message prints the route parameter, a Result, instead of the peer id.
    check:
      getRes3.status == 404
      getRes3.data == "Peer with ID ok(" & unknownPeerId & ") not found"

  asyncTest "get connected peers":
    # Connect to nodes 2 and 3 using the Admin API
    let postRes = await client.postPeers(
      @[constructMultiaddrStr(peerInfo2), constructMultiaddrStr(peerInfo3)]
    )

    check:
      postRes.status == 200

    # A peer in the store that is not connected
    let nonExistentPeer =
      "/ip4/0.0.0.0/tcp/10000/p2p/16Uiu2HAm6HZZr7aToTvEBPpiys4UxajCTU97zj5v7RNR2gbniy1D"
    let failedPostRes = await client.postPeers(@[nonExistentPeer])

    let getRes = await client.getConnectedPeers()
    let getAllRes = await client.getPeers()

    check:
      failedPostRes.status == 400
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 2
      # Check peer 2
      getRes.data.anyIt(it.multiaddr == constructMultiaddrStr(peerInfo2))
      # Check peer 3
      getRes.data.anyIt(it.multiaddr == constructMultiaddrStr(peerInfo3))
      getAllRes.data.anyIt(
        it.multiaddr == nonExistentPeer and it.connected == CannotConnect
      )

    checkUntilTimeout:
      node1.peerManager.getPeer(peerInfo2.peerId).getShards() == @[5.uint16]
      node1.peerManager.getPeer(peerInfo3.peerId).getShards() == @[5.uint16]

    let getRes2 = await client.getConnectedPeersByShard(5)
    check:
      getRes2.status == 200
      $getRes2.contentType == $MIMETYPE_JSON
      getRes2.data.mapIt(it.multiaddr).sorted() ==
        @[constructMultiaddrStr(peerInfo2), constructMultiaddrStr(peerInfo3)].sorted()

    let getRes3 = await client.getConnectedPeersByShard(99)
    check:
      getRes3.status == 200
      $getRes3.contentType == $MIMETYPE_JSON
      getRes3.data.len() == 0

  asyncTest "get relay peers":
    # A peer without relay
    let node4 = newTestWakuNode(generateSecp256k1Key(), getPrimaryIPAddr(), Port(0))
    check node4.mountMetadata(1, @[0.uint16]).isOk()
    await node4.start()
    defer:
      await node4.stop()
    let peerInfo4 = node4.peerInfo.toRemotePeerInfo()

    # Connect to nodes 2, 3 and 4 using the Admin API
    let postRes = await client.postPeers(
      @[
        constructMultiaddrStr(peerInfo2),
        constructMultiaddrStr(peerInfo3),
        constructMultiaddrStr(peerInfo4),
      ]
    )

    check:
      postRes.status == 200

    let shardTopic = $RelayShard(clusterId: 1, shardId: 5)
    checkUntilTimeout:
      node1.hasGossipsubPeer(shardTopic, peerInfo2.peerId)
      node1.hasGossipsubPeer(shardTopic, peerInfo3.peerId)

    let relayPeers =
      @[constructMultiaddrStr(peerInfo2), constructMultiaddrStr(peerInfo3)].sorted()
    let getRes = await client.getRelayPeers()

    check:
      node1.peerManager.switch.peerStore.isConnected(peerInfo4.peerId)
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.mapIt(it.shard) == @[5.uint16]
      getRes.data.mapIt(it.peers.mapIt(it.multiaddr).sorted()) == @[relayPeers]
      getRes.data.allIt(it.peers.allIt(it.score.isSome()))

    let getRes2 = await client.getRelayPeersByShard(5)
    check:
      getRes2.status == 200
      $getRes2.contentType == $MIMETYPE_JSON
      getRes2.data.shard == 5
      getRes2.data.peers.mapIt(it.multiaddr).sorted() == relayPeers

    let getRes3 = await client.getRelayPeersByShard(99)
    check:
      getRes3.status == 200
      $getRes3.contentType == $MIMETYPE_JSON
      getRes3.data.peers.len() == 0

  asyncTest "get mesh peers":
    # Connect to nodes 2 and 3 using the Admin API
    let postResponse = await client.postPeers(
      @[constructMultiaddrStr(peerInfo2), constructMultiaddrStr(peerInfo3)]
    )

    check:
      postResponse.status == 200

    let pubsubTopic = $RelayShard(clusterId: 1, shardId: 5)
    checkUntilTimeout:
      node1.wakuRelay.hasMeshPeer(pubsubTopic, peerInfo2.peerId)
      node1.wakuRelay.hasMeshPeer(pubsubTopic, peerInfo3.peerId)

    let meshPeerMultiaddrs =
      @[constructMultiaddrStr(peerInfo2), constructMultiaddrStr(peerInfo3)].sorted()
    let meshPeersOnShardResponse = await client.getMeshPeersByShard(5)
    let meshPeersResponse = await client.getMeshPeers()

    check:
      meshPeersOnShardResponse.status == 200
      $meshPeersOnShardResponse.contentType == $MIMETYPE_JSON
      meshPeersOnShardResponse.data.shard == 5
      meshPeersOnShardResponse.data.peers.mapIt(it.multiaddr).sorted() ==
        meshPeerMultiaddrs
      meshPeersOnShardResponse.data.peers.allIt(it.score.isSome())
      meshPeersResponse.status == 200
      $meshPeersResponse.contentType == $MIMETYPE_JSON
      meshPeersResponse.data.mapIt(it.shard) == @[5.uint16]
      meshPeersResponse.data.mapIt(it.peers.mapIt(it.multiaddr).sorted()) ==
        @[meshPeerMultiaddrs]

  asyncTest "get peers stats":
    # Connect to nodes 2 and 3 using the Admin API
    let postResponse = await client.postPeers(
      @[constructMultiaddrStr(peerInfo2), constructMultiaddrStr(peerInfo3)]
    )

    check:
      postResponse.status == 200

    let pubsubTopic = $RelayShard(clusterId: 1, shardId: 5)
    checkUntilTimeout:
      node1.hasGossipsubPeer(pubsubTopic, peerInfo2.peerId)
      node1.hasGossipsubPeer(pubsubTopic, peerInfo3.peerId)

    let peerStatsResponse = await client.getPeersStats()
    let peerStats = peerStatsResponse.data

    check:
      peerStatsResponse.status == 200
      $peerStatsResponse.contentType == $MIMETYPE_JSON
      peerStats.getOrDefault("Sum") == {"Total peers": 2}.toOrderedTable()
      peerStats.getOrDefault("By Connectedness").getOrDefault($Connected) == 2
      peerStats.getOrDefault("Relay peers") ==
        {"5": 2, "Total relay peers": 2}.toOrderedTable()
      peerStats.getOrDefault("By Protocols").getOrDefault(WakuRelayCodec) == 2

  asyncTest "get service peers":
    check node3.mountArchive(QueueDriver.new()).isOk()
    await node3.mountStore()

    # Connect to nodes 2 and 3 using the Admin API
    let postResponse = await client.postPeers(
      @[constructMultiaddrStr(peerInfo2), constructMultiaddrStr(peerInfo3)]
    )

    check:
      postResponse.status == 200

    let servicePeersResponse = await client.getServicePeers()

    check:
      servicePeersResponse.status == 200
      $servicePeersResponse.contentType == $MIMETYPE_JSON
      servicePeersResponse.data.len() == 2
      servicePeersResponse.data.anyIt(
        it.protocols.find(WakuRelayCodec) >= 0 and
          it.multiaddr == constructMultiaddrStr(peerInfo2)
      )
      servicePeersResponse.data.anyIt(
        it.protocols.find(WakuStoreCodec) >= 0 and
          it.multiaddr == constructMultiaddrStr(peerInfo3)
      )

  asyncTest "set log level":
    for level in enabledLogLevel .. LogLevel.FATAL:
      let logLevelResponse = await issueRequest(
        restServer.getAddress("/admin/v1/log-level/" & $level), MethodPost
      )
      check:
        logLevelResponse.status == 200
        topicsMatch(level, []) != 0
        topicsMatch(pred(level), []) == 0

    for level in LogLevel.TRACE ..< enabledLogLevel:
      let logLevelResponse = await issueRequest(
        restServer.getAddress("/admin/v1/log-level/" & $level), MethodPost
      )
      check:
        logLevelResponse.status == 400

    let invalidLogLevelResponse = await issueRequest(
      restServer.getAddress("/admin/v1/log-level/random"), MethodPost
    )
    check:
      invalidLogLevelResponse.status == 400
      invalidLogLevelResponse.data ==
        "Invalid log-level: random. Please specify one of TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL"

    # Restore the log level for the tests that follow.
    discard await issueRequest(
      restServer.getAddress("/admin/v1/log-level/" & $enabledLogLevel), MethodPost
    )

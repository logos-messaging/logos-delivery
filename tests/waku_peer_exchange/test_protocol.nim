{.used.}

import
  std/[options, sequtils, net],
  testutils/unittests,
  chronos,
  libp2p/[switch, peerId, crypto/crypto],
  eth/[keys, p2p/discoveryv5/enr]

import
  waku/[
    waku_node,
    node/peer_manager,
    discovery/waku_discv5,
    waku_peer_exchange,
    waku_peer_exchange/rpc,
    waku_peer_exchange/rpc_codec,
    waku_peer_exchange/protocol,
    waku_peer_exchange/client,
    waku_core,
    common/enr/builder,
    waku_enr/sharding,
  ],
  ../testlib/[wakucore, wakunode, assertions],
  ./utils.nim

suite "Waku Peer Exchange":
  # Some of this tests use node.wakuPeerExchange instead of just a standalone PeerExchange.
  # This is because attempts to connect the switches for two standalones PeerExchanges failed.
  # TODO: Try to make the tests work with standalone PeerExchanges

  suite "request":
    asyncTest "Retrieve and provide peer exchange peers from discv5":
      ## Given (copied from test_waku_discv5.nim)
      let
        # todo: px flag
        flags = CapabilitiesBitfield.init(
          lightpush = false, filter = false, store = false, relay = true
        )
        bindIp = parseIpAddress("0.0.0.0")
        extIp = parseIpAddress("127.0.0.1")

        nodeKey1 = generateSecp256k1Key()
        nodeTcpPort1 = Port(64010)
        nodeUdpPort1 = Port(9000)
        node1 = newTestWakuNode(
          nodeKey1,
          bindIp,
          nodeTcpPort1,
          some(extIp),
          wakuFlags = some(flags),
          discv5UdpPort = some(nodeUdpPort1),
        )

        nodeKey2 = generateSecp256k1Key()
        nodeTcpPort2 = Port(64012)
        nodeUdpPort2 = Port(9002)
        node2 = newTestWakuNode(
          nodeKey2,
          bindIp,
          nodeTcpPort2,
          some(extIp),
          wakuFlags = some(flags),
          discv5UdpPort = some(nodeUdpPort2),
        )

        nodeKey3 = generateSecp256k1Key()
        nodeTcpPort3 = Port(64014)
        nodeUdpPort3 = Port(9004)
        node3 = newTestWakuNode(
          nodeKey3,
          bindIp,
          nodeTcpPort3,
          some(extIp),
          wakuFlags = some(flags),
          discv5UdpPort = some(nodeUdpPort3),
        )

      # discv5
      let conf1 = WakuDiscoveryV5Config(
        discv5Config: none(DiscoveryConfig),
        address: bindIp,
        port: nodeUdpPort1,
        privateKey: keys.PrivateKey(nodeKey1.skkey),
        bootstrapRecords: @[],
        autoupdateRecord: true,
      )

      let disc1 =
        WakuDiscoveryV5.new(node1.rng, conf1, some(node1.enr), some(node1.peerManager))

      let conf2 = WakuDiscoveryV5Config(
        discv5Config: none(DiscoveryConfig),
        address: bindIp,
        port: nodeUdpPort2,
        privateKey: keys.PrivateKey(nodeKey2.skkey),
        bootstrapRecords: @[disc1.protocol.getRecord()],
        autoupdateRecord: true,
      )

      let disc2 =
        WakuDiscoveryV5.new(node2.rng, conf2, some(node2.enr), some(node2.peerManager))

      await allFutures(node1.start(), node2.start(), node3.start())
      let resultDisc1StartRes = await disc1.start()
      assert resultDisc1StartRes.isOk(), resultDisc1StartRes.error
      let resultDisc2StartRes = await disc2.start()
      assert resultDisc2StartRes.isOk(), resultDisc2StartRes.error

      ## When
      var attempts = 10
      while (disc1.protocol.nodesDiscovered < 1 or disc2.protocol.nodesDiscovered < 1) and
          attempts > 0:
        await sleepAsync(1.seconds)
        attempts -= 1

      # node2 can be connected, so will be returned by peer exchange
      require (
        await node1.peerManager.connectPeer(node2.switch.peerInfo.toRemotePeerInfo())
      )

      # Mount peer exchange
      await node1.mountPeerExchange()
      await node3.mountPeerExchange()

      let dialResponse =
        await node3.dialForPeerExchange(node1.switch.peerInfo.toRemotePeerInfo())
      let response = dialResponse.get()

      ## Then
      check:
        response.get().peerInfos.len == 1
        response.get().peerInfos[0].enr == disc2.protocol.localNode.record.raw

      await allFutures(
        [node1.stop(), node2.stop(), node3.stop(), disc1.stop(), disc2.stop()]
      )

    asyncTest "Request returns some discovered peers":
      let
        node1 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
        node2 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
        node3 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
        node4 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))

      # Start and mount peer exchange
      await allFutures([node1.start(), node2.start(), node3.start(), node4.start()])
      await allFutures([node1.mountPeerExchange(), node2.mountPeerExchangeClient()])

      # Create connection
      let connOpt = await node2.peerManager.dialPeer(
        node1.switch.peerInfo.toRemotePeerInfo(), WakuPeerExchangeCodec
      )
      require:
        connOpt.isSome

      # Simulate node1 discovering node3 via Discv5
      var info3 = node3.peerInfo.toRemotePeerInfo()
      info3.enr = some(node3.enr)
      node1.peerManager.addPeer(info3, PeerOrigin.Discv5)

      # Simulate node1 discovering node4 via Discv5
      var info4 = node4.peerInfo.toRemotePeerInfo()
      info4.enr = some(node4.enr)
      node1.peerManager.addPeer(info4, PeerOrigin.Discv5)

      # Request 2 peer from px. Test all request variants
      let response1 = await node2.wakuPeerExchangeClient.request(2)
      let response2 =
        await node2.wakuPeerExchangeClient.request(2, node1.peerInfo.toRemotePeerInfo())
      let response3 = await node2.wakuPeerExchangeClient.request(2, connOpt.get())

      # Check the response or dont even continue
      require:
        response1.isOk
        response2.isOk
        response3.isOk

      check:
        response1.get().peerInfos.len == 2
        response2.get().peerInfos.len == 2
        response3.get().peerInfos.len == 2

        # Since it can return duplicates test that at least one of the enrs is in the response
        response1.get().peerInfos.anyIt(it.enr == node3.enr.raw) or
          response1.get().peerInfos.anyIt(it.enr == node4.enr.raw)
        response2.get().peerInfos.anyIt(it.enr == node3.enr.raw) or
          response2.get().peerInfos.anyIt(it.enr == node4.enr.raw)
        response3.get().peerInfos.anyIt(it.enr == node3.enr.raw) or
          response3.get().peerInfos.anyIt(it.enr == node4.enr.raw)

    asyncTest "Request fails gracefully":
      let
        node1 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
        node2 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))

      # Start and mount peer exchange
      await allFutures([node1.start(), node2.start()])
      await allFutures([node1.mountPeerExchange(), node2.mountPeerExchange()])

      # Create connection
      let connOpt = await node2.peerManager.dialPeer(
        node1.switch.peerInfo.toRemotePeerInfo(), WakuPeerExchangeCodec
      )
      require connOpt.isSome

      # Force closing the connection to simulate a failed peer
      await connOpt.get().close()

      # Request 2 peer from px
      let response = await node1.wakuPeerExchangeClient.request(2, connOpt.get())

      # Check that it failed gracefully
      check:
        response.isErr
        response.error.status_code == PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE

    asyncTest "Request 0 peers, with 0 peers in PeerExchange":
      # Given a disconnected PeerExchange
      let
        switch = newTestSwitch()
        peerManager = PeerManager.new(switch)
        peerExchangeClient = WakuPeerExchangeClient.new(peerManager)

      # When requesting 0 peers
      let response = await peerExchangeClient.request(0)

      # Then the response should be an error
      check:
        response.isErr
        response.error.status_code == PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE

    asyncTest "Pool filtering":
      let
        key1 = generateSecp256k1Key()
        key2 = generateSecp256k1Key()
        cluster: Option[uint16] = some(uint16(16))
        bindIp = parseIpAddress("0.0.0.0")
        nodeTcpPort = Port(64010)
        nodeUdpPort = Port(9000)

      var
        builder1 = EnrBuilder.init(key1)
        builder2 = EnrBuilder.init(key2)

      builder1.withIpAddressAndPorts(some(bindIp), some(nodeTcpPort), some(nodeUdpPort))
      builder2.withIpAddressAndPorts(some(bindIp), some(nodeTcpPort), some(nodeUdpPort))
      builder1.withShardedTopics(@["/waku/2/rs/1/7"]).expect("valid topic")
      builder2.withShardedTopics(@["/waku/2/rs/16/32"]).expect("valid topic")

      let
        enr1 = builder1.build().expect("valid ENR")
        enr2 = builder2.build().expect("valid ENR")

      var
        peerInfo1 = enr1.toRemotePeerInfo().expect("valid PeerInfo")
        peerInfo2 = enr2.toRemotePeerInfo().expect("valid PeerInfo")

      peerInfo1.origin = PeerOrigin.Discv5
      peerInfo2.origin = PeerOrigin.Discv5

      check:
        poolFilter(cluster, peerInfo1).isErr()
        poolFilter(cluster, peerInfo2).isOk()

    asyncTest "Request 0 peers, with 1 peer in PeerExchange":
      # Given two valid nodes with PeerExchange
      let
        node1 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
        node2 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
        node3 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))

      # Start and mount peer exchange
      await allFutures([node1.start(), node2.start(), node3.start()])
      await allFutures([node1.mountPeerExchange(), node2.mountPeerExchangeClient()])

      # Connect the nodes
      let dialResponse = await node2.peerManager.dialPeer(
        node1.switch.peerInfo.toRemotePeerInfo(), WakuPeerExchangeCodec
      )
      assert dialResponse.isSome

      # Simulate node1 discovering node3 via Discv5
      var info3 = node3.peerInfo.toRemotePeerInfo()
      info3.enr = some(node3.enr)
      node1.peerManager.addPeer(info3, PeerOrigin.Discv5)

      # When requesting 0 peers
      let response = await node2.wakuPeerExchangeClient.request(0)

      # Then the response should be empty
      assertResultOk(response)
      check response.get().peerInfos.len == 0

    asyncTest "Request with invalid peer info":
      # Given two valid nodes with PeerExchange
      let
        node1 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
        node2 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))

      # Start and mount peer exchange
      await allFutures([node1.start(), node2.start()])
      await allFutures([node1.mountPeerExchangeClient(), node2.mountPeerExchange()])

      # When making any request with an invalid peer info
      var remotePeerInfo2 = node2.peerInfo.toRemotePeerInfo()
      remotePeerInfo2.peerId.data.add(255.byte)
      let response = await node1.wakuPeerExchangeClient.request(1, remotePeerInfo2)

      # Then the response should be an error
      check:
        response.isErr
        response.error.status_code == PeerExchangeResponseStatusCode.DIAL_FAILURE

    asyncTest "Connections are closed after response is sent":
      # Create 3 nodes
      let nodes = toSeq(0 ..< 3).mapIt(
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
        )

      await allFutures(nodes.mapIt(it.start()))
      await allFutures(nodes.mapIt(it.mountPeerExchange()))
      await allFutures(nodes.mapIt(it.mountPeerExchangeClient()))

      # Multiple nodes request to node 0
      for i in 1 ..< 3:
        let resp = await nodes[i].wakuPeerExchangeClient.request(
          2, nodes[0].switch.peerInfo.toRemotePeerInfo()
        )
        require resp.isOk

      # Wait for streams to be closed
      await sleepAsync(1.seconds)

      # Check that all streams are closed for px
      check:
        nodes[0].peerManager.getNumStreams(WakuPeerExchangeCodec) == (0, 0)
        nodes[1].peerManager.getNumStreams(WakuPeerExchangeCodec) == (0, 0)
        nodes[2].peerManager.getNumStreams(WakuPeerExchangeCodec) == (0, 0)

  suite "Protocol Handler":
    asyncTest "Works as expected":
      let
        node1 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
        node2 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
        node3 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))

      # Start and mount peer exchange
      await allFutures([node1.start(), node2.start(), node3.start()])
      await allFutures([node1.mountPeerExchange(), node2.mountPeerExchange()])

      # Simulate node1 discovering node3 via Discv5
      var info3 = node3.peerInfo.toRemotePeerInfo()
      info3.enr = some(node3.enr)
      node1.peerManager.addPeer(info3, PeerOrigin.Discv5)

      # Create connection
      let connOpt = await node2.peerManager.dialPeer(
        node1.switch.peerInfo.toRemotePeerInfo(), WakuPeerExchangeCodec
      )
      require connOpt.isSome
      let conn = connOpt.get()

      # Send bytes so that they directly hit the handler
      let rpc = PeerExchangeRpc.makeRequest(1)

      var buffer: seq[byte]
      await conn.writeLP(rpc.encode().buffer)
      buffer = await conn.readLp(DefaultMaxRpcSize.int)

      # Decode the response
      let decodedBuff = PeerExchangeRpc.decode(buffer)
      require decodedBuff.isOk

      # Check we got back the enr we mocked
      check:
        decodedBuff.get().response.status_code == PeerExchangeResponseStatusCode.SUCCESS
        decodedBuff.get().response.peerInfos.len == 1
        decodedBuff.get().response.peerInfos[0].enr == node3.enr.raw

    asyncTest "RateLimit as expected":
      let
        node1 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
        node2 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
        node3 =
          newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))

      # Start and mount peer exchange
      await allFutures([node1.start(), node2.start(), node3.start()])
      await allFutures(
        [
          node1.mountPeerExchange(rateLimit = (1, 150.milliseconds)),
          node2.mountPeerExchangeClient(),
        ]
      )

      # Simulate node1 discovering nodeA via Discv5
      var info3 = node3.peerInfo.toRemotePeerInfo()
      info3.enr = some(node3.enr)
      node1.peerManager.addPeer(info3, PeerOrigin.Discv5)

      # Create connection
      let connOpt = await node2.peerManager.dialPeer(
        node1.switch.peerInfo.toRemotePeerInfo(), WakuPeerExchangeCodec
      )
      require:
        connOpt.isSome

      await sleepAsync(150.milliseconds)

      # Request 2 peer from px. Test all request variants
      let response1 = await node2.wakuPeerExchangeClient.request(1)
      check:
        response1.isOk
        response1.get().peerInfos.len == 1

      let response2 =
        await node2.wakuPeerExchangeClient.request(1, node1.peerInfo.toRemotePeerInfo())
      check:
        response2.isErr
        response2.error().status_code == PeerExchangeResponseStatusCode.TOO_MANY_REQUESTS

      await sleepAsync(150.milliseconds)
      let response3 = await node2.wakuPeerExchangeClient.request(1, connOpt.get())
      check:
        response3.isOk
        response3.get().peerInfos.len == 1

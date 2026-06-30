{.used.}

import
  std/[options, sequtils],
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/switch,
  libp2p/peerId,
  libp2p/crypto/crypto,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  brokers/broker_context

import
  logos_delivery/waku/
    [waku_node, discovery/waku_discv5, waku_peer_exchange, node/peer_manager, waku_core],
  ../waku_peer_exchange/utils,
  ../testlib/[wakucore, wakunode, testasync]

suite "Waku Peer Exchange":
  let
    bindIp: IPAddress = parseIpAddress("0.0.0.0")
    bindPort: Port = Port(0)

  var node {.threadvar.}: WakuNode

  suite "mountPeerExchange":
    asyncSetup:
      node = newTestWakuNode(generateSecp256k1Key(), bindIp, bindPort)

    asyncTest "Started node mounts peer exchange":
      # Given a started node without peer exchange mounted
      await node.start()
      check:
        node.wakuPeerExchange == nil

      # When mounting peer exchange
      await node.mountPeerExchange()

      # Then peer exchange is mounted
      check:
        node.wakuPeerExchange != nil
        node.wakuPeerExchange.started == true

      # Cleanup
      await node.stop()

    asyncTest "Stopped node mounts peer exchange":
      # Given a stopped node without peer exchange mounted
      check:
        node.wakuPeerExchange == nil

      # When mounting peer exchange
      await node.mountPeerExchange()

      # Then peer exchange is mounted
      check:
        node.wakuPeerExchange != nil
        node.wakuPeerExchange.started == false

  suite "fetchPeerExchangePeers":
    var node2 {.threadvar.}: WakuNode
    var node3 {.threadvar.}: WakuNode

    asyncSetup:
      node = newTestWakuNode(generateSecp256k1Key(), bindIp, bindPort)
      node2 = newTestWakuNode(generateSecp256k1Key(), bindIp, bindPort)
      node3 = newTestWakuNode(generateSecp256k1Key(), bindIp, bindPort)

      await allFutures(node.start(), node2.start(), node3.start())

    asyncTeardown:
      await allFutures(node.stop(), node2.stop(), node3.stop())

    asyncTest "Node fetches without mounting peer exchange":
      # When a node, without peer exchange mounted, fetches peers
      let res = await node.fetchPeerExchangePeers(1)

      # Then no peers are fetched
      check:
        node.peerManager.switch.peerStore.peers.len == 0
        res.error.status_code == SERVICE_UNAVAILABLE
        res.error.status_desc == some("PeerExchangeClient is not mounted")

    asyncTest "Node fetches with mounted peer exchange, but no peers":
      # Given a node with peer exchange mounted
      await node.mountPeerExchangeClient()

      # When a node fetches peers
      let res = await node.fetchPeerExchangePeers(1)
      check:
        res.error.status_code == SERVICE_UNAVAILABLE
        res.error.status_desc == some("peer_not_found_failure")

      # Then no peers are fetched
      check node.peerManager.switch.peerStore.peers.len == 0

    asyncTest "Node succesfully exchanges px peers with faked discv5":
      # Given both nodes mount peer exchange
      await allFutures([node.mountPeerExchangeClient(), node2.mountPeerExchange()])
      check node.peerManager.switch.peerStore.peers.len == 0

      # Simulate node2 discovering node3 via Discv5
      var rpInfo = node3.peerInfo.toRemotePeerInfo()
      rpInfo.enr = some(node3.enr)
      node2.peerManager.addPeer(rpInfo, PeerOrigin.Discv5)

      # Set node2 as service peer (default one) for px protocol
      node.peerManager.addServicePeer(
        node2.peerInfo.toRemotePeerInfo(), WakuPeerExchangeCodec
      )

      # Request 1 peer from peer exchange protocol
      let res = await node.fetchPeerExchangePeers(1)
      check res.tryGet() == 1

      # Check that the peer ended up in the peerstore
      check:
        node.peerManager.switch.peerStore.peers.anyIt(it.peerId == rpInfo.peerId)

  suite "setPeerExchangePeer":
    var node2 {.threadvar.}: WakuNode

    asyncSetup:
      node = newTestWakuNode(generateSecp256k1Key(), bindIp, bindPort)
      node2 = newTestWakuNode(generateSecp256k1Key(), bindIp, bindPort)

      await allFutures(node.start(), node2.start())

    asyncTeardown:
      await allFutures(node.stop(), node2.stop())

    asyncTest "peer set successfully":
      # Given a node with peer exchange mounted
      await node.mountPeerExchange()
      let initialPeers = node.peerManager.switch.peerStore.peers.len

      # And a valid peer info
      let remotePeerInfo2 = node2.peerInfo.toRemotePeerInfo()

      # When making a request with a valid peer info
      node.setPeerExchangePeer(remotePeerInfo2)

      # Then the peer is added to the peer store
      check:
        node.peerManager.switch.peerStore.peers.len == (initialPeers + 1)

    asyncTest "peer exchange not mounted":
      # Given a node without peer exchange mounted
      check node.wakuPeerExchange == nil
      let initialPeers = node.peerManager.switch.peerStore.peers.len

      # And a valid peer info
      let invalidMultiAddress = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

      # When making any request with an invalid peer info
      node.setPeerExchangePeer(invalidMultiAddress)

      # Then no peer is added to the peer store
      check:
        node.peerManager.switch.peerStore.peers.len == initialPeers

    asyncTest "peer info parse error":
      # Given a node with peer exchange mounted
      await node.mountPeerExchange()
      let initialPeers = node.peerManager.switch.peerStore.peers.len

      # And given a peer info with an invalid peer id
      var remotePeerInfo2 = node2.peerInfo.toRemotePeerInfo()
      remotePeerInfo2.peerId.data.add(255.byte)

      # When making any request with an invalid peer info
      node.setPeerExchangePeer("invalidpeerinfo")

      # Then no peer is added to the peer store
      check:
        node.peerManager.switch.peerStore.peers.len == initialPeers

suite "Waku Peer Exchange with discv5":
  asyncTest "Node successfully exchanges px peers with real discv5":
    lockNewGlobalBrokerContext:
      ## Given (copied from test_waku_discv5.nim)
      let
        # todo: px flag
        flags = CapabilitiesBitfield.init(
          lightpush = false, filter = false, store = false, relay = true
        )
        bindIp = parseIpAddress("0.0.0.0")

        nodeKey1 = generateSecp256k1Key()
        node1 = newTestWakuNode(nodeKey1, bindIp, Port(0), wakuFlags = some(flags))

        nodeKey2 = generateSecp256k1Key()
        node2 = newTestWakuNode(nodeKey2, bindIp, Port(0), wakuFlags = some(flags))

        nodeKey3 = generateSecp256k1Key()
        node3 = newTestWakuNode(nodeKey3, bindIp, Port(0), wakuFlags = some(flags))

      await allFutures(node1.start(), node2.start(), node3.start())

      let disc1 = (
        await startDiscv5WithAutoPort(node1, keys.PrivateKey(nodeKey1.skkey), bindIp)
      ).valueOr:
        raiseAssert "disc1: " & error
      let disc2 = (
        await startDiscv5WithAutoPort(
          node2, keys.PrivateKey(nodeKey2.skkey), bindIp, @[disc1.protocol.getRecord()]
        )
      ).valueOr:
        raiseAssert "disc2: " & error

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
      await node3.mountPeerExchangeClient()

      let dialResponse =
        await node3.dialForPeerExchange(node1.switch.peerInfo.toRemotePeerInfo())

      check dialResponse.isOk

      let
        requestPeers = 1
        currentPeers = node3.peerManager.switch.peerStore.peers.len
      let res = await node3.fetchPeerExchangePeers(1)
      check res.tryGet() == 1

      # Then node3 has received 1 peer from node1
      check:
        node3.peerManager.switch.peerStore.peers.len == currentPeers + requestPeers

      await allFutures(
        [node1.stop(), node2.stop(), node3.stop(), disc1.stop(), disc2.stop()]
      )

{.used.}

import
  std/[sequtils, times, sugar, net],
  testutils/unittests,
  chronos,
  json_rpc/rpcserver,
  json_rpc/rpcclient,
  eth/keys,
  eth/common/eth_types,
  libp2p/[builders, switch, multiaddress],
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/rpc/message,
  libp2p/peerid
import
  waku/[
    common/databases/db_sqlite,
    node/peer_manager/peer_manager,
    node/peer_manager/peer_store/waku_peer_storage,
    waku_node,
    waku_core,
    waku_enr/capabilities,
    waku_relay/protocol,
    waku_filter_v2/common,
    waku_store/common,
    waku_peer_exchange,
    waku_metadata,
  ],
  ./testlib/common,
  ./testlib/testutils,
  ./testlib/wakucore,
  ./testlib/wakunode

procSuite "Peer Manager":
  asyncTest "connectPeer() works":
    # Create 2 nodes
    let nodes = toSeq(0 ..< 2).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )
    await allFutures(nodes.mapIt(it.start()))

    let connOk =
      await nodes[0].peerManager.connectPeer(nodes[1].peerInfo.toRemotePeerInfo())
    await sleepAsync(chronos.milliseconds(500))

    check:
      connOk == true
      nodes[0].peerManager.switch.peerStore.peers().anyIt(
        it.peerId == nodes[1].peerInfo.peerId
      )
      nodes[0].peerManager.switch.peerStore.connectedness(nodes[1].peerInfo.peerId) ==
        Connectedness.Connected

  asyncTest "dialPeer() works":
    # Create 2 nodes
    let nodes = toSeq(0 ..< 2).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )

    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))
    await allFutures(nodes.mapIt(it.mountFilter()))

    # Dial node2 from node1
    let conn = await nodes[0].peerManager.dialPeer(
      nodes[1].peerInfo.toRemotePeerInfo(), WakuFilterSubscribeCodec
    )
    await sleepAsync(chronos.milliseconds(500))

    # Check connection
    check:
      conn.isSome()
      conn.get.activity
      conn.get.peerId == nodes[1].peerInfo.peerId

    # Check that node2 is being managed in node1
    check:
      nodes[0].peerManager.switch.peerStore.peers().anyIt(
        it.peerId == nodes[1].peerInfo.peerId
      )

    # Check connectedness
    check:
      nodes[0].peerManager.switch.peerStore.connectedness(nodes[1].peerInfo.peerId) ==
        Connectedness.Connected

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "dialPeer() fails gracefully":
    # Create 2 nodes and start them
    let nodes = toSeq(0 ..< 2).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )
    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))

    let nonExistentPeerRes = parsePeerInfo(
      "/ip4/0.0.0.0/tcp/1000/p2p/16Uiu2HAmQSMNExfUYUqfuXWkD5DaNZnMYnigRxFKbk3tcEFQeQeE"
    )
    require nonExistentPeerRes.isOk()

    let nonExistentPeer = nonExistentPeerRes.value

    # Dial non-existent peer from node1
    let conn1 = await nodes[0].peerManager.dialPeer(nonExistentPeer, WakuStoreCodec)
    check:
      conn1.isNone()

    # Dial peer not supporting given protocol
    let conn2 = await nodes[0].peerManager.dialPeer(
      nodes[1].peerInfo.toRemotePeerInfo(), WakuStoreCodec
    )
    check:
      conn2.isNone()

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Adding, selecting and filtering peers work":
    let
      node = newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))

      # Create filter peer
      filterLoc = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
      filterPeer = PeerInfo.new(generateEcdsaKey(), @[filterLoc])
      # Create store peer
      storeLoc = MultiAddress.init("/ip4/127.0.0.3/tcp/4").tryGet()
      storePeer = PeerInfo.new(generateEcdsaKey(), @[storeLoc])

    await node.start()

    node.peerManager.addServicePeer(storePeer.toRemotePeerInfo(), WakuStoreCodec)
    node.peerManager.addServicePeer(
      filterPeer.toRemotePeerInfo(), WakuFilterSubscribeCodec
    )

    # Check peers were successfully added to peer manager
    check:
      node.peerManager.switch.peerStore.peers().len == 2
      node.peerManager.switch.peerStore.peers(WakuFilterSubscribeCodec).allIt(
        it.peerId == filterPeer.peerId and it.addrs.contains(filterLoc) and
          it.protocols.contains(WakuFilterSubscribeCodec)
      )
      node.peerManager.switch.peerStore.peers(WakuStoreCodec).allIt(
        it.peerId == storePeer.peerId and it.addrs.contains(storeLoc) and
          it.protocols.contains(WakuStoreCodec)
      )

    await node.stop()

  asyncTest "Peer manager keeps track of connections":
    # Create 2 nodes
    let nodes = toSeq(0 ..< 2).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )

    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))

    # Test default connectedness for new peers
    nodes[0].peerManager.addPeer(nodes[1].peerInfo.toRemotePeerInfo())
    check:
      # No information about node2's connectedness
      nodes[0].peerManager.switch.peerStore.connectedness(nodes[1].peerInfo.peerId) ==
        NotConnected

    # Failed connection
    let nonExistentPeerRes = parsePeerInfo(
      "/ip4/0.0.0.0/tcp/1000/p2p/16Uiu2HAmQSMNExfUYUqfuXWkD5DaNZnMYnigRxFKbk3tcEFQeQeE"
    )
    require:
      nonExistentPeerRes.isOk()

    let nonExistentPeer = nonExistentPeerRes.value
    require:
      (await nodes[0].peerManager.connectPeer(nonExistentPeer)) == false
    await sleepAsync(chronos.milliseconds(500))

    check:
      # Cannot connect to node2
      nodes[0].peerManager.switch.peerStore.connectedness(nonExistentPeer.peerId) ==
        CannotConnect

    # Successful connection
    require:
      (await nodes[0].peerManager.connectPeer(nodes[1].peerInfo.toRemotePeerInfo())) ==
        true
    await sleepAsync(chronos.milliseconds(500))

    check:
      # Currently connected to node2
      nodes[0].peerManager.switch.peerStore.connectedness(nodes[1].peerInfo.peerId) ==
        Connected

    # Stop node. Gracefully disconnect from all peers.
    await nodes[0].stop()
    check:
      # Not currently connected to node2, but had recent, successful connection.
      nodes[0].peerManager.switch.peerStore.connectedness(nodes[1].peerInfo.peerId) ==
        CanConnect

    await nodes[1].stop()

  asyncTest "Peer manager updates failed peers correctly":
    # Create 2 nodes
    let nodes = toSeq(0 ..< 2).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )

    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))

    let nonExistentPeerRes = parsePeerInfo(
      "/ip4/0.0.0.0/tcp/1000/p2p/16Uiu2HAmQSMNExfUYUqfuXWkD5DaNZnMYnigRxFKbk3tcEFQeQeE"
    )
    require nonExistentPeerRes.isOk()

    let nonExistentPeer = nonExistentPeerRes.value

    nodes[0].peerManager.addPeer(nonExistentPeer)

    # Set a low backoff to speed up test: 2, 4, 8, 16
    nodes[0].peerManager.initialBackoffInSec = 2
    nodes[0].peerManager.backoffFactor = 2

    # try to connect to peer that doesnt exist
    let conn1Ok = await nodes[0].peerManager.connectPeer(nonExistentPeer)
    check:
      # Cannot connect to node2
      nodes[0].peerManager.switch.peerStore.connectedness(nonExistentPeer.peerId) ==
        CannotConnect
      nodes[0].peerManager.switch.peerStore[ConnectionBook][nonExistentPeer.peerId] ==
        CannotConnect
      nodes[0].peerManager.switch.peerStore[NumberFailedConnBook][
        nonExistentPeer.peerId
      ] == 1

      # Connection attempt failed
      conn1Ok == false

      # Right after failing there is a backoff period
      nodes[0].peerManager.canBeConnected(nonExistentPeer.peerId) == false

    # We wait the first backoff period
    await sleepAsync(chronos.milliseconds(2100))

    # And backoff period is over
    check:
      nodes[0].peerManager.canBeConnected(nodes[1].peerInfo.peerId) == true

    # After a successful connection, the number of failed connections is reset

    nodes[0].peerManager.switch.peerStore[NumberFailedConnBook][
      nodes[1].peerInfo.peerId
    ] = 4
    let conn2Ok =
      await nodes[0].peerManager.connectPeer(nodes[1].peerInfo.toRemotePeerInfo())
    check:
      conn2Ok == true
      nodes[0].peerManager.switch.peerStore[NumberFailedConnBook][
        nodes[1].peerInfo.peerId
      ] == 0

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Peer manager can use persistent storage and survive restarts":
    let
      database = SqliteDatabase.new(":memory:")[]
      storage = WakuPeerStorage.new(database)[]
      node1 = newTestWakuNode(
        generateSecp256k1Key(), getPrimaryIPAddr(), Port(44048), peerStorage = storage
      )
      node2 = newTestWakuNode(generateSecp256k1Key(), getPrimaryIPAddr(), Port(34023))

    node1.mountMetadata(0, @[0'u16]).expect("Mounted Waku Metadata")
    node2.mountMetadata(0, @[0'u16]).expect("Mounted Waku Metadata")

    await node1.start()
    await node2.start()

    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    let peerInfo2 = node2.switch.peerInfo
    var remotePeerInfo2 = peerInfo2.toRemotePeerInfo()
    remotePeerInfo2.enr = some(node2.enr)

    let is12Connected = await node1.peerManager.connectPeer(remotePeerInfo2)
    assert is12Connected == true, "Node 1 and 2 not connected"

    check:
      node1.peerManager.switch.peerStore[AddressBook][remotePeerInfo2.peerId] ==
        remotePeerInfo2.addrs

    # wait for the peer store update
    await sleepAsync(chronos.milliseconds(500))

    check:
      # Currently connected to node2
      node1.peerManager.switch.peerStore.peers().len == 1
      node1.peerManager.switch.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node1.peerManager.switch.peerStore.connectedness(peerInfo2.peerId) == Connected

    # Simulate restart by initialising a new node using the same storage
    let node3 = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("127.0.0.1"),
      Port(56037),
      peerStorage = storage,
    )

    node3.mountMetadata(0, @[0'u16]).expect("Mounted Waku Metadata")

    await node3.start()

    check:
      # Node2 has been loaded after "restart", but we have not yet reconnected
      node3.peerManager.switch.peerStore.peers().len == 1
      node3.peerManager.switch.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.switch.peerStore.connectedness(peerInfo2.peerId) == NotConnected

    (await node3.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    await node3.peerManager.connectToRelayPeers()

    await sleepAsync(chronos.milliseconds(500))

    check:
      # Reconnected to node2 after "restart"
      node3.peerManager.switch.peerStore.peers().len == 1
      node3.peerManager.switch.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.switch.peerStore.connectedness(peerInfo2.peerId) == Connected

    await allFutures([node1.stop(), node2.stop(), node3.stop()])

  asyncTest "Sharded peer manager can use persistent storage and survive restarts":
    let
      database = SqliteDatabase.new(":memory:")[]
      storage = WakuPeerStorage.new(database)[]
      node1 = newTestWakuNode(
        generateSecp256k1Key(), getPrimaryIPAddr(), Port(44048), peerStorage = storage
      )
      node2 = newTestWakuNode(generateSecp256k1Key(), getPrimaryIPAddr(), Port(34023))

    node1.mountMetadata(0, @[0'u16]).expect("Mounted Waku Metadata")
    node2.mountMetadata(0, @[0'u16]).expect("Mounted Waku Metadata")

    await node1.start()
    await node2.start()

    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    let peerInfo2 = node2.switch.peerInfo
    var remotePeerInfo2 = peerInfo2.toRemotePeerInfo()
    remotePeerInfo2.enr = some(node2.enr)

    let is12Connected = await node1.peerManager.connectPeer(remotePeerInfo2)
    assert is12Connected == true, "Node 1 and 2 not connected"

    check:
      node1.peerManager.switch.peerStore[AddressBook][remotePeerInfo2.peerId] ==
        remotePeerInfo2.addrs

    # wait for the peer store update
    await sleepAsync(chronos.milliseconds(500))

    check:
      # Currently connected to node2
      node1.peerManager.switch.peerStore.peers().len == 1
      node1.peerManager.switch.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node1.peerManager.switch.peerStore.connectedness(peerInfo2.peerId) == Connected

    # Simulate restart by initialising a new node using the same storage
    let node3 = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("127.0.0.1"),
      Port(56037),
      peerStorage = storage,
    )

    node3.mountMetadata(0, @[0'u16]).expect("Mounted Waku Metadata")

    await node3.start()

    check:
      # Node2 has been loaded after "restart", but we have not yet reconnected
      node3.peerManager.switch.peerStore.peers().len == 1
      node3.peerManager.switch.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.switch.peerStore.connectedness(peerInfo2.peerId) == NotConnected

    (await node3.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    await node3.peerManager.manageRelayPeers()

    await sleepAsync(chronos.milliseconds(500))

    check:
      # Reconnected to node2 after "restart"
      node3.peerManager.switch.peerStore.peers().len == 1
      node3.peerManager.switch.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.switch.peerStore.connectedness(peerInfo2.peerId) == Connected

    await allFutures([node1.stop(), node2.stop(), node3.stop()])

  asyncTest "Peer manager drops conections to peers on different networks":
    let
      port = Port(0)
      # different network
      node1 = newTestWakuNode(
        generateSecp256k1Key(),
        parseIpAddress("0.0.0.0"),
        port,
        clusterId = 3,
        subscribeShards = @[uint16(0)],
      )

      # same network
      node2 = newTestWakuNode(
        generateSecp256k1Key(),
        parseIpAddress("0.0.0.0"),
        port,
        clusterId = 4,
        subscribeShards = @[uint16(0)],
      )
      node3 = newTestWakuNode(
        generateSecp256k1Key(),
        parseIpAddress("0.0.0.0"),
        port,
        clusterId = 4,
        subscribeShards = @[uint16(0)],
      )

    node1.mountMetadata(3, @[0'u16]).expect("Mounted Waku Metadata")
    node2.mountMetadata(4, @[0'u16]).expect("Mounted Waku Metadata")
    node3.mountMetadata(4, @[0'u16]).expect("Mounted Waku Metadata")

    # Start nodes
    await allFutures([node1.start(), node2.start(), node3.start()])

    # 1->2 (fails)
    let conn1 = await node1.peerManager.dialPeer(
      node2.switch.peerInfo.toRemotePeerInfo(), WakuMetadataCodec
    )

    # 1->3 (fails)
    let conn2 = await node1.peerManager.dialPeer(
      node3.switch.peerInfo.toRemotePeerInfo(), WakuMetadataCodec
    )

    # 2->3 (succeeds)
    let conn3 = await node2.peerManager.dialPeer(
      node3.switch.peerInfo.toRemotePeerInfo(), WakuMetadataCodec
    )

    check:
      conn1.isNone or conn1.get().isClosed
      conn2.isNone or conn2.get().isClosed
      conn3.isSome and not conn3.get().isClosed

  # TODO: nwaku/issues/1377
  xasyncTest "Peer manager support multiple protocol IDs when reconnecting to peers":
    let
      database = SqliteDatabase.new(":memory:")[]
      storage = WakuPeerStorage.new(database)[]
      node1 = newTestWakuNode(
        generateSecp256k1Key(),
        parseIpAddress("0.0.0.0"),
        Port(0),
        peerStorage = storage,
      )
      node2 =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      peerInfo2 = node2.switch.peerInfo
      betaCodec = "/vac/waku/relay/2.0.0-beta2"
      stableCodec = "/vac/waku/relay/2.0.0"

    await node1.start()
    await node2.start()

    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    node1.wakuRelay.codec = betaCodec
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    node2.wakuRelay.codec = betaCodec

    require:
      (await node1.peerManager.connectPeer(peerInfo2.toRemotePeerInfo())) == true
    check:
      # Currently connected to node2
      node1.peerManager.switch.peerStore.peers().len == 1
      node1.peerManager.switch.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node1.peerManager.switch.peerStore.peers().anyIt(
        it.protocols.contains(node2.wakuRelay.codec)
      )
      node1.peerManager.switch.peerStore.connectedness(peerInfo2.peerId) == Connected

    # Simulate restart by initialising a new node using the same storage
    let node3 = newTestWakuNode(
      generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0), peerStorage = storage
    )

    (await node3.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    node3.wakuRelay.codec = stableCodec
    check:
      # Node 2 and 3 have differing codecs
      node2.wakuRelay.codec == betaCodec
      node3.wakuRelay.codec == stableCodec
      # Node2 has been loaded after "restart", but we have not yet reconnected
      node3.peerManager.switch.peerStore.peers().len == 1
      node3.peerManager.switch.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.switch.peerStore.peers().anyIt(it.protocols.contains(betaCodec))
      node3.peerManager.switch.peerStore.connectedness(peerInfo2.peerId) == NotConnected

    await node3.start() # This should trigger a reconnect

    check:
      # Reconnected to node2 after "restart"
      node3.peerManager.switch.peerStore.peers().len == 1
      node3.peerManager.switch.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.switch.peerStore.peers().anyIt(it.protocols.contains(betaCodec))
      node3.peerManager.switch.peerStore.peers().anyIt(
        it.protocols.contains(stableCodec)
      )
      node3.peerManager.switch.peerStore.connectedness(peerInfo2.peerId) == Connected

    await allFutures([node1.stop(), node2.stop(), node3.stop()])

  asyncTest "Peer manager connects to all peers supporting a given protocol":
    # Create 4 nodes
    let nodes = toSeq(0 ..< 4).mapIt(
        newTestWakuNode(
          nodeKey = generateSecp256k1Key(),
          bindIp = parseIpAddress("0.0.0.0"),
          bindPort = Port(0),
          wakuFlags = some(CapabilitiesBitfield.init(@[Relay])),
        )
      )

    # Start them
    discard nodes.mapIt(it.mountMetadata(0, @[0'u16]))
    await allFutures(nodes.mapIt(it.mountRelay()))
    await allFutures(nodes.mapIt(it.start()))

    # Get all peer infos
    let peerInfos = collect:
      for i in 0 .. nodes.high:
        let peerInfo = nodes[i].switch.peerInfo.toRemotePeerInfo()
        peerInfo.enr = some(nodes[i].enr)
        peerInfo

    # Add all peers (but self) to node 0
    nodes[0].peerManager.addPeer(peerInfos[1])
    nodes[0].peerManager.addPeer(peerInfos[2])
    nodes[0].peerManager.addPeer(peerInfos[3])

    # Connect to relay peers
    await nodes[0].peerManager.connectToRelayPeers()

    # wait for the connections to settle
    await sleepAsync(chronos.milliseconds(500))

    check:
      # Peerstore track all three peers
      nodes[0].peerManager.switch.peerStore.peers().len == 3

      # All peer ids are correct
      nodes[0].peerManager.switch.peerStore.peers().anyIt(
        it.peerId == nodes[1].switch.peerInfo.peerId
      )
      nodes[0].peerManager.switch.peerStore.peers().anyIt(
        it.peerId == nodes[2].switch.peerInfo.peerId
      )
      nodes[0].peerManager.switch.peerStore.peers().anyIt(
        it.peerId == nodes[3].switch.peerInfo.peerId
      )

      # All peers support the relay protocol
      nodes[0].peerManager.switch.peerStore[ProtoBook][nodes[1].switch.peerInfo.peerId].contains(
        WakuRelayCodec
      )
      nodes[0].peerManager.switch.peerStore[ProtoBook][nodes[2].switch.peerInfo.peerId].contains(
        WakuRelayCodec
      )
      nodes[0].peerManager.switch.peerStore[ProtoBook][nodes[3].switch.peerInfo.peerId].contains(
        WakuRelayCodec
      )

      # All peers are connected
      nodes[0].peerManager.switch.peerStore[ConnectionBook][
        nodes[1].switch.peerInfo.peerId
      ] == Connected
      nodes[0].peerManager.switch.peerStore[ConnectionBook][
        nodes[2].switch.peerInfo.peerId
      ] == Connected
      nodes[0].peerManager.switch.peerStore[ConnectionBook][
        nodes[3].switch.peerInfo.peerId
      ] == Connected

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Sharded peer manager connects to all peers supporting a given protocol":
    # Create 4 nodes
    let nodes = toSeq(0 ..< 4).mapIt(
        newTestWakuNode(
          nodeKey = generateSecp256k1Key(),
          bindIp = parseIpAddress("0.0.0.0"),
          bindPort = Port(0),
          wakuFlags = some(CapabilitiesBitfield.init(@[Relay])),
        )
      )

    # Start them
    discard nodes.mapIt(it.mountMetadata(0, @[0'u16]))
    await allFutures(nodes.mapIt(it.mountRelay()))
    await allFutures(nodes.mapIt(it.start()))

    proc simpleHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.millis)

    let topic = "/waku/2/rs/0/0"
    for node in nodes:
      node.wakuRelay.subscribe(topic, simpleHandler)

    # Get all peer infos
    let peerInfos = collect:
      for i in 0 .. nodes.high:
        let peerInfo = nodes[i].switch.peerInfo.toRemotePeerInfo()
        peerInfo.enr = some(nodes[i].enr)
        peerInfo

    # Add all peers (but self) to node 0
    nodes[0].peerManager.addPeer(peerInfos[1])
    nodes[0].peerManager.addPeer(peerInfos[2])
    nodes[0].peerManager.addPeer(peerInfos[3])

    # Connect to relay peers
    await nodes[0].peerManager.manageRelayPeers()

    # wait for the connections to settle
    await sleepAsync(chronos.milliseconds(500))

    check:
      # Peerstore track all three peers
      nodes[0].peerManager.switch.peerStore.peers().len == 3

      # All peer ids are correct
      nodes[0].peerManager.switch.peerStore.peers().anyIt(
        it.peerId == nodes[1].switch.peerInfo.peerId
      )
      nodes[0].peerManager.switch.peerStore.peers().anyIt(
        it.peerId == nodes[2].switch.peerInfo.peerId
      )
      nodes[0].peerManager.switch.peerStore.peers().anyIt(
        it.peerId == nodes[3].switch.peerInfo.peerId
      )

      # All peers support the relay protocol
      nodes[0].peerManager.switch.peerStore[ProtoBook][nodes[1].switch.peerInfo.peerId].contains(
        WakuRelayCodec
      )
      nodes[0].peerManager.switch.peerStore[ProtoBook][nodes[2].switch.peerInfo.peerId].contains(
        WakuRelayCodec
      )
      nodes[0].peerManager.switch.peerStore[ProtoBook][nodes[3].switch.peerInfo.peerId].contains(
        WakuRelayCodec
      )

      # All peers are connected
      nodes[0].peerManager.switch.peerStore[ConnectionBook][
        nodes[1].switch.peerInfo.peerId
      ] == Connected
      nodes[0].peerManager.switch.peerStore[ConnectionBook][
        nodes[2].switch.peerInfo.peerId
      ] == Connected
      nodes[0].peerManager.switch.peerStore[ConnectionBook][
        nodes[3].switch.peerInfo.peerId
      ] == Connected

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Peer store keeps track of incoming connections":
    # Create 4 nodes
    let nodes = toSeq(0 ..< 4).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )

    # Start them
    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))

    # Get all peer infos
    let peerInfos = nodes.mapIt(it.switch.peerInfo.toRemotePeerInfo())

    # all nodes connect to peer 0
    require:
      (await nodes[1].peerManager.connectPeer(peerInfos[0])) == true
      (await nodes[2].peerManager.connectPeer(peerInfos[0])) == true
      (await nodes[3].peerManager.connectPeer(peerInfos[0])) == true

    await sleepAsync(chronos.milliseconds(500))

    check:
      # Peerstore track all three peers
      nodes[0].peerManager.switch.peerStore.peers().len == 3

      # Inbound/Outbound number of peers match
      nodes[0].peerManager.switch.peerStore.getPeersByDirection(Inbound).len == 3
      nodes[0].peerManager.switch.peerStore.getPeersByDirection(Outbound).len == 0
      nodes[1].peerManager.switch.peerStore.getPeersByDirection(Inbound).len == 0
      nodes[1].peerManager.switch.peerStore.getPeersByDirection(Outbound).len == 1
      nodes[2].peerManager.switch.peerStore.getPeersByDirection(Inbound).len == 0
      nodes[2].peerManager.switch.peerStore.getPeersByDirection(Outbound).len == 1
      nodes[3].peerManager.switch.peerStore.getPeersByDirection(Inbound).len == 0
      nodes[3].peerManager.switch.peerStore.getPeersByDirection(Outbound).len == 1

      # All peer ids are correct
      nodes[0].peerManager.switch.peerStore.peers().anyIt(
        it.peerId == nodes[1].switch.peerInfo.peerId
      )
      nodes[0].peerManager.switch.peerStore.peers().anyIt(
        it.peerId == nodes[2].switch.peerInfo.peerId
      )
      nodes[0].peerManager.switch.peerStore.peers().anyIt(
        it.peerId == nodes[3].switch.peerInfo.peerId
      )

      # All peers support the relay protocol
      nodes[0].peerManager.switch.peerStore[ProtoBook][nodes[1].switch.peerInfo.peerId].contains(
        WakuRelayCodec
      )
      nodes[0].peerManager.switch.peerStore[ProtoBook][nodes[2].switch.peerInfo.peerId].contains(
        WakuRelayCodec
      )
      nodes[0].peerManager.switch.peerStore[ProtoBook][nodes[3].switch.peerInfo.peerId].contains(
        WakuRelayCodec
      )

      # All peers are connected
      nodes[0].peerManager.switch.peerStore[ConnectionBook][
        nodes[1].switch.peerInfo.peerId
      ] == Connected
      nodes[0].peerManager.switch.peerStore[ConnectionBook][
        nodes[2].switch.peerInfo.peerId
      ] == Connected
      nodes[0].peerManager.switch.peerStore[ConnectionBook][
        nodes[3].switch.peerInfo.peerId
      ] == Connected

      # All peers are Inbound in peer 0
      nodes[0].peerManager.switch.peerStore[DirectionBook][
        nodes[1].switch.peerInfo.peerId
      ] == Inbound
      nodes[0].peerManager.switch.peerStore[DirectionBook][
        nodes[2].switch.peerInfo.peerId
      ] == Inbound
      nodes[0].peerManager.switch.peerStore[DirectionBook][
        nodes[3].switch.peerInfo.peerId
      ] == Inbound

      # All peers have an Outbound connection with peer 0
      nodes[1].peerManager.switch.peerStore[DirectionBook][
        nodes[0].switch.peerInfo.peerId
      ] == Outbound
      nodes[2].peerManager.switch.peerStore[DirectionBook][
        nodes[0].switch.peerInfo.peerId
      ] == Outbound
      nodes[3].peerManager.switch.peerStore[DirectionBook][
        nodes[0].switch.peerInfo.peerId
      ] == Outbound

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Peer store addServicePeer() stores service peers":
    # Valid peer id missing the last digit
    let basePeerId = "16Uiu2HAm7QGEZKujdSbbo1aaQyfDPQ6Bw3ybQnj6fruH5Dxwd7D"

    let
      node = newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      peers = toSeq(1 .. 4)
        .mapIt(parsePeerInfo("/ip4/0.0.0.0/tcp/30300/p2p/" & basePeerId & $it))
        .filterIt(it.isOk())
        .mapIt(it.value)

    require:
      peers.len == 4

    # service peers
    node.peerManager.addServicePeer(peers[0], WakuStoreCodec)
    node.peerManager.addServicePeer(peers[1], WakuLegacyLightPushCodec)
    node.peerManager.addServicePeer(peers[2], WakuPeerExchangeCodec)

    # relay peers (should not be added)
    node.peerManager.addServicePeer(peers[3], WakuRelayCodec)

    # all peers are stored in the peerstore
    check:
      node.peerManager.switch.peerStore.peers().anyIt(it.peerId == peers[0].peerId)
      node.peerManager.switch.peerStore.peers().anyIt(it.peerId == peers[1].peerId)
      node.peerManager.switch.peerStore.peers().anyIt(it.peerId == peers[2].peerId)

      # but the relay peer is not
      node.peerManager.switch.peerStore.peers().anyIt(it.peerId == peers[3].peerId) ==
        false

    # all service peers are added to its service slot
    check:
      node.peerManager.serviceSlots[WakuStoreCodec].peerId == peers[0].peerId
      node.peerManager.serviceSlots[WakuLegacyLightPushCodec].peerId == peers[1].peerId
      node.peerManager.serviceSlots[WakuPeerExchangeCodec].peerId == peers[2].peerId

      # but the relay peer is not
      node.peerManager.serviceSlots.hasKey(WakuRelayCodec) == false

  asyncTest "connectedPeers() returns expected number of connections per protocol":
    # Create 4 nodes
    let nodes = toSeq(0 ..< 4).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )

    # Start them with relay + filter
    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))
    await allFutures(nodes.mapIt(it.mountFilter()))

    let pInfos = nodes.mapIt(it.switch.peerInfo.toRemotePeerInfo())

    # create some connections/streams
    check:
      # some relay connections
      (await nodes[0].peerManager.connectPeer(pInfos[1])) == true
      (await nodes[0].peerManager.connectPeer(pInfos[2])) == true
      (await nodes[1].peerManager.connectPeer(pInfos[2])) == true

      (await nodes[0].peerManager.dialPeer(pInfos[1], WakuFilterSubscribeCodec)).isSome() ==
        true
      (await nodes[0].peerManager.dialPeer(pInfos[2], WakuFilterSubscribeCodec)).isSome() ==
        true

      # isolated dial creates a relay conn under the hood (libp2p behaviour)
      (await nodes[2].peerManager.dialPeer(pInfos[3], WakuFilterSubscribeCodec)).isSome() ==
        true

    # assert physical connections
    check:
      nodes[0].peerManager.connectedPeers(WakuRelayCodec)[0].len == 0
      nodes[0].peerManager.connectedPeers(WakuRelayCodec)[1].len == 2

      nodes[0].peerManager.connectedPeers(WakuFilterSubscribeCodec)[0].len == 0
      nodes[0].peerManager.connectedPeers(WakuFilterSubscribeCodec)[1].len == 2

      nodes[1].peerManager.connectedPeers(WakuRelayCodec)[0].len == 1
      nodes[1].peerManager.connectedPeers(WakuRelayCodec)[1].len == 1

      nodes[1].peerManager.connectedPeers(WakuFilterSubscribeCodec)[0].len == 1
      nodes[1].peerManager.connectedPeers(WakuFilterSubscribeCodec)[1].len == 0

      nodes[2].peerManager.connectedPeers(WakuRelayCodec)[0].len == 2
      nodes[2].peerManager.connectedPeers(WakuRelayCodec)[1].len == 1

      nodes[2].peerManager.connectedPeers(WakuFilterSubscribeCodec)[0].len == 1
      nodes[2].peerManager.connectedPeers(WakuFilterSubscribeCodec)[1].len == 1

      nodes[3].peerManager.connectedPeers(WakuRelayCodec)[0].len == 1
      nodes[3].peerManager.connectedPeers(WakuRelayCodec)[1].len == 0

      nodes[3].peerManager.connectedPeers(WakuFilterSubscribeCodec)[0].len == 1
      nodes[3].peerManager.connectedPeers(WakuFilterSubscribeCodec)[1].len == 0

  asyncTest "getNumStreams() returns expected number of connections per protocol":
    # Create 2 nodes
    let nodes = toSeq(0 ..< 2).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )

    # Start them with relay + filter
    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))
    await allFutures(nodes.mapIt(it.mountFilter()))

    let pInfos = nodes.mapIt(it.switch.peerInfo.toRemotePeerInfo())

    require:
      # multiple streams are multiplexed over a single connection.
      # note that a relay connection is created under the hood when dialing a peer (libp2p behaviour)
      (await nodes[0].peerManager.dialPeer(pInfos[1], WakuFilterSubscribeCodec)).isSome() ==
        true
      (await nodes[0].peerManager.dialPeer(pInfos[1], WakuFilterSubscribeCodec)).isSome() ==
        true
      (await nodes[0].peerManager.dialPeer(pInfos[1], WakuFilterSubscribeCodec)).isSome() ==
        true
      (await nodes[0].peerManager.dialPeer(pInfos[1], WakuFilterSubscribeCodec)).isSome() ==
        true

    check:
      nodes[0].peerManager.getNumStreams(WakuRelayCodec) == (1, 1)
      nodes[0].peerManager.getNumStreams(WakuFilterSubscribeCodec) == (0, 4)

      nodes[1].peerManager.getNumStreams(WakuRelayCodec) == (1, 1)
      nodes[1].peerManager.getNumStreams(WakuFilterSubscribeCodec) == (4, 0)

  test "selectPeer() returns the correct peer":
    # Valid peer id missing the last digit
    let basePeerId = "16Uiu2HAm7QGEZKujdSbbo1aaQyfDPQ6Bw3ybQnj6fruH5Dxwd7D"

    # Create peer manager
    let pm = PeerManager.new(
      switch = SwitchBuilder.new().withRng(rng).withMplex().withNoise().build(),
      storage = nil,
    )

    # Create 3 peer infos
    let peers = toSeq(1 .. 3)
      .mapIt(parsePeerInfo("/ip4/0.0.0.0/tcp/30300/p2p/" & basePeerId & $it))
      .filterIt(it.isOk())
      .mapIt(it.value)
    require:
      peers.len == 3

    # Add a peer[0] to the peerstore
    pm.switch.peerStore[AddressBook][peers[0].peerId] = peers[0].addrs
    pm.switch.peerStore[ProtoBook][peers[0].peerId] =
      @[WakuRelayCodec, WakuStoreCodec, WakuFilterSubscribeCodec]

    # When no service peers, we get one from the peerstore
    let selectedPeer1 = pm.selectPeer(WakuStoreCodec)
    check:
      selectedPeer1.isSome() == true
      selectedPeer1.get().peerId == peers[0].peerId

    # Same for other protocol
    let selectedPeer2 = pm.selectPeer(WakuFilterSubscribeCodec)
    check:
      selectedPeer2.isSome() == true
      selectedPeer2.get().peerId == peers[0].peerId

    # And return none if we dont have any peer for that protocol
    let selectedPeer3 = pm.selectPeer(WakuLegacyLightPushCodec)
    check:
      selectedPeer3.isSome() == false

    # Now we add service peers for different protocols peer[1..3]
    pm.addServicePeer(peers[1], WakuStoreCodec)
    pm.addServicePeer(peers[2], WakuLegacyLightPushCodec)

    # We no longer get one from the peerstore. Slots are being used instead.
    let selectedPeer4 = pm.selectPeer(WakuStoreCodec)
    check:
      selectedPeer4.isSome() == true
      selectedPeer4.get().peerId == peers[1].peerId

    let selectedPeer5 = pm.selectPeer(WakuLegacyLightPushCodec)
    check:
      selectedPeer5.isSome() == true
      selectedPeer5.get().peerId == peers[2].peerId

  test "peer manager cant have more max connections than peerstore size":
    # Peerstore size can't be smaller than max connections
    let peerStoreSize = 20
    let maxConnections = 25

    expect(Defect):
      let pm = PeerManager.new(
        switch = SwitchBuilder
          .new()
          .withRng(rng)
          .withMplex()
          .withNoise()
          .withPeerStore(peerStoreSize)
          .withMaxConnections(maxConnections)
          .build(),
        storage = nil,
      )

  test "prunePeerStore() correctly removes peers to match max quota":
    # Create peer manager
    let pm = PeerManager.new(
      switch = SwitchBuilder
        .new()
        .withRng(rng)
        .withMplex()
        .withNoise()
        .withPeerStore(25)
        .withMaxConnections(20)
        .build(),
      maxFailedAttempts = 1,
      storage = nil,
      maxConnections = 20,
    )

    # Create 30 peers and add them to the peerstore
    let peers = toSeq(1 .. 30)
      .mapIt(parsePeerInfo("/ip4/0.0.0.0/tcp/0/p2p/" & $PeerId.random().get()))
      .filterIt(it.isOk())
      .mapIt(it.value)
    for p in peers:
      pm.addPeer(p)

    # Check that we have 30 peers in the peerstore
    check:
      pm.switch.peerStore.peers.len == 30

    # fake that some peers failed to connected
    pm.switch.peerStore[NumberFailedConnBook][peers[0].peerId] = 2
    pm.switch.peerStore[NumberFailedConnBook][peers[1].peerId] = 2
    pm.switch.peerStore[NumberFailedConnBook][peers[2].peerId] = 2
    pm.switch.peerStore[NumberFailedConnBook][peers[3].peerId] = 2
    pm.switch.peerStore[NumberFailedConnBook][peers[4].peerId] = 2

    # fake that some peers are connected
    pm.switch.peerStore[ConnectionBook][peers[5].peerId] = Connected
    pm.switch.peerStore[ConnectionBook][peers[8].peerId] = Connected
    pm.switch.peerStore[ConnectionBook][peers[15].peerId] = Connected
    pm.switch.peerStore[ConnectionBook][peers[18].peerId] = Connected
    pm.switch.peerStore[ConnectionBook][peers[24].peerId] = Connected
    pm.switch.peerStore[ConnectionBook][peers[29].peerId] = Connected

    # Prune the peerstore (current=30, target=25)
    pm.prunePeerStore()

    check:
      # ensure peerstore was pruned
      pm.switch.peerStore.peers.len == 25

      # ensure connected peers were not pruned
      pm.switch.peerStore.peers.anyIt(it.peerId == peers[5].peerId)
      pm.switch.peerStore.peers.anyIt(it.peerId == peers[8].peerId)
      pm.switch.peerStore.peers.anyIt(it.peerId == peers[15].peerId)
      pm.switch.peerStore.peers.anyIt(it.peerId == peers[18].peerId)
      pm.switch.peerStore.peers.anyIt(it.peerId == peers[24].peerId)
      pm.switch.peerStore.peers.anyIt(it.peerId == peers[29].peerId)

      # ensure peers that failed were the first to be pruned
      not pm.switch.peerStore.peers.anyIt(it.peerId == peers[0].peerId)
      not pm.switch.peerStore.peers.anyIt(it.peerId == peers[1].peerId)
      not pm.switch.peerStore.peers.anyIt(it.peerId == peers[2].peerId)
      not pm.switch.peerStore.peers.anyIt(it.peerId == peers[3].peerId)
      not pm.switch.peerStore.peers.anyIt(it.peerId == peers[4].peerId)

  asyncTest "canBeConnected() returns correct value":
    let pm = PeerManager.new(
      switch = SwitchBuilder
        .new()
        .withRng(rng)
        .withMplex()
        .withNoise()
        .withPeerStore(25)
        .withMaxConnections(20)
        .build(),
      initialBackoffInSec = 1,
        # with InitialBackoffInSec = 1 backoffs are: 1, 2, 4, 8secs.
      backoffFactor = 2,
      maxFailedAttempts = 10,
      storage = nil,
      maxConnections = 20,
    )
    var p1: PeerId
    require p1.init("QmeuZJbXrszW2jdT7GdduSjQskPU3S7vvGWKtKgDfkDvW" & "1")

    # new peer with no errors can be connected
    check:
      pm.canBeConnected(p1) == true

    # peer with ONE error that just failed
    pm.switch.peerStore[NumberFailedConnBook][p1] = 1
    pm.switch.peerStore[LastFailedConnBook][p1] = Moment.init(getTime().toUnix, Second)
    # we cant connect right now
    check:
      pm.canBeConnected(p1) == false

    # but we can after the first backoff of 1 seconds
    await sleepAsync(chronos.milliseconds(1200))
    check:
      pm.canBeConnected(p1) == true

    # peer with TWO errors, we can connect until 2 seconds have passed
    pm.switch.peerStore[NumberFailedConnBook][p1] = 2
    pm.switch.peerStore[LastFailedConnBook][p1] = Moment.init(getTime().toUnix, Second)

    # cant be connected after 1 second
    await sleepAsync(chronos.milliseconds(1000))
    check:
      pm.canBeConnected(p1) == false

    # can be connected after 2 seconds
    await sleepAsync(chronos.milliseconds(1200))
    check:
      pm.canBeConnected(p1) == true

    # can't be connected if failed attempts are equal to maxFailedAttempts
    pm.maxFailedAttempts = 2
    check:
      pm.canBeConnected(p1) == false

  test "peer manager must fail if max backoff is over a week":
    # Should result in overflow exception
    expect(Defect):
      let pm = PeerManager.new(
        switch = SwitchBuilder
          .new()
          .withRng(rng)
          .withMplex()
          .withNoise()
          .withPeerStore(25)
          .withMaxConnections(20)
          .build(),
        maxFailedAttempts = 150,
        storage = nil,
        maxConnections = 20,
      )

    # Should result in backoff > 1 week
    expect(Defect):
      let pm = PeerManager.new(
        switch = SwitchBuilder
          .new()
          .withRng(rng)
          .withMplex()
          .withNoise()
          .withPeerStore(25)
          .withMaxConnections(20)
          .build(),
        maxFailedAttempts = 10,
        storage = nil,
        maxConnections = 20,
      )

    let pm = PeerManager.new(
      switch = SwitchBuilder
        .new()
        .withRng(rng)
        .withMplex()
        .withNoise()
        .withPeerStore(25)
        .withMaxConnections(20)
        .build(),
      maxFailedAttempts = 5,
      storage = nil,
      maxConnections = 20,
    )

  asyncTest "colocationLimit is enforced by pruneConnsByIp()":
    # Create 5 nodes
    let nodes = toSeq(0 ..< 5).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )

    # Start them with relay + filter
    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))

    let pInfos = nodes.mapIt(it.switch.peerInfo.toRemotePeerInfo())

    # force max 1 conn per ip
    nodes[0].peerManager.colocationLimit = 1

    # 2 in connections
    discard await nodes[1].peerManager.connectPeer(pInfos[0])
    discard await nodes[2].peerManager.connectPeer(pInfos[0])
    await sleepAsync(chronos.milliseconds(500))

    # but one is pruned
    check nodes[0].peerManager.switch.connManager.getConnections().len == 1

    # 2 out connections
    discard await nodes[0].peerManager.connectPeer(pInfos[3])
    discard await nodes[0].peerManager.connectPeer(pInfos[4])
    await sleepAsync(chronos.milliseconds(500))

    # they are also prunned
    check nodes[0].peerManager.switch.connManager.getConnections().len == 1

    # we should have 4 peers (2in/2out) but due to collocation limit
    # they are pruned to max 1
    check:
      nodes[0].peerManager.ipTable["127.0.0.1"].len == 1
      nodes[0].peerManager.switch.connManager.getConnections().len == 1
      nodes[0].peerManager.switch.peerStore.peers().len == 1

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Retrieve peer that mounted peer exchange":
    let
      node1 = newTestWakuNode(generateSecp256k1Key(), getPrimaryIPAddr(), Port(55048))
      node2 = newTestWakuNode(generateSecp256k1Key(), getPrimaryIPAddr(), Port(55023))

    await allFutures(node1.start(), node2.start())
    await allFutures(node1.mountRelay(), node2.mountRelay())
    await allFutures(node1.mountPeerExchange(), node2.mountPeerExchange())

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    var r = node1.peerManager.selectPeer(WakuRelayCodec)
    assert r.isSome(), "could not retrieve peer mounting WakuRelayCodec"

    r = node1.peerManager.selectPeer(WakuPeerExchangeCodec)
    assert r.isSome(), "could not retrieve peer mounting WakuPeerExchangeCodec"

  asyncTest "selectPeer() filters peers by shard using ENR":
    ## Given: A peer manager with 3 peers having different shards in their ENRs
    let
      clusterId = 0.uint16
      shardId0 = 0.uint16
      shardId1 = 1.uint16

    # Create 3 nodes with different shards
    let nodes = @[
      newTestWakuNode(
        generateSecp256k1Key(),
        parseIpAddress("0.0.0.0"),
        Port(0),
        clusterId = clusterId,
        subscribeShards = @[shardId0],
      ),
      newTestWakuNode(
        generateSecp256k1Key(),
        parseIpAddress("0.0.0.0"),
        Port(0),
        clusterId = clusterId,
        subscribeShards = @[shardId1],
      ),
      newTestWakuNode(
        generateSecp256k1Key(),
        parseIpAddress("0.0.0.0"),
        Port(0),
        clusterId = clusterId,
        subscribeShards = @[shardId0],
      ),
    ]

    await allFutures(nodes.mapIt(it.start()))
    for node in nodes:
      discard await node.mountRelay()

    # Get peer infos with ENRs
    let peerInfos = collect:
      for node in nodes:
        var peerInfo = node.switch.peerInfo.toRemotePeerInfo()
        peerInfo.enr = some(node.enr)
        peerInfo

    # Add all peers to node 0's peer manager and peerstore
    for i in 1 .. 2:
      nodes[0].peerManager.addPeer(peerInfos[i])
      nodes[0].peerManager.switch.peerStore[AddressBook][peerInfos[i].peerId] =
        peerInfos[i].addrs
      nodes[0].peerManager.switch.peerStore[ProtoBook][peerInfos[i].peerId] =
        @[WakuRelayCodec]

    ## When: We select a peer for shard 0
    let shard0Topic = some(PubsubTopic("/waku/2/rs/0/0"))
    let selectedPeer0 = nodes[0].peerManager.selectPeer(WakuRelayCodec, shard0Topic)

    ## Then: Only peers supporting shard 0 are considered (nodes 2, not node 1)
    check:
      selectedPeer0.isSome()
      selectedPeer0.get().peerId != peerInfos[1].peerId # node1 has shard 1
      selectedPeer0.get().peerId == peerInfos[2].peerId # node2 has shard 0

    ## When: We select a peer for shard 1
    let shard1Topic = some(PubsubTopic("/waku/2/rs/0/1"))
    let selectedPeer1 = nodes[0].peerManager.selectPeer(WakuRelayCodec, shard1Topic)

    ## Then: Only peer with shard 1 is selected
    check:
      selectedPeer1.isSome()
      selectedPeer1.get().peerId == peerInfos[1].peerId # node1 has shard 1

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "selectPeer() filters peers by shard using shards field":
    ## Given: A peer manager with peers having shards in RemotePeerInfo (no ENR)
    let
      clusterId = 0.uint16
      shardId0 = 0.uint16
      shardId1 = 1.uint16

    # Create peer manager
    let pm = PeerManager.new(
      switch = SwitchBuilder.new().withRng(rng()).withMplex().withNoise().build(),
      storage = nil,
    )

    # Create peer infos with shards field populated (simulating metadata exchange)
    let basePeerId = "16Uiu2HAm7QGEZKujdSbbo1aaQyfDPQ6Bw3ybQnj6fruH5Dxwd7D"
    let peers = toSeq(1 .. 3)
      .mapIt(parsePeerInfo("/ip4/0.0.0.0/tcp/30300/p2p/" & basePeerId & $it))
      .filterIt(it.isOk())
      .mapIt(it.value)
    require:
      peers.len == 3

    # Manually populate the shards field (ENR is not available)
    var peerInfos: seq[RemotePeerInfo] = @[]
    for i, peer in peers:
      var peerInfo = RemotePeerInfo.init(peer.peerId, peer.addrs)
      # Peer 0 and 2 have shard 0, peer 1 has shard 1
      peerInfo.shards =
        if i == 1:
          @[shardId1]
        else:
          @[shardId0]
      # Note: ENR is intentionally left as none
      peerInfos.add(peerInfo)

    # Add peers to peerstore
    for peerInfo in peerInfos:
      pm.switch.peerStore[AddressBook][peerInfo.peerId] = peerInfo.addrs
      pm.switch.peerStore[ProtoBook][peerInfo.peerId] = @[WakuRelayCodec]
      # simulate metadata exchange by setting shards field in peerstore
      pm.switch.peerStore.setShardInfo(peerInfo.peerId, peerInfo.shards)

    ## When: We select a peer for shard 0
    let shard0Topic = some(PubsubTopic("/waku/2/rs/0/0"))
    let selectedPeer0 = pm.selectPeer(WakuRelayCodec, shard0Topic)

    ## Then: Peers with shard 0 in shards field are selected
    check:
      selectedPeer0.isSome()
      selectedPeer0.get().peerId in [peerInfos[0].peerId, peerInfos[2].peerId]

    ## When: We select a peer for shard 1
    let shard1Topic = some(PubsubTopic("/waku/2/rs/0/1"))
    let selectedPeer1 = pm.selectPeer(WakuRelayCodec, shard1Topic)

    ## Then: Peer with shard 1 in shards field is selected
    check:
      selectedPeer1.isSome()
      selectedPeer1.get().peerId == peerInfos[1].peerId

  asyncTest "selectPeer() handles invalid pubsub topic gracefully":
    ## Given: A peer manager with valid peers
    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("0.0.0.0"),
      Port(0),
      clusterId = 0,
      subscribeShards = @[0'u16],
    )
    await node.start()

    # Add a peer
    let peer =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
    await peer.start()
    discard await peer.mountRelay()

    var peerInfo = peer.switch.peerInfo.toRemotePeerInfo()
    peerInfo.enr = some(peer.enr)
    node.peerManager.addPeer(peerInfo)
    node.peerManager.switch.peerStore[ProtoBook][peerInfo.peerId] = @[WakuRelayCodec]

    ## When: selectPeer is called with malformed pubsub topic
    let invalidTopics = @[
      some(PubsubTopic("invalid-topic")),
      some(PubsubTopic("/waku/2/invalid")),
      some(PubsubTopic("/waku/2/rs/abc/0")), # non-numeric cluster
      some(PubsubTopic("")), # empty topic
    ]

    ## Then: Returns none(RemotePeerInfo) without crashing
    for invalidTopic in invalidTopics:
      let result = node.peerManager.selectPeer(WakuRelayCodec, invalidTopic)
      check:
        result.isNone()

    await allFutures(node.stop(), peer.stop())

  asyncTest "selectPeer() prioritizes ENR over shards field":
    ## Given: A peer with both ENR and shards field populated
    let
      clusterId = 0.uint16
      shardId0 = 0.uint16
      shardId1 = 1.uint16

    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("0.0.0.0"),
      Port(0),
      clusterId = clusterId,
      subscribeShards = @[shardId0],
    )
    await node.start()
    discard await node.mountRelay()

    # Create peer with ENR containing shard 0
    let peer = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("0.0.0.0"),
      Port(0),
      clusterId = clusterId,
      subscribeShards = @[shardId0],
    )
    await peer.start()
    discard await peer.mountRelay()

    # Create peer info with ENR (shard 0) but set shards field to shard 1
    var peerInfo = peer.switch.peerInfo.toRemotePeerInfo()
    peerInfo.enr = some(peer.enr) # ENR has shard 0
    peerInfo.shards = @[shardId1] # shards field has shard 1

    node.peerManager.addPeer(peerInfo)
    node.peerManager.switch.peerStore[ProtoBook][peerInfo.peerId] = @[WakuRelayCodec]
    # simulate metadata exchange by setting shards field in peerstore
    node.peerManager.switch.peerStore.setShardInfo(peerInfo.peerId, peerInfo.shards)

    ## When: We select for shard 0
    let shard0Topic = some(PubsubTopic("/waku/2/rs/0/0"))
    let selectedPeer = node.peerManager.selectPeer(WakuRelayCodec, shard0Topic)

    ## Then: Peer is selected because ENR (shard 0) takes precedence
    check:
      selectedPeer.isSome()
      selectedPeer.get().peerId == peerInfo.peerId

    ## When: We select for shard 1
    let shard1Topic = some(PubsubTopic("/waku/2/rs/0/1"))
    let selectedPeer1 = node.peerManager.selectPeer(WakuRelayCodec, shard1Topic)

    ## Then: Peer is still selected because shards field is checked as fallback
    check:
      selectedPeer1.isSome()
      selectedPeer1.get().peerId == peerInfo.peerId

    await allFutures(node.stop(), peer.stop())

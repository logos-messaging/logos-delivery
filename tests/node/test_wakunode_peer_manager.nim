{.used.}

import
  os,
  std/[options, tables],
  testutils/unittests,
  chronos,
  # chronos/timer,
  chronicles,
  times,
  libp2p/[peerstore, crypto/crypto, multiaddress]

from times import getTime, toUnix

import
  waku/[
    waku_core,
    node/peer_manager,
    node/waku_node,
    node/kernel_api,
    discovery/waku_discv5,
    waku_filter_v2/common,
    waku_relay/protocol,
  ],
  ../testlib/[wakucore, wakunode, testasync, testutils, comparisons],
  ../waku_enr/utils,
  ../waku_archive/archive_utils,
  ../waku_discv5/utils,
  ./peer_manager/peer_store/utils

const DEFAULT_PROTOCOLS: seq[string] =
  @["/ipfs/id/1.0.0", "/libp2p/autonat/1.0.0", "/libp2p/circuit/relay/0.2.0/hop"]

let
  listenIp = parseIpAddress("0.0.0.0")
  listenPort = Port(0)

suite "Peer Manager":
  var
    pubsubTopic {.threadvar.}: PubsubTopic
    contentTopic {.threadvar.}: ContentTopic

  var
    server {.threadvar.}: WakuNode
    serverPeerStore {.threadvar.}: PeerStore
    client {.threadvar.}: WakuNode
    clientPeerStore {.threadvar.}: PeerStore

  var
    serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    serverPeerId {.threadvar.}: PeerId
    clientRemotePeerInfo {.threadvar.}: RemotePeerInfo
    clientPeerId {.threadvar.}: PeerId

  asyncSetup:
    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, listenIp, Port(3000))
    serverPeerStore = server.peerManager.switch.peerStore
    client = newTestWakuNode(clientKey, listenIp, Port(3001))
    clientPeerStore = client.peerManager.switch.peerStore

    await allFutures(server.start(), client.start())

    serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
    serverPeerId = serverRemotePeerInfo.peerId
    clientRemotePeerInfo = client.switch.peerInfo.toRemotePeerInfo()
    clientPeerId = clientRemotePeerInfo.peerId

  asyncTeardown:
    await allFutures(server.stop(), client.stop())

  suite "Peer Connectivity, Management, and Store":
    asyncTest "Peer Connection Validation":
      # When a client connects to a server
      await client.connectToNodes(@[serverRemotePeerInfo])

      # Then the server should have the client in its peer store
      check:
        clientPeerStore.peerExists(serverRemotePeerInfo.peerId)
        clientPeerStore.getPeer(serverPeerId).connectedness == Connectedness.Connected
        serverPeerStore.getPeer(clientPeerId).connectedness == Connectedness.Connected

    asyncTest "Graceful Handling of Non-Existent Peers":
      # Given a non existent RemotePeerInfo
      let
        privKey = generateSecp256k1Key()
        extIp = "127.0.0.1"
        tcpPort = 61500u16
        udpPort = 9000u16
        nonExistentRecord = newTestEnrRecord(
          privKey = privKey, extIp = extIp, tcpPort = tcpPort, udpPort = udpPort
        )
        nonExistentRemotePeerInfo = nonExistentRecord.toRemotePeerInfo().value()

      # When a client connects to the non existent peer
      await client.connectToNodes(@[nonExistentRemotePeerInfo])

      # Then the client exists in the peer store but is marked as a failed connection
      let parsedRemotePeerInfo =
        clientPeerStore.getPeer(nonExistentRemotePeerInfo.peerId)
      check:
        clientPeerStore.peerExists(nonExistentRemotePeerInfo.peerId)
        parsedRemotePeerInfo.connectedness == CannotConnect
        parsedRemotePeerInfo.lastFailedConn <= Moment.init(getTime().toUnix, Second)
        parsedRemotePeerInfo.numberFailedConn == 1

    suite "Peer Store Pruning":
      asyncTest "Capacity is not exceeded":
        # Given the client's peer store has a capacity of 1
        clientPeerStore.setCapacity(1)

        # And the client connects to the server
        await client.connectToNodes(@[serverRemotePeerInfo])
        check:
          clientPeerStore.peers().len == 1

        # When pruning the client's store
        client.peerManager.prunePeerStore()

        # Then no peers are removed
        check:
          clientPeerStore.peers().len == 1

      asyncTest "Capacity is not exceeded but some peers are unhealthy":
        # Given the client's peer store has a capacity of 1
        clientPeerStore.setCapacity(1)

        # And the client connects to the server
        await client.connectToNodes(@[serverRemotePeerInfo])
        check:
          clientPeerStore.peers().len == 1

        # Given the server is marked as CannotConnect
        client.peerManager.switch.peerStore[ConnectionBook].book[serverPeerId] =
          CannotConnect

        # When pruning the client's store
        client.peerManager.prunePeerStore()

        # Then no peers are removed
        check:
          clientPeerStore.peers().len == 1

      asyncTest "Capacity is exceeded but all peers are healthy":
        # Given the client's peer store has a capacity of 0
        clientPeerStore.setCapacity(0)

        # And the client connects to the server
        await client.connectToNodes(@[serverRemotePeerInfo])
        check:
          clientPeerStore.peers().len == 1

        # When pruning the client's store
        client.peerManager.prunePeerStore()

        # Then no peers are removed
        check:
          clientPeerStore.peers().len == 1

      asyncTest "Failed connections":
        # Given the client's peer store has a capacity of 0 and maxFailedAttempts of 1
        clientPeerStore.setCapacity(0)
        client.peerManager.maxFailedAttempts = 1

        # And the client connects to the server
        await client.connectToNodes(@[serverRemotePeerInfo])
        check:
          clientPeerStore.peers().len == 1

        # Given the server is marked as having 1 failed connection
        client.peerManager.switch.peerStore[NumberFailedConnBook].book[serverPeerId] = 1

        # When pruning the client's store
        client.peerManager.prunePeerStore()

        # Then the server is removed from the client's peer store
        check:
          clientPeerStore.peers().len == 0

      asyncTest "Shardless":
        # Given the client's peer store has a capacity of 0
        clientPeerStore.setCapacity(0)

        # And the client connects to the server
        await client.connectToNodes(@[serverRemotePeerInfo])
        check:
          clientPeerStore.peers().len == 1

        # Given the server is marked as not connected
        client.peerManager.switch.peerStore[ConnectionBook].book[serverPeerId] =
          CannotConnect

        # When pruning the client's store
        client.peerManager.prunePeerStore()

        # Then the server is removed from the client's peer store
        check:
          clientPeerStore.peers().len == 0

      asyncTest "Higher than avg shard count":
        # Given the client's peer store has a capacity of 0
        clientPeerStore.setCapacity(0)

        # And the server's remote peer info contains the node's ENR
        serverRemotePeerInfo.enr = some(server.enr)

        # And the client connects to the server
        await client.connectToNodes(@[serverRemotePeerInfo])
        check:
          clientPeerStore.peers().len == 1

        # Given the server is marked as not connected
        # (There's only one shard in the ENR so avg shards will be the same as the shard count; hence it will be purged.)
        client.peerManager.switch.peerStore[ConnectionBook].book[serverPeerId] =
          CannotConnect

        # When pruning the client's store
        client.peerManager.prunePeerStore()

        # Then the server is removed from the client's peer store
        check:
          clientPeerStore.peers().len == 0

    suite "Enforcing Colocation Limits":
      asyncTest "Without colocation limits":
        # Given two extra clients
        let
          client2Key = generateSecp256k1Key()
          client3Key = generateSecp256k1Key()
          client2 = newTestWakuNode(client2Key, listenIp, listenPort)
          client3 = newTestWakuNode(client3Key, listenIp, listenPort)

        await allFutures(client2.start(), client3.start())

        # And the server's peer manager has no colocation limit
        server.peerManager.colocationLimit = 0

        # When all clients connect to the server
        await client.connectToNodes(@[serverRemotePeerInfo])
        await client2.connectToNodes(@[serverRemotePeerInfo])
        await client3.connectToNodes(@[serverRemotePeerInfo])

        # Then the server should have all clients in its peer store
        check:
          serverPeerStore.peers().len == 3

        # Teardown
        await allFutures(client2.stop(), client3.stop())

      asyncTest "With colocation limits":
        # Given two extra clients
        let
          client2Key = generateSecp256k1Key()
          client3Key = generateSecp256k1Key()
          client2 = newTestWakuNode(client2Key, listenIp, listenPort)
          client3 = newTestWakuNode(client3Key, listenIp, listenPort)

        await allFutures(client2.start(), client3.start())

        # And the server's peer manager has a colocation limit of 1
        server.peerManager.colocationLimit = 1

        # When all clients connect to the server
        await client.connectToNodes(@[serverRemotePeerInfo])
        await client2.connectToNodes(@[serverRemotePeerInfo])
        await client3.connectToNodes(@[serverRemotePeerInfo])

        # Then the server should have only 1 client in its peer store
        check:
          serverPeerStore.peers().len == 1

        # Teardown
        await allFutures(client2.stop(), client3.stop())

    suite "In-memory Data Structure Verification":
      asyncTest "Cannot add self":
        # When trying to add self to the peer store
        client.peerManager.addPeer(clientRemotePeerInfo)

        # Then the peer store should not contain the peer
        check:
          not clientPeerStore.peerExists(clientPeerId)

      asyncTest "Peer stored in peer store":
        # When adding a peer other than self to the peer store
        client.peerManager.addPeer(serverRemotePeerInfo)

        # Then the peer store should contain the peer
        check:
          clientPeerStore.peerExists(serverPeerId)
          clientPeerStore[AddressBook][serverPeerId] == serverRemotePeerInfo.addrs

    suite "Protocol-Specific Peer Handling":
      asyncTest "Peer Protocol Support Verification - No waku protocols":
        # When connecting to a server with no Waku protocols
        await client.connectToNodes(@[serverRemotePeerInfo])

        # Then the stored protocols should be the default (libp2p) ones
        check:
          clientPeerStore.peerExists(serverPeerId)
          clientPeerStore.getPeer(serverPeerId).protocols == DEFAULT_PROTOCOLS

      asyncTest "Peer Protocol Support Verification (Before Connection)":
        # Given the server has mounted some Waku protocols
        (await server.mountRelay()).isOkOr:
          assert false, "Failed to mount relay"
        await server.mountFilter()

        # When connecting to the server
        await client.connectToNodes(@[serverRemotePeerInfo])

        # Then the stored protocols should include the Waku protocols
        check:
          clientPeerStore.peerExists(serverPeerId)
          clientPeerStore.getPeer(serverPeerId).protocols ==
            DEFAULT_PROTOCOLS & @[WakuRelayCodec, WakuFilterSubscribeCodec]

      asyncTest "Service-Specific Peer Addition":
        # Given a server mounts some Waku protocols
        await server.mountFilter()

        # And another server that mounts different Waku protocols
        let
          server2Key = generateSecp256k1Key()
          server2 = newTestWakuNode(server2Key, listenIp, listenPort)

        await server2.start()

        let
          server2RemotePeerInfo = server2.switch.peerInfo.toRemotePeerInfo()
          server2PeerId = server2RemotePeerInfo.peerId

        (await server2.mountRelay()).isOkOr:
          assert false, "Failed to mount relay"

        # When connecting to both servers
        await client.connectToNodes(@[serverRemotePeerInfo, server2RemotePeerInfo])

        # Then the peer store should contain both peers with the correct protocols
        check:
          clientPeerStore.peerExists(serverPeerId)
          clientPeerStore.getPeer(serverPeerId).protocols ==
            DEFAULT_PROTOCOLS & @[WakuFilterSubscribeCodec]
          clientPeerStore.peerExists(server2PeerId)
          clientPeerStore.getPeer(server2PeerId).protocols ==
            DEFAULT_PROTOCOLS & @[WakuRelayCodec]

        # Cleanup
        await server2.stop()

    suite "Tracked Peer Metadata":
      asyncTest "Metadata Recording":
        # When adding a peer other than self to the peer store
        serverRemotePeerInfo.enr = some(server.enr)
        client.peerManager.addPeer(serverRemotePeerInfo)

        # Then the peer store should contain the peer
        check clientPeerStore.peerExists(serverPeerId)

        # And all the peer's information should be stored
        check:
          clientPeerStore[AddressBook][serverPeerId] == serverRemotePeerInfo.addrs
          clientPeerStore[ENRBook][serverPeerId].raw ==
            serverRemotePeerInfo.enr.get().raw
          chainedComparison(
            clientPeerStore[ProtoBook][serverPeerId],
            serverRemotePeerInfo.protocols,
            DEFAULT_PROTOCOLS,
          )
          chainedComparison(
            clientPeerStore[AgentBook][serverPeerId], # FIXME: Not assigned
            serverRemotePeerInfo.agent,
            "nim-libp2p/0.0.1",
          )
          chainedComparison(
            clientPeerStore[ProtoVersionBook][serverPeerId], # FIXME: Not assigned
            serverRemotePeerInfo.protoVersion,
            "ipfs/0.1.0",
          )
          clientPeerStore[KeyBook][serverPeerId] == serverRemotePeerInfo.publicKey
          chainedComparison(
            clientPeerStore[ConnectionBook][serverPeerId],
            serverRemotePeerInfo.connectedness,
            NOT_CONNECTED,
          )
          chainedComparison(
            clientPeerStore[DisconnectBook][serverPeerId],
            serverRemotePeerInfo.disconnectTime,
            0,
          )
          chainedComparison(
            clientPeerStore[SourceBook][serverPeerId],
            serverRemotePeerInfo.origin,
            UnknownOrigin,
          )
          chainedComparison(
            clientPeerStore[DirectionBook][serverPeerId],
            serverRemotePeerInfo.direction,
            UnknownDirection,
          )
          chainedComparison(
            clientPeerStore[LastFailedConnBook][serverPeerId],
            serverRemotePeerInfo.lastFailedConn,
            Moment.init(0, Second),
          )
          chainedComparison(
            clientPeerStore[NumberFailedConnBook][serverPeerId],
            serverRemotePeerInfo.numberFailedConn,
            0,
          )

      xasyncTest "Metadata Accuracy":
        # Given a second server
        let
          server2Key = generateSecp256k1Key()
          server2 = newTestWakuNode(server2Key, listenIp, listenPort)
          server2RemotePeerInfo = server2.switch.peerInfo.toRemotePeerInfo()
          server2PeerId = server2RemotePeerInfo.peerId

        await server2.start()

        # When the client connects to both servers
        await client.connectToNodes(@[serverRemotePeerInfo, server2RemotePeerInfo])

        # Then the peer store should contain both peers with the correct metadata
        check:
          # Server
          clientPeerStore[AddressBook][serverPeerId] == serverRemotePeerInfo.addrs
          clientPeerStore[ENRBook][serverPeerId].raw ==
            serverRemotePeerInfo.enr.get().raw
          chainedComparison(
            clientPeerStore[ProtoBook][serverPeerId],
            serverRemotePeerInfo.protocols,
            DEFAULT_PROTOCOLS,
          )
          chainedComparison(
            clientPeerStore[AgentBook][serverPeerId], # FIXME: Not assigned
            serverRemotePeerInfo.agent,
            "nim-libp2p/0.0.1",
          )
          chainedComparison(
            clientPeerStore[ProtoVersionBook][serverPeerId], # FIXME: Not assigned
            serverRemotePeerInfo.protoVersion,
            "ipfs/0.1.0",
          )
          clientPeerStore[KeyBook][serverPeerId] == serverRemotePeerInfo.publicKey
          chainedComparison(
            clientPeerStore[ConnectionBook][serverPeerId],
            serverRemotePeerInfo.connectedness,
            NOT_CONNECTED,
          )
          chainedComparison(
            clientPeerStore[DisconnectBook][serverPeerId],
            serverRemotePeerInfo.disconnectTime,
            0,
          )
          chainedComparison(
            clientPeerStore[SourceBook][serverPeerId],
            serverRemotePeerInfo.origin,
            UnknownOrigin,
          )
          chainedComparison(
            clientPeerStore[DirectionBook][serverPeerId],
            serverRemotePeerInfo.direction,
            UnknownDirection,
          )
          chainedComparison(
            clientPeerStore[LastFailedConnBook][serverPeerId],
            serverRemotePeerInfo.lastFailedConn,
            Moment.init(0, Second),
          )
          chainedComparison(
            clientPeerStore[NumberFailedConnBook][serverPeerId],
            serverRemotePeerInfo.numberFailedConn,
            0,
          )

          # Server 2
          clientPeerStore[AddressBook][server2PeerId] == server2RemotePeerInfo.addrs
          clientPeerStore[ENRBook][server2PeerId].raw ==
            server2RemotePeerInfo.enr.get().raw
          chainedComparison(
            clientPeerStore[ProtoBook][server2PeerId],
            server2RemotePeerInfo.protocols,
            DEFAULT_PROTOCOLS,
          )
          chainedComparison(
            clientPeerStore[AgentBook][server2PeerId], # FIXME: Not assigned
            server2RemotePeerInfo.agent,
            "nim-libp2p/0.0.1",
          )
          chainedComparison(
            clientPeerStore[ProtoVersionBook][server2PeerId], # FIXME: Not assigned
            server2RemotePeerInfo.protoVersion,
            "ipfs/0.1.0",
          )
          clientPeerStore[KeyBook][serverPeerId] == server2RemotePeerInfo.publicKey
          chainedComparison(
            clientPeerStore[ConnectionBook][server2PeerId],
            server2RemotePeerInfo.connectedness,
            NOT_CONNECTED,
          )
          chainedComparison(
            clientPeerStore[DisconnectBook][server2PeerId],
            server2RemotePeerInfo.disconnectTime,
            0,
          )
          chainedComparison(
            clientPeerStore[SourceBook][server2PeerId],
            server2RemotePeerInfo.origin,
            UnknownOrigin,
          )
          chainedComparison(
            clientPeerStore[DirectionBook][server2PeerId],
            server2RemotePeerInfo.direction,
            UnknownDirection,
          )
          chainedComparison(
            clientPeerStore[LastFailedConnBook][server2PeerId],
            server2RemotePeerInfo.lastFailedConn,
            Moment.init(0, Second),
          )
          chainedComparison(
            clientPeerStore[NumberFailedConnBook][server2PeerId],
            server2RemotePeerInfo.numberFailedConn,
            0,
          )

      suite "Peer Connectivity States":
        asyncTest "State Tracking & Transition":
          # Given two correctly initialised nodes, but not connected
          (await server.mountRelay()).isOkOr:
            assert false, "Failed to mount relay"
          (await client.mountRelay()).isOkOr:
            assert false, "Failed to mount relay"

          # Then their connectedness should be NotConnected
          check:
            clientPeerStore.getPeer(serverPeerId).connectedness ==
              Connectedness.NotConnected
            serverPeerStore.getPeer(clientPeerId).connectedness ==
              Connectedness.NotConnected

          # When connecting the client to the server
          await client.connectToNodes(@[serverRemotePeerInfo])

          # Then both peers' connectedness should be Connected
          check:
            clientPeerStore.getPeer(serverPeerId).connectedness ==
              Connectedness.Connected
            serverPeerStore.getPeer(clientPeerId).connectedness ==
              Connectedness.Connected

          # When stopping the switches of either of the peers
          # (Running just one stop is enough to change the states in both peers, but I'll leave both calls as an example)
          await server.switch.stop()
          await client.switch.stop()

          # Then both peers are gracefully disconnected, and turned to CanConnect
          check:
            clientPeerStore.getPeer(serverPeerId).connectedness ==
              Connectedness.CanConnect
            serverPeerStore.getPeer(clientPeerId).connectedness ==
              Connectedness.CanConnect

          # When trying to connect those peers to a non-existent peer
          # Generate an invalid multiaddress, and patching both peerInfos with it so dialing fails
          let
            port = Port(8080)
            ipAddress = IpAddress(family: IPv4, address_v4: [192, 168, 0, 1])
            multiaddress =
              MultiAddress.init(ipAddress, IpTransportProtocol.tcpProtocol, port)
          serverRemotePeerInfo.addrs = @[multiaddress]
          clientRemotePeerInfo.addrs = @[multiaddress]
          await client.connectToNodes(@[serverRemotePeerInfo])
          await server.connectToNodes(@[clientRemotePeerInfo])

          # Then both peers should be marked as CannotConnect
          check:
            clientPeerStore.getPeer(serverPeerId).connectedness ==
              Connectedness.CannotConnect
            serverPeerStore.getPeer(clientPeerId).connectedness ==
              Connectedness.CannotConnect

      suite "Automatic Reconnection":
        asyncTest "Automatic Reconnection Implementation":
          # Given two correctly initialised nodes, that are available for reconnection
          (await server.mountRelay()).isOkOr:
            assert false, "Failed to mount relay"
          (await client.mountRelay()).isOkOr:
            assert false, "Failed to mount relay"
          await client.connectToNodes(@[serverRemotePeerInfo])

          waitActive:
            clientPeerStore.getPeer(serverPeerId).connectedness ==
              Connectedness.Connected and
              serverPeerStore.getPeer(clientPeerId).connectedness ==
              Connectedness.Connected

          await client.disconnectNode(serverRemotePeerInfo)

          waitActive:
            clientPeerStore.getPeer(serverPeerId).connectedness ==
              Connectedness.CanConnect and
              serverPeerStore.getPeer(clientPeerId).connectedness ==
              Connectedness.CanConnect

          # When triggering the reconnection
          await client.peerManager.reconnectPeers(WakuRelayCodec)

          # Then both peers should be marked as Connected
          waitActive:
            clientPeerStore.getPeer(serverPeerId).connectedness ==
              Connectedness.Connected and
              serverPeerStore.getPeer(clientPeerId).connectedness ==
              Connectedness.Connected

          ## Now let's do the same but with backoff period
          await client.disconnectNode(serverRemotePeerInfo)

          waitActive:
            clientPeerStore.getPeer(serverPeerId).connectedness ==
              Connectedness.CanConnect and
              serverPeerStore.getPeer(clientPeerId).connectedness ==
              Connectedness.CanConnect

          # When triggering a reconnection with a backoff period
          let backoffPeriod = chronos.seconds(1)
          let beforeReconnect = getTime().toUnixFloat()
          await client.peerManager.reconnectPeers(WakuRelayCodec, backoffPeriod)
          let reconnectDurationWithBackoffPeriod =
            getTime().toUnixFloat() - beforeReconnect

          # Then both peers should be marked as Connected
          check:
            clientPeerStore.getPeer(serverPeerId).connectedness ==
              Connectedness.Connected
            serverPeerStore.getPeer(clientPeerId).connectedness ==
              Connectedness.Connected
            reconnectDurationWithBackoffPeriod > backoffPeriod.seconds.float

suite "Handling Connections on Different Networks":
  # TODO: Implement after discv5 and peer manager's interaction is understood
  proc buildNode(
      tcpPort: uint16,
      udpPort: uint16,
      bindIp: string = "0.0.0.0",
      extIp: string = "127.0.0.1",
      indices: seq[uint64] = @[],
      recordFlags: Option[CapabilitiesBitfield] = none(CapabilitiesBitfield),
      bootstrapRecords: seq[waku_enr.Record] = @[],
  ): (WakuDiscoveryV5, Record) =
    let
      privKey = generateSecp256k1Key()
      record = newTestEnrRecord(
        privKey = privKey,
        extIp = extIp,
        tcpPort = tcpPort,
        udpPort = udpPort,
        indices = indices,
        flags = recordFlags,
      )
      node = newTestDiscv5(
        privKey = privKey,
        bindIp = bindIp,
        tcpPort = tcpPort,
        udpPort = udpPort,
        record = record,
        bootstrapRecords = bootstrapRecords,
      )

    (node, record)

  asyncTest "Same cluster but different shard":
    # peer 1 is on cluster x - shard a  ; peer 2 is on cluster x - shard b
    # todo: Implement after discv5 and peer manager's interaction is understood
    discard

  xasyncTest "Different cluster but same shard":
    # peer 1 is on cluster x - shard a  ; peer 2 is on cluster y - shard a
    # todo: Implement after discv5 and peer manager's interaction is understood
    discard

  xasyncTest "Different cluster and different shard":
    # peer 1 is on cluster x - shard a  ; peer 2 is on cluster y - shard b
    # todo: Implement after discv5 and peer manager's interaction is understood
    discard

  xasyncTest "Same cluster with multiple shards (one shared)":
    # peer 1 is on cluster x - shard [a,b,c]  ; peer 2 is on cluster x - shard [c, d, e]
    # todo: Implement after discv5 and peer manager's interaction is understood
    discard

const baseDbPath = "./peers.test.db"
proc cleanupDb() =
  os.removeFile(baseDbPath)
  os.removeFile(baseDbPath & "-shm")
  os.removeFile(baseDbPath & "-wal")

suite "Persistence Check":
  asyncTest "PeerStorage exists":
    # Cleanup previous existing db
    cleanupDb()

    # Given an on-disk peer db exists, with a peer in it; and two connected nodes
    let
      clientPeerStorage = newTestWakuPeerStorage(some(baseDbPath))
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, listenIp, listenPort)
      client = newTestWakuNode(
        clientKey, listenIp, listenPort, peerStorage = clientPeerStorage
      )
      serverPeerStore = server.peerManager.switch.peerStore
      clientPeerStore = client.peerManager.switch.peerStore

    await allFutures(server.start(), client.start())

    await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])
    check:
      clientPeerStore.peers().len == 1

    await allFutures(server.stop(), client.stop())

    # When initializing a new client using the prepopulated on-disk storage
    let
      newClientPeerStorage = newTestWakuPeerStorage(some(baseDbPath))
      newClient = newTestWakuNode(
        clientKey, listenIp, listenPort, peerStorage = newClientPeerStorage
      )
      newClientPeerStore = newClient.peerManager.switch.peerStore

    await newClient.start()

    # Then the new client should have the same peer in its peer store
    check:
      newClientPeerStore.peers().len == 1

    # Cleanup
    await newClient.stop()
    cleanupDb()

  asyncTest "PeerStorage exists but no data":
    # Cleanup previous existing db
    cleanupDb()

    # When creating a new server with memory storage, and a client with on-disk peer storage
    let
      clientPeerStorage = newTestWakuPeerStorage(some(baseDbPath))
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, listenIp, listenPort)
      client = newTestWakuNode(
        clientKey, listenIp, listenPort, peerStorage = clientPeerStorage
      )
      serverPeerStore = server.peerManager.switch.peerStore
      clientPeerStore = client.peerManager.switch.peerStore

    await allFutures(server.start(), client.start())

    # Then the client's peer store should be empty
    check:
      clientPeerStore.peers().len == 0

    # Cleanup
    await allFutures(server.stop(), client.stop())
    cleanupDb()

  asyncTest "PeerStorage not exists":
    # When creating a new server and client, both without peer storage
    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, listenIp, listenPort)
      client = newTestWakuNode(clientKey, listenIp, listenPort)
      serverPeerStore = server.peerManager.switch.peerStore
      clientPeerStore = client.peerManager.switch.peerStore

    await allFutures(server.start(), client.start())

    # Then the client's peer store should be empty
    check:
      clientPeerStore.peers().len == 0

    # Cleanup
    await allFutures(server.stop(), client.stop())

suite "Mount Order":
  var
    client {.threadvar.}: WakuNode
    clientRemotePeerInfo {.threadvar.}: RemotePeerInfo
    clientPeerStore {.threadvar.}: PeerStore

  asyncSetup:
    let clientKey = generateSecp256k1Key()

    client = newTestWakuNode(clientKey, listenIp, listenPort)
    clientPeerStore = client.peerManager.switch.peerStore

    await client.start()

    clientRemotePeerInfo = client.switch.peerInfo.toRemotePeerInfo()

  asyncTeardown:
    await client.stop()

  asyncTest "protocol-start-info":
    # Given a server that is initiaalised in the order defined in the title
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, listenIp, listenPort)

    (await server.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await server.start()
    let
      serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      serverPeerId = serverRemotePeerInfo.peerId

    # When connecting to the server
    await client.connectToNodes(@[serverRemotePeerInfo])

    # Then the peer store should contain the peer with the mounted protocol
    check:
      clientPeerStore.peerExists(serverPeerId)
      clientPeerStore.getPeer(serverPeerId).protocols ==
        DEFAULT_PROTOCOLS & @[WakuRelayCodec]

    # Cleanup
    await server.stop()

  asyncTest "protocol-info-start":
    # Given a server that is initialised in the order defined in the title
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, listenIp, listenPort)

    (await server.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    let
      serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      serverPeerId = serverRemotePeerInfo.peerId
    await server.start()

    # When connecting to the server
    await client.connectToNodes(@[serverRemotePeerInfo])

    # Then the peer store should contain the peer with the mounted protocol
    check:
      clientPeerStore.peerExists(serverPeerId)
      clientPeerStore.getPeer(serverPeerId).protocols ==
        DEFAULT_PROTOCOLS & @[WakuRelayCodec]

    # Cleanup
    await server.stop()

  asyncTest "start-protocol-info":
    # Given a server that is initialised in the order defined in the title
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, listenIp, listenPort)

    await server.start()
    (await server.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    let
      serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      serverPeerId = serverRemotePeerInfo.peerId

    # When connecting to the server
    await client.connectToNodes(@[serverRemotePeerInfo])

    # Then the peer store should contain the peer with the mounted protocol
    check:
      clientPeerStore.peerExists(serverPeerId)
      clientPeerStore.getPeer(serverPeerId).protocols ==
        DEFAULT_PROTOCOLS & @[WakuRelayCodec]

    # Cleanup
    await server.stop()

  asyncTest "start-info-protocol":
    # Given a server that is initialised in the order defined in the title
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, listenIp, listenPort)

    await server.start()
    let
      serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      serverPeerId = serverRemotePeerInfo.peerId
    (await server.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    # When connecting to the server
    await client.connectToNodes(@[serverRemotePeerInfo])

    # Then the peer store should contain the peer with the mounted protocol
    check:
      clientPeerStore.peerExists(serverPeerId)
      clientPeerStore.getPeer(serverPeerId).protocols ==
        DEFAULT_PROTOCOLS & @[WakuRelayCodec]

    # Cleanup
    await server.stop()

  asyncTest "info-start-protocol":
    # Given a server that is initialised in the order defined in the title
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, listenIp, listenPort)

    let
      serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      serverPeerId = serverRemotePeerInfo.peerId
    await server.start()
    (await server.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    # When connecting to the server
    await client.connectToNodes(@[serverRemotePeerInfo])

    # Then the peer store should contain the peer but not the mounted protocol
    check:
      clientPeerStore.peerExists(serverPeerId)
      clientPeerStore.getPeer(serverPeerId).protocols == DEFAULT_PROTOCOLS

    # Cleanup
    await server.stop()

  asyncTest "info-protocol-start":
    # Given a server that is initialised in the order defined in the title
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, listenIp, listenPort)

    let
      serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      serverPeerId = serverRemotePeerInfo.peerId
    (await server.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await server.start()

    # When connecting to the server
    await client.connectToNodes(@[serverRemotePeerInfo])

    # Then the peer store should contain the peer but not the mounted protocol
    check:
      clientPeerStore.peerExists(serverPeerId)
      clientPeerStore.getPeer(serverPeerId).protocols == DEFAULT_PROTOCOLS

    # Cleanup
    await server.stop()

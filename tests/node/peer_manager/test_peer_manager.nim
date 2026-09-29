{.used.}

import results, chronicles, std/tables, chronos, testutils/unittests

import
  logos_delivery/waku/waku_node,
  logos_delivery/waku/waku_core,
  ../../waku_lightpush/[lightpush_utils],
  ../../testlib/[wakucore, wakunode, futures, testasync],
  logos_delivery/waku/node/peer_manager/peer_manager

suite "Peer Manager":
  suite "refreshPeerMetadata":
    var
      listenPort {.threadvar.}: Port
      listenAddress {.threadvar.}: IpAddress
      serverKey {.threadvar.}: PrivateKey
      clientKey {.threadvar.}: PrivateKey
      clusterId {.threadvar.}: uint16

    asyncSetup:
      listenPort = Port(0)
      listenAddress = parseIpAddress("0.0.0.0")
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()
      clusterId = 1

    asyncTest "light client is not disconnected":
      # Given two nodes with different shardIds
      let
        server = newTestWakuNode(
          serverKey,
          listenAddress,
          listenPort,
          clusterId = clusterId,
          subscribeShards = @[0'u16],
        )
        client = newTestWakuNode(
          clientKey,
          listenAddress,
          listenPort,
          clusterId = clusterId,
          subscribeShards = @[1'u16],
        )

      # And both mount metadata and filter
      discard
        client.mountMetadata(0, @[1'u16]) # clusterId irrelevant, overridden by topic
      discard
        server.mountMetadata(0, @[0'u16]) # clusterId irrelevant, overridden by topic
      await client.mountFilterClient()
      await server.mountFilter()

      # And both nodes are started
      await allFutures(server.start(), client.start())

      # And the nodes are connected
      let serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      await client.connectToNodes(@[serverRemotePeerInfo])
      checkUntilTimeout:
        client.switch.peerStore.hasShard(serverRemotePeerInfo.peerId, clusterId, 0)
        server.switch.peerStore.hasShard(client.switch.peerInfo.peerId, clusterId, 1)

      # When the client issues a filter request
      discard await client.filterSubscribe(
        Opt.some("/waku/2/rs/0/0"), "waku/lightpush/1", serverRemotePeerInfo
      )

      check:
        server.switch.isConnected(client.switch.peerInfo.toRemotePeerInfo().peerId)
        client.switch.isConnected(server.switch.peerInfo.toRemotePeerInfo().peerId)

    asyncTest "relay with same shardId is not disconnected":
      # Given two nodes with the same shardId
      let
        server = newTestWakuNode(
          serverKey,
          listenAddress,
          listenPort,
          clusterId = clusterId,
          subscribeShards = @[0'u16],
        )
        client = newTestWakuNode(
          clientKey,
          listenAddress,
          listenPort,
          clusterId = clusterId,
          subscribeShards = @[0'u16],
        )

      # And both mount metadata and relay
      discard
        client.mountMetadata(0, @[0'u16]) # clusterId irrelevant, overridden by topic
      discard
        server.mountMetadata(0, @[0'u16]) # clusterId irrelevant, overridden by topic
      (await client.mountRelay()).isOkOr:
        assert false, "Failed to mount relay"
      (await server.mountRelay()).isOkOr:
        assert false, "Failed to mount relay"

      # And both nodes are started
      await allFutures(server.start(), client.start())

      # And the nodes are connected
      let serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      await client.connectToNodes(@[serverRemotePeerInfo])
      checkUntilTimeout:
        client.switch.peerStore.hasShard(serverRemotePeerInfo.peerId, clusterId, 0)
        server.switch.peerStore.hasShard(client.switch.peerInfo.peerId, clusterId, 0)

      # When the client subscribes to a relay topic
      client.subscribe((kind: SubscriptionKind.PubsubSub, topic: "newTopic"), nil).isOkOr:
        assert false, "Failed to subscribe to relay"
      checkUntilTimeout:
        server.hasGossipsubPeer("newTopic", client.switch.peerInfo.peerId)

      check:
        server.switch.isConnected(client.switch.peerInfo.toRemotePeerInfo().peerId)
        client.switch.isConnected(server.switch.peerInfo.toRemotePeerInfo().peerId)

    asyncTest "relay with different shardId is not disconnected":
      # Given two nodes with different shardIds
      let
        server = newTestWakuNode(
          serverKey,
          listenAddress,
          listenPort,
          clusterId = clusterId,
          subscribeShards = @[0'u16],
        )
        client = newTestWakuNode(
          clientKey,
          listenAddress,
          listenPort,
          clusterId = clusterId,
          subscribeShards = @[1'u16],
        )

      # And both mount metadata and relay
      discard
        client.mountMetadata(0, @[1'u16]) # clusterId irrelevant, overridden by topic
      discard
        server.mountMetadata(0, @[0'u16]) # clusterId irrelevant, overridden by topic
      (await client.mountRelay()).isOkOr:
        assert false, "Failed to mount relay"
      (await server.mountRelay()).isOkOr:
        assert false, "Failed to mount relay"

      # And both nodes are started
      await allFutures(server.start(), client.start())

      # And the nodes are connected
      let serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      await client.connectToNodes(@[serverRemotePeerInfo])
      checkUntilTimeout:
        client.switch.peerStore.hasShard(serverRemotePeerInfo.peerId, clusterId, 0)
        server.switch.peerStore.hasShard(client.switch.peerInfo.peerId, clusterId, 1)

      # When the client subscribes to a relay topic
      client.subscribe((kind: SubscriptionKind.PubsubSub, topic: "newTopic"), nil).isOkOr:
        assert false, "Failed to subscribe to relay"
      checkUntilTimeout:
        server.hasGossipsubPeer("newTopic", client.switch.peerInfo.peerId)

      check:
        # the metadata exchange ran and recorded the disjoint shard sets
        client.switch.peerStore[ShardBook][serverRemotePeerInfo.peerId] == @[0'u16]
        server.switch.peerStore[ShardBook][client.switch.peerInfo.peerId] == @[1'u16]
        server.switch.isConnected(client.switch.peerInfo.toRemotePeerInfo().peerId)
        client.switch.isConnected(server.switch.peerInfo.toRemotePeerInfo().peerId)

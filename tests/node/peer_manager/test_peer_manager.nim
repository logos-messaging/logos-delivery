import chronicles, std/[options, tables, strutils], chronos, testutils/unittests

import
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/waku_core,
  ../../waku_lightpush/[lightpush_utils],
  ../../testlib/[wakucore, wakunode, futures, testasync],
  logos_delivery/waku/node/peer_manager/peer_manager

suite "Peer Manager":
  suite "onPeerMetadata":
    var
      listenPort {.threadvar.}: Port
      listenAddress {.threadvar.}: IpAddress
      serverKey {.threadvar.}: PrivateKey
      clientKey {.threadvar.}: PrivateKey
      clusterId {.threadvar.}: uint64

    asyncSetup:
      listenPort = Port(0)
      listenAddress = parseIpAddress("0.0.0.0")
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()
      clusterId = 1

    asyncTest "light client is not disconnected":
      # Given two nodes with the same shardId
      let
        server = newTestWakuNode(
          serverKey, listenAddress, listenPort, clusterId = clusterId, shards = @[0]
        )
        client = newTestWakuNode(
          clientKey, listenAddress, listenPort, clusterId = clusterId, shards = @[1]
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
      await sleepAsync(FUTURE_TIMEOUT)

      # And the nodes are connected
      let serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      await client.connectToNodes(@[serverRemotePeerInfo])
      await sleepAsync(FUTURE_TIMEOUT)

      # When making an operation that triggers onPeerMetadata
      discard await client.filterSubscribe(
        some("/waku/2/rs/0/0"), "waku/lightpush/1", serverRemotePeerInfo
      )
      await sleepAsync(FUTURE_TIMEOUT)

      check:
        server.switch.isConnected(client.switch.peerInfo.toRemotePeerInfo().peerId)
        client.switch.isConnected(server.switch.peerInfo.toRemotePeerInfo().peerId)

    asyncTest "relay with same shardId is not disconnected":
      # Given two nodes with the same shardId
      let
        server = newTestWakuNode(
          serverKey, listenAddress, listenPort, clusterId = clusterId, shards = @[0]
        )
        client = newTestWakuNode(
          clientKey, listenAddress, listenPort, clusterId = clusterId, shards = @[1]
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
      await sleepAsync(FUTURE_TIMEOUT)

      # And the nodes are connected
      let serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      await client.connectToNodes(@[serverRemotePeerInfo])
      await sleepAsync(FUTURE_TIMEOUT)

      # When making an operation that triggers onPeerMetadata
      client.subscribe((kind: SubscriptionKind.PubsubSub, topic: "newTopic")).isOkOr:
        assert false, "Failed to subscribe to relay"
      await sleepAsync(FUTURE_TIMEOUT)

      check:
        server.switch.isConnected(client.switch.peerInfo.toRemotePeerInfo().peerId)
        client.switch.isConnected(server.switch.peerInfo.toRemotePeerInfo().peerId)

    asyncTest "relay with different shardId is disconnected":
      # Given two nodes with different shardIds
      let
        server = newTestWakuNode(
          serverKey, listenAddress, listenPort, clusterId = clusterId, shards = @[0]
        )
        client = newTestWakuNode(
          clientKey, listenAddress, listenPort, clusterId = clusterId, shards = @[1]
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
      await sleepAsync(FUTURE_TIMEOUT)

      # And the nodes are connected
      let serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      await client.connectToNodes(@[serverRemotePeerInfo])
      await sleepAsync(FUTURE_TIMEOUT)

      # When making an operation that triggers onPeerMetadata
      client.subscribe((kind: SubscriptionKind.PubsubSub, topic: "newTopic")).isOkOr:
        assert false, "Failed to subscribe to relay"
      await sleepAsync(FUTURE_TIMEOUT)

      check:
        not server.switch.isConnected(client.switch.peerInfo.toRemotePeerInfo().peerId)
        not client.switch.isConnected(server.switch.peerInfo.toRemotePeerInfo().peerId)

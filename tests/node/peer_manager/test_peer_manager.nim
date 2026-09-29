{.used.}

import results, chronicles, std/[tables, strutils], chronos, testutils/unittests

import
  libp2p/protocols/protocol,
  libp2p/crypto/curve25519,
  libp2p_mix/mix_protocol,
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

    proc checkMixConnection(registered, metadata: bool, quic = false) {.async.} =
      let server = newTestWakuNode(
        serverKey, listenAddress, listenPort, clusterId = 2, quicEnabled = quic
      )
      let client = newTestWakuNode(
        clientKey, listenAddress, listenPort, clusterId = 1, quicEnabled = quic
      )
      discard client.mountMetadata(1, @[0'u16])
      if metadata:
        discard server.mountMetadata(2, @[0'u16])
      let mix = LPProtocol(codecs: @[MixProtocolID])
      mix.handler = proc(
          stream: Stream, proto: string
      ) {.async: (raises: [CancelledError]).} =
        await stream.close()
      server.switch.mount(mix)
      await allFutures(server.start(), client.start())
      try:
        var peer = server.switch.peerInfo.toRemotePeerInfo()
        peer.protocols = @[] # Peer records supply keys and addresses, before Identify.
        var key: Curve25519Key
        key[0] = 1
        if registered:
          peer.mixPubKey = Opt.some(key)
        client.peerManager.addPeer(peer)
        await client.connectToNodes(@[peer])
        await sleepAsync(FUTURE_TIMEOUT)
        check client.switch.isConnected(peer.peerId) == (registered and not metadata)
      finally:
        await allFutures(server.stop(), client.stop())

    asyncTest "registered Mix-only peer stays connected without Waku metadata":
      await checkMixConnection(true, false)

    asyncTest "unregistered Mix peer still requires Waku metadata":
      await checkMixConnection(false, false)

    asyncTest "registered Mix peer advertising Waku metadata must match cluster":
      await checkMixConnection(true, true)

    asyncTest "registered Mix-only peer stays connected over QUIC":
      await checkMixConnection(true, false, quic = true)

    asyncTest "unregistered Mix peer still requires metadata over QUIC":
      await checkMixConnection(false, false, quic = true)

    asyncTest "registered Mix peer must match cluster over QUIC":
      await checkMixConnection(true, true, quic = true)

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
      await sleepAsync(FUTURE_TIMEOUT)

      # And the nodes are connected
      let serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      await client.connectToNodes(@[serverRemotePeerInfo])
      await sleepAsync(FUTURE_TIMEOUT)

      # When the client issues a filter request
      discard await client.filterSubscribe(
        Opt.some("/waku/2/rs/0/0"), "waku/lightpush/1", serverRemotePeerInfo
      )
      await sleepAsync(FUTURE_TIMEOUT)

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
      await sleepAsync(FUTURE_TIMEOUT)

      # And the nodes are connected
      let serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      await client.connectToNodes(@[serverRemotePeerInfo])
      await sleepAsync(FUTURE_TIMEOUT)

      # When the client subscribes to a relay topic
      client.subscribe((kind: SubscriptionKind.PubsubSub, topic: "newTopic"), nil).isOkOr:
        assert false, "Failed to subscribe to relay"
      await sleepAsync(FUTURE_TIMEOUT)

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
      await sleepAsync(FUTURE_TIMEOUT)

      # And the nodes are connected
      let serverRemotePeerInfo = server.switch.peerInfo.toRemotePeerInfo()
      await client.connectToNodes(@[serverRemotePeerInfo])
      await sleepAsync(FUTURE_TIMEOUT)

      # When the client subscribes to a relay topic
      client.subscribe((kind: SubscriptionKind.PubsubSub, topic: "newTopic"), nil).isOkOr:
        assert false, "Failed to subscribe to relay"
      await sleepAsync(FUTURE_TIMEOUT)

      check:
        # the metadata exchange ran and recorded the disjoint shard sets
        client.switch.peerStore[ShardBook][serverRemotePeerInfo.peerId] == @[0'u16]
        server.switch.peerStore[ShardBook][client.switch.peerInfo.peerId] == @[1'u16]
        server.switch.isConnected(client.switch.peerInfo.toRemotePeerInfo().peerId)
        client.switch.isConnected(server.switch.peerInfo.toRemotePeerInfo().peerId)

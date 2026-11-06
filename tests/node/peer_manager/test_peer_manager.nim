{.used.}

import results, chronicles, std/[tables, strutils], chronos, testutils/unittests

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

  suite "selectInRelayPeersToPrune":
    let now = Moment.now()
    let rng = crypto.newRng()

    proc inPeer(age: Duration, usesService = false): InRelayPeer =
      InRelayPeer(
        peerId: PeerId.random(rng).get(),
        connectedAt: now - age,
        usesServiceProtocol: usesService,
      )

    test "late joiners in the grace period are kept":
      let fresh = inPeer(chronos.seconds(10))
      let old = inPeer(chronos.minutes(30))

      check selectInRelayPeersToPrune([fresh, old], 2, now) == @[old.peerId]

    test "longest-connected peers are pruned first":
      let a = inPeer(chronos.minutes(10))
      let b = inPeer(chronos.minutes(60))
      let c = inPeer(chronos.minutes(30))

      check selectInRelayPeersToPrune([a, b, c], 2, now) == @[b.peerId, c.peerId]

    test "relay-only peers are pruned before service clients":
      let client = inPeer(chronos.minutes(60), usesService = true)
      let relayOnly = inPeer(chronos.minutes(10))

      check selectInRelayPeersToPrune([client, relayOnly], 1, now) == @[
        relayOnly.peerId
      ]

    test "non-positive amount prunes nothing":
      let old = inPeer(chronos.minutes(30))

      check:
        selectInRelayPeersToPrune([old], 0, now).len == 0
        selectInRelayPeersToPrune([old], -1, now).len == 0

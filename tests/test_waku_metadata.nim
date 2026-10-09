{.used.}

import
  std/[algorithm, sequtils, tables],
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/switch,
  libp2p/peerId,
  libp2p/crypto/crypto,
  libp2p/multistream,
  libp2p/muxers/muxer,
  eth/keys,
  eth/p2p/discoveryv5/enr
import
  logos_delivery/waku/[
    waku_node,
    waku_core/topics,
    waku_core,
    node/peer_manager,
    discovery/waku_discv5,
    waku_metadata,
    waku_relay/protocol,
  ],
  ./testlib/wakucore,
  ./testlib/wakunode,
  ./testlib/testasync

procSuite "Waku Metadata Protocol":
  asyncTest "request() returns the supported metadata of the peer":
    let clusterId = 10.uint16
    let
      node1 = newTestWakuNode(generateSecp256k1Key(), clusterId = clusterId)
      node2 = newTestWakuNode(generateSecp256k1Key(), clusterId = clusterId)

    # Mount metadata protocol on both nodes before starting
    discard node1.mountMetadata(clusterId, @[])
    discard node2.mountMetadata(clusterId, @[])

    # Mount relay so metadata can track subscriptions
    discard await node1.mountRelay()
    discard await node2.mountRelay()

    # Start nodes
    await allFutures([node1.start(), node2.start()])

    # Subscribe to topics on node1 - relay will track these and metadata will report them
    let noOpHandler: WakuRelayHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[void] {.async.} =
      discard

    node1.wakuRelay.subscribe("/waku/2/rs/10/7", noOpHandler)
    node1.wakuRelay.subscribe("/waku/2/rs/10/6", noOpHandler)

    # Create connection
    let connOpt = await node2.peerManager.dialPeer(
      node1.switch.peerInfo.toRemotePeerInfo(), WakuMetadataCodec
    )
    require:
      connOpt.isSome()

    # Request metadata
    let response1 = await node2.wakuMetadata.request(connOpt.get())

    # Check the response or dont even continue
    require:
      response1.isOk()

    check:
      response1.get().clusterId.get() == clusterId
      response1.get().shards == @[uint32(6), uint32(7)]

    await allFutures([node1.stop(), node2.stop()])

  asyncTest "Metadata reports configured shards before relay subscription":
    ## Given: Node with configured shards but no relay subscriptions yet
    let
      clusterId = 10.uint16
      configuredShards = @[uint16(0), uint16(1)]

    let node1 = newTestWakuNode(
      generateSecp256k1Key(), clusterId = clusterId, subscribeShards = configuredShards
    )
    let node2 = newTestWakuNode(generateSecp256k1Key(), clusterId = clusterId)

    # Mount metadata with configured shards on node1
    discard node1.mountMetadata(clusterId, configuredShards)
    # Mount metadata on node2 so it can make requests
    discard node2.mountMetadata(clusterId, @[])

    # Start nodes (relay is NOT mounted yet on node1)
    await allFutures([node1.start(), node2.start()])

    ## When: Node2 requests metadata from Node1 before relay is active
    let connOpt = await node2.peerManager.dialPeer(
      node1.switch.peerInfo.toRemotePeerInfo(), WakuMetadataCodec
    )
    require:
      connOpt.isSome

    let response = await node2.wakuMetadata.request(connOpt.get())

    ## Then: Response contains configured shards even without relay subscriptions
    require:
      response.isOk()

    check:
      response.get().clusterId.get() == clusterId
      response.get().shards == @[uint32(0), uint32(1)]

    await allFutures([node1.stop(), node2.stop()])

  asyncTest "Metadata reports configured shards once the relay holds a shard of another cluster":
    # TODO: logos-delivery#4457
    let clusterId = 10.uint16
    let
      node1 = newTestWakuNode(
        generateSecp256k1Key(), clusterId = clusterId, subscribeShards = @[uint16(0)]
      )
      node2 = newTestWakuNode(generateSecp256k1Key(), clusterId = clusterId)
      node3 = newTestWakuNode(generateSecp256k1Key(), clusterId = clusterId)

    discard node1.mountMetadata(clusterId, @[uint16(0)])
    discard node2.mountMetadata(clusterId, @[])
    discard node3.mountMetadata(clusterId, @[])
    discard await node1.mountRelay()

    await allFutures([node1.start(), node2.start(), node3.start()])

    let noOpHandler: WakuRelayHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[void] {.async.} =
      discard

    ## Given: Node1's relay on shards 0 and 1 of its cluster
    node1.wakuRelay.subscribe("/waku/2/rs/10/0", noOpHandler)
    node1.wakuRelay.subscribe("/waku/2/rs/10/1", noOpHandler)

    ## When: Node2 connects to it
    let node2Connected =
      await node2.peerManager.connectPeer(node1.switch.peerInfo.toRemotePeerInfo())

    ## Then: Node2 learns both shards
    check node2Connected
    checkUntilTimeout:
      node2.peerManager.switch.peerStore
        .getPeer(node1.switch.peerInfo.peerId).shards
        .sorted() == @[uint16(0), uint16(1)]

    ## Given: Node1's relay also on shard 0 of cluster 199
    node1.wakuRelay.subscribe("/waku/2/rs/199/0", noOpHandler)

    ## When: Node3 connects to it
    let node3Connected =
      await node3.peerManager.connectPeer(node1.switch.peerInfo.toRemotePeerInfo())

    ## Then: Node3 learns only the configured shard, though node1's relay is still on shard 1
    check:
      node3Connected
      node1.wakuRelay.isSubscribed("/waku/2/rs/10/1")
    checkUntilTimeout:
      node3.peerManager.switch.peerStore.getPeer(node1.switch.peerInfo.peerId).shards ==
        @[uint16(0)]

    await allFutures([node1.stop(), node2.stop(), node3.stop()])

  asyncTest "Metadata reports a shard of another cluster as a shard of the node's own cluster":
    # TODO: logos-delivery#4457
    let clusterId = 10.uint16
    let
      node1 = newTestWakuNode(
        generateSecp256k1Key(), clusterId = clusterId, subscribeShards = @[]
      )
      node2 = newTestWakuNode(generateSecp256k1Key(), clusterId = clusterId)

    discard node1.mountMetadata(clusterId, @[])
    discard node2.mountMetadata(clusterId, @[])
    discard await node1.mountRelay()

    await allFutures([node1.start(), node2.start()])

    let noOpHandler: WakuRelayHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[void] {.async.} =
      discard

    ## Given: Node1's relay only on shard 3 of cluster 199
    node1.wakuRelay.subscribe("/waku/2/rs/199/3", noOpHandler)

    ## When: Node2, of cluster 10, connects to it
    let connected =
      await node2.peerManager.connectPeer(node1.switch.peerInfo.toRemotePeerInfo())

    ## Then: Node2 records node1 on shard 3, which node1's relay is not on
    check:
      connected
      not node1.wakuRelay.isSubscribed("/waku/2/rs/10/3")
    checkUntilTimeout:
      node2.peerManager.switch.peerStore.getPeer(node1.switch.peerInfo.peerId).shards ==
        @[uint16(3)]

    await allFutures([node1.stop(), node2.stop()])

  asyncTest "A peer of another cluster is disconnected although the relay holds a shard of that cluster":
    # TODO: logos-delivery#4457
    let
      node1 = newTestWakuNode(
        generateSecp256k1Key(), clusterId = 10, subscribeShards = @[uint16(0)]
      )
      node2 = newTestWakuNode(
        generateSecp256k1Key(), clusterId = 199, subscribeShards = @[uint16(0)]
      )

    discard node1.mountMetadata(10, @[uint16(0)])
    discard node2.mountMetadata(199, @[uint16(0)])
    discard await node1.mountRelay()
    discard await node2.mountRelay()

    await allFutures([node1.start(), node2.start()])

    let noOpHandler: WakuRelayHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[void] {.async.} =
      discard

    ## Given: Both relays on shard 0 of cluster 199, node1 also on shard 0 of cluster 10
    node1.wakuRelay.subscribe("/waku/2/rs/10/0", noOpHandler)
    node1.wakuRelay.subscribe("/waku/2/rs/199/0", noOpHandler)
    node2.wakuRelay.subscribe("/waku/2/rs/199/0", noOpHandler)

    ## When: Node1 connects to node2
    let connected =
      await node1.peerManager.connectPeer(node2.switch.peerInfo.toRemotePeerInfo())

    ## Then: The connection is closed on both sides
    check connected
    checkUntilTimeout:
      not node1.switch.isConnected(node2.switch.peerInfo.peerId)
      not node2.switch.isConnected(node1.switch.peerInfo.peerId)

    await allFutures([node1.stop(), node2.stop()])

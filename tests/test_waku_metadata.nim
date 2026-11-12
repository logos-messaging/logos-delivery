{.used.}

import
  std/[algorithm, sequtils],
  testutils/unittests,
  stew/byteutils,
  chronos,
  libp2p/switch,
  libp2p/peerId,
  libp2p/crypto/crypto,
  eth/common/keys,
  eth/p2p/discoveryv5/enr
import
  logos_delivery/waku/[
    waku_node,
    waku_core/topics,
    waku_core,
    node/peer_manager,
    discovery/waku_discv5,
    waku_metadata,
    waku_metadata/rpc,
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

    # Relay is mounted on node1 but not subscribed to any shard yet
    (await node1.mountRelay()).isOkOr:
      raiseAssert error
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

  asyncTest "Metadata of a node without relay advertises no shards":
    ## Given: an edge node with configured shards and no relay
    let clusterId = 10.uint16
    let node1 = newTestWakuNode(
      generateSecp256k1Key(), clusterId = clusterId, subscribeShards = @[uint16(0)]
    )
    let node2 = newTestWakuNode(generateSecp256k1Key(), clusterId = clusterId)
    discard node1.mountMetadata(clusterId, @[uint16(0)])
    discard node2.mountMetadata(clusterId, @[])
    await allFutures([node1.start(), node2.start()])
    defer:
      await allFutures([node1.stop(), node2.stop()])

    ## When: node2 requests node1's metadata
    let connOpt = await node2.peerManager.dialPeer(
      node1.switch.peerInfo.toRemotePeerInfo(), WakuMetadataCodec
    )
    require:
      connOpt.isSome
    let response = await node2.wakuMetadata.request(connOpt.get())

    ## Then: the cluster is reported but the shard list is empty
    require:
      response.isOk()
    check:
      response.get().clusterId.get() == clusterId
      response.get().shards.len == 0

  asyncTest "A shard of another cluster is refused and metadata keeps reporting the relay's shards":
    let clusterId = 10.uint16
    let
      node1 = newTestWakuNode(
        generateSecp256k1Key(), clusterId = clusterId, subscribeShards = @[uint16(0)]
      )
      node2 = newTestWakuNode(generateSecp256k1Key(), clusterId = clusterId)

    discard node1.mountMetadata(clusterId, @[uint16(0)])
    discard node2.mountMetadata(clusterId, @[])
    discard await node1.mountRelay()

    await allFutures([node1.start(), node2.start()])

    let noOpHandler: WakuRelayHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[void] {.async.} =
      discard

    ## Given: Node1's relay on shards 0 and 1 of its cluster
    check:
      node1.subscribe((kind: PubsubSub, topic: "/waku/2/rs/10/0"), noOpHandler).isOk()
      node1.subscribe((kind: PubsubSub, topic: "/waku/2/rs/10/1"), noOpHandler).isOk()

    ## When: Node1 subscribes to a shard of another cluster
    let otherClusterRes =
      node1.subscribe((kind: PubsubSub, topic: "/waku/2/rs/199/0"), noOpHandler)

    ## Then: It is refused
    check:
      otherClusterRes.isErr()
      not node1.wakuRelay.isSubscribed("/waku/2/rs/199/0")

    ## When: Node2 connects to it
    let connected =
      await node2.peerManager.connectPeer(node1.switch.peerInfo.toRemotePeerInfo())

    ## Then: Node2 learns both shards of the relay
    check connected
    checkUntilTimeout:
      node2.peerManager.switch.peerStore
        .getPeer(node1.switch.peerInfo.peerId).shards
        .sorted() == @[uint16(0), uint16(1)]

    await allFutures([node1.stop(), node2.stop()])

  asyncTest "A peer of another cluster is disconnected":
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

    ## When: Node1 connects to node2
    let connected =
      await node1.peerManager.connectPeer(node2.switch.peerInfo.toRemotePeerInfo())

    ## Then: The connection is closed on both sides
    check connected
    checkUntilTimeout:
      not node1.switch.isConnected(node2.switch.peerInfo.peerId)
      not node2.switch.isConnected(node1.switch.peerInfo.peerId)

    await allFutures([node1.stop(), node2.stop()])

  asyncTest "A lightpush peer is not selected for a shard it joins later":
    # TODO: logos-delivery#4591
    let clusterId = 10.uint16
    let
      node1 = newTestWakuNode(
        generateSecp256k1Key(), clusterId = clusterId, subscribeShards = @[0'u16]
      )
      node2 = newTestWakuNode(generateSecp256k1Key(), clusterId = clusterId)

    discard node1.mountMetadata(clusterId, @[0'u16])
    discard node2.mountMetadata(clusterId, @[])
    discard await node1.mountRelay()
    check (await node1.mountLightPush()).isOk()

    await allFutures([node1.start(), node2.start()])
    defer:
      await allFutures([node1.stop(), node2.stop()])

    let noOpHandler: WakuRelayHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[void] {.async.} =
      discard

    let node1Info = node1.switch.peerInfo.toRemotePeerInfo()

    check:
      node1.subscribe((kind: PubsubSub, topic: "/waku/2/rs/10/0"), noOpHandler).isOk()

    let connected = await node2.peerManager.connectPeer(node1Info)

    check connected
    checkUntilTimeout:
      node2.peerManager.switch.peerStore.getPeer(node1Info.peerId).shards == @[0'u16]

    check:
      node1.subscribe((kind: PubsubSub, topic: "/waku/2/rs/10/1"), noOpHandler).isOk()

    # node2 keeps the shards it learned on connecting.
    check:
      node2.peerManager.switch.peerStore.getPeer(node1Info.peerId).shards == @[0'u16]
      node2.peerManager.selectPeers(WakuLightPushCodec).mapIt(it.peerId) ==
        @[node1Info.peerId]
      node2.peerManager
        .selectPeer(WakuLightPushCodec, Opt.some(PubsubTopic("/waku/2/rs/10/1")))
        .isNone()

    await node2.peerManager.disconnectNode(node1Info.peerId)
    checkUntilTimeout:
      not node2.switch.isConnected(node1Info.peerId)
      not node1.switch.isConnected(node2.switch.peerInfo.peerId)

    let reconnected = await node2.peerManager.connectPeer(node1Info)

    check reconnected
    checkUntilTimeout:
      node2.peerManager.switch.peerStore.getPeer(node1Info.peerId).shards.sorted() ==
        @[0'u16, 1'u16]
      node2.peerManager
        .selectPeer(WakuLightPushCodec, Opt.some(PubsubTopic("/waku/2/rs/10/1")))
        .isSome()

suite "Waku Metadata - shards on the wire":
  test "the decoder reads the shards of each writer":
    # Cluster 1 and shards 0 and 5, in four forms.
    const forms = [
      "0801100010051a020005", # master: field 2 unpacked and field 3 packed
      "08011a020005", # go-waku: field 3 packed only
      "080112020005", # the schema: field 2 packed only
      "080110001005", # a node before #2511: field 2 unpacked only
    ]
    for hex in forms:
      let request = WakuMetadataRequest.decode(hexToSeqByte(hex))
      let response = WakuMetadataResponse.decode(hexToSeqByte(hex))
      check:
        request.isOk()
        request.get().clusterId == Opt.some(1'u32)
        request.get().shards == @[0'u32, 5]
        response.isOk()
        response.get().shards == @[0'u32, 5]

  test "the encoder writes the bytes of master":
    let request = WakuMetadataRequest(clusterId: Opt.some(1'u32), shards: @[0'u32, 5])
    let response = WakuMetadataResponse(clusterId: Opt.some(1'u32), shards: @[0'u32, 5])
    check:
      request.encode() == hexToSeqByte("0801100010051a020005")
      response.encode() == hexToSeqByte("0801100010051a020005")

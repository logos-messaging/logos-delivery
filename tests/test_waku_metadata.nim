{.used.}

import
  std/[sequtils, tables],
  testutils/unittests,
  stew/byteutils,
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
    waku_metadata/rpc,
    waku_relay/protocol,
  ],
  ./testlib/wakucore,
  ./testlib/wakunode

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

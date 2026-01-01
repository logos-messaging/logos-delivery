{.used.}

import
  std/[options, sequtils, tables],
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/switch,
  libp2p/peerId,
  libp2p/crypto/crypto,
  libp2p/multistream,
  libp2p/muxers/muxer,
  eth/keys,
  eth/enr/enr
import
  waku/
    [
      waku_node,
      waku_core/topics,
      node/peer_manager,
      discovery/waku_discv5,
      waku_metadata,
    ],
  ./testlib/wakucore,
  ./testlib/wakunode

procSuite "Waku Metadata Protocol":
  asyncTest "request() returns the supported metadata of the peer":
    let clusterId = 10.uint16
    let
      node1 = newTestWakuNode(
        generateSecp256k1Key(),
        parseIpAddress("0.0.0.0"),
        Port(0),
        clusterId = clusterId,
      )
      node2 = newTestWakuNode(
        generateSecp256k1Key(),
        parseIpAddress("0.0.0.0"),
        Port(0),
        clusterId = clusterId,
      )

    # Start nodes
    await allFutures([node1.start(), node2.start()])

    node1.topicSubscriptionQueue.emit((kind: PubsubSub, topic: "/waku/2/rs/10/7"))
    node1.topicSubscriptionQueue.emit((kind: PubsubSub, topic: "/waku/2/rs/10/6"))

    # Create connection
    let connOpt = await node2.peerManager.dialPeer(
      node1.switch.peerInfo.toRemotePeerInfo(), WakuMetadataCodec
    )
    require:
      connOpt.isSome

    # Request metadata
    let response1 = await node2.wakuMetadata.request(connOpt.get())

    # Check the response or dont even continue
    require:
      response1.isOk

    check:
      response1.get().clusterId.get() == clusterId
      response1.get().shards == @[uint32(6), uint32(7)]

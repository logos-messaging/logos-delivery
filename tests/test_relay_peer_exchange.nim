{.used.}

import
  std/[sequtils, options],
  testutils/unittests,
  chronos,
  libp2p/peerid,
  libp2p/protocols/pubsub/gossipsub

import logos_delivery/waku/waku_core, logos_delivery/waku/waku_node, ./testlib/wakucore, ./testlib/wakunode

procSuite "Relay (GossipSub) Peer Exchange":
  asyncTest "Mount relay without peer exchange handler":
    # Given two nodes
    let
      listenAddress = parseIpAddress("0.0.0.0")
      port = Port(0)
      node1Key = generateSecp256k1Key()
      node1 = newTestWakuNode(node1Key, listenAddress, port)
      node2Key = generateSecp256k1Key()
      node2 =
        newTestWakuNode(node2Key, listenAddress, port, sendSignedPeerRecord = true)

    # When both client and server mount relay without a handler
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    (await node2.mountRelay(none(RoutingRecordsHandler))).isOkOr:
      assert false, "Failed to mount relay"

    # Then the relays are mounted without a handler
    check:
      node1.wakuRelay.parameters.enablePX == false
      node1.wakuRelay.routingRecordsHandler.len == 0
      node2.wakuRelay.parameters.enablePX == false
      node2.wakuRelay.routingRecordsHandler.len == 0

  asyncTest "Mount relay with peer exchange handler":
    ## Given three nodes
    # Create nodes and ENR. These will be added to the discoverable list
    let
      bindIp = parseIpAddress("0.0.0.0")
      port = Port(0)
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, bindIp, port)
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, bindIp, port, sendSignedPeerRecord = true)
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, bindIp, port, sendSignedPeerRecord = true)

    # Given some peer exchange handlers
    proc emptyPeerExchangeHandler(
        peer: PeerId, topic: string, peers: seq[RoutingRecordsPair]
    ) {.gcsafe.} =
      discard

    var completionFut = newFuture[bool]()
    proc peerExchangeHandler(
        peer: PeerId, topic: string, peers: seq[RoutingRecordsPair]
    ) {.gcsafe.} =
      ## Handle peers received via gossipsub peer exchange
      let peerRecords = peers.mapIt(it.record.get())

      check:
        # Node 3 is informed of node 2 via peer exchange
        peer == node1.switch.peerInfo.peerId
        topic == DefaultPubsubTopic
        peerRecords.countIt(it.peerId == node2.switch.peerInfo.peerId) == 1

      if (not completionFut.completed()):
        completionFut.complete(true)

    let
      emptyPeerExchangeHandle: RoutingRecordsHandler = emptyPeerExchangeHandler
      peerExchangeHandle: RoutingRecordsHandler = peerExchangeHandler

    # Givem the nodes mount relay with a peer exchange handler
    (await node1.mountRelay(some(emptyPeerExchangeHandle))).isOkOr:
      assert false, "Failed to mount relay"
    (await node2.mountRelay(some(emptyPeerExchangeHandle))).isOkOr:
      assert false, "Failed to mount relay"
    (await node3.mountRelay(some(peerExchangeHandle))).isOkOr:
      assert false, "Failed to mount relay"

    # Ensure that node1 prunes all peers after the first connection
    node1.wakuRelay.parameters.dHigh = 1

    await allFutures([node1.start(), node2.start(), node3.start()])

    # The three nodes should be subscribed to the same shard
    proc simpleHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    node1.subscribe((kind: PubsubSub, topic: $DefaultRelayShard), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to topic: " & $error
    node2.subscribe((kind: PubsubSub, topic: $DefaultRelayShard), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to topic: " & $error
    node3.subscribe((kind: PubsubSub, topic: $DefaultRelayShard), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to topic: " & $error

    # When nodes are connected
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node1.switch.peerInfo.toRemotePeerInfo()])

    # Verify that the handlePeerExchange was called (node3)
    check:
      (await completionFut.withTimeout(5.seconds)) == true

    # Clean up
    await allFutures([node1.stop(), node2.stop(), node3.stop()])

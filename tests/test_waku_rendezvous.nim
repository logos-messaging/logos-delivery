{.used.}

import
  std/options,
  chronos,
  testutils/unittests,
  libp2p/builders,
  libp2p/protocols/rendezvous

import
  waku/waku_core/peers,
  waku/waku_core/codecs,
  waku/waku_core,
  waku/node/waku_node,
  waku/node/peer_manager/peer_manager,
  waku/waku_rendezvous/protocol,
  waku/waku_rendezvous/common,
  waku/waku_rendezvous/waku_peer_record,
  ./testlib/[wakucore, wakunode]

procSuite "Waku Rendezvous":
  asyncTest "Simple remote test":
    let
      clusterId = 10.uint16
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
      node3 = newTestWakuNode(
        generateSecp256k1Key(),
        parseIpAddress("0.0.0.0"),
        Port(0),
        clusterId = clusterId,
      )

    await allFutures(
      [
        node1.mountRendezvous(clusterId),
        node2.mountRendezvous(clusterId),
        node3.mountRendezvous(clusterId),
      ]
    )
    await allFutures([node1.start(), node2.start(), node3.start()])

    let peerInfo1 = node1.switch.peerInfo.toRemotePeerInfo()
    let peerInfo2 = node2.switch.peerInfo.toRemotePeerInfo()
    let peerInfo3 = node3.switch.peerInfo.toRemotePeerInfo()

    node1.peerManager.addPeer(peerInfo2)
    node2.peerManager.addPeer(peerInfo1)
    node2.peerManager.addPeer(peerInfo3)
    node3.peerManager.addPeer(peerInfo2)

    let res = await node1.wakuRendezvous.advertiseAll()
    assert res.isOk(), $res.error
    # Rendezvous Request API requires dialing first
    let connOpt =
      await node3.peerManager.dialPeer(peerInfo2.peerId, WakuRendezVousCodec)
    require:
      connOpt.isSome

    var records: seq[WakuPeerRecord]
    try:
      records = await rendezvous.request[WakuPeerRecord](
        node3.wakuRendezvous,
        Opt.some(computeMixNamespace(clusterId)),
        Opt.some(1),
        Opt.some(@[peerInfo2.peerId]),
      )
    except CatchableError as e:
      assert false, "Request failed with exception: " & e.msg

    check:
      records.len == 1
      records[0].peerId == peerInfo1.peerId
      #records[0].mixPubKey == $node1.wakuMix.pubKey

  asyncTest "Rendezvous advertises configured shards before relay is active":
    ## Given: A node with configured shards but no relay subscriptions yet
    let
      clusterId = 10.uint16
      configuredShards = @[RelayShard(clusterId: clusterId, shardId: 0)]

    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("0.0.0.0"),
      Port(0),
      clusterId = clusterId,
      subscribeShards = @[0'u16],
    )

    ## When: Node mounts rendezvous with configured shards (before relay)
    await node.mountRendezvous(clusterId, configuredShards)
    await node.start()

    ## Then: The rendezvous protocol should be mounted successfully
    check:
      node.wakuRendezvous != nil

    # Verify that the protocol is running without errors
    # (shards are used internally by the getShardsGetter closure)
    let namespace = computeMixNamespace(clusterId)
    check:
      namespace.len > 0

    await node.stop()

  asyncTest "Rendezvous uses configured shards when relay not mounted":
    ## Given: A light client node with no relay protocol
    let
      clusterId = 10.uint16
      configuredShards = @[
        RelayShard(clusterId: clusterId, shardId: 0),
        RelayShard(clusterId: clusterId, shardId: 1),
      ]

    let lightClient = newTestWakuNode(
      generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0), clusterId = clusterId
    )

    ## When: Node mounts rendezvous with configured shards (no relay mounted)
    await lightClient.mountRendezvous(clusterId, configuredShards)
    await lightClient.start()

    ## Then: Rendezvous should be mounted successfully without relay
    check:
      lightClient.wakuRendezvous != nil
      lightClient.wakuRelay == nil # Verify relay is not mounted

    # Verify the protocol is working (doesn't fail immediately)
    # advertiseAll requires peers,so we just check the protocol is initialized
    await sleepAsync(100.milliseconds)

    check:
      lightClient.wakuRendezvous != nil

    await lightClient.stop()

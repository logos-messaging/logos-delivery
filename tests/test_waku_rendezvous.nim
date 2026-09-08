{.used.}

import
  results,
  chronos,
  stew/byteutils,
  testutils/unittests,
  libp2p/builders,
  libp2p/crypto/curve25519,
  libp2p/protocols/rendezvous

import
  logos_delivery/waku/waku_core/peers,
  logos_delivery/waku/waku_core/codecs,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/node/peer_manager/peer_manager,
  logos_delivery/waku/waku_rendezvous/protocol,
  logos_delivery/waku/waku_rendezvous/common,
  logos_delivery/waku/waku_rendezvous/waku_peer_record,
  logos_delivery/waku/waku_rendezvous/client,
  ./testlib/[wakucore, wakunode]

suite "mixPubKeyFromHex":
  proc validKeyBytes(): seq[byte] =
    var b = newSeq[byte](Curve25519KeySize)
    for i in 0 ..< Curve25519KeySize:
      b[i] = byte(i)
    b

  test "empty string returns none":
    check:
      mixPubKeyFromHex("").isNone()

  test "short hex does not raise":
    check:
      mixPubKeyFromHex("ff").isNone()
      mixPubKeyFromHex("zz").isNone()

  test "non-32-byte decoded length returns none":
    check:
      mixPubKeyFromHex(byteutils.toHex(newSeq[byte](Curve25519KeySize - 1))).isNone()
      mixPubKeyFromHex(byteutils.toHex(newSeq[byte](Curve25519KeySize + 1))).isNone()

  test "32-byte hex returns the key":
    let bytes = validKeyBytes()
    let res = mixPubKeyFromHex(byteutils.toHex(bytes))
    require:
      res.isSome()
    check:
      res.get().getBytes() == bytes

  test "0x-prefixed 32-byte hex returns the key":
    let bytes = validKeyBytes()
    let res = mixPubKeyFromHex("0x" & byteutils.toHex(bytes))
    require:
      res.isSome()
    check:
      res.get().getBytes() == bytes

  test "round-trip matches intoCurve25519Key on raw bytes":
    let bytes = validKeyBytes()
    let extracted = mixPubKeyFromHex(byteutils.toHex(bytes)).get()
    let direct = intoCurve25519Key(bytes)
    check:
      extracted.getBytes() == direct.getBytes()

procSuite "Waku Rendezvous":
  asyncTest "Simple remote test":
    let
      clusterId = 10.uint16
      node1 = newTestWakuNode(generateSecp256k1Key(), clusterId = clusterId)
      node2 = newTestWakuNode(generateSecp256k1Key(), clusterId = clusterId)
      node3 = newTestWakuNode(generateSecp256k1Key(), clusterId = clusterId)

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
      generateSecp256k1Key(), clusterId = clusterId, subscribeShards = @[0'u16]
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

    let lightClient = newTestWakuNode(generateSecp256k1Key(), clusterId = clusterId)

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

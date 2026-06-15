{.used.}

import
  std/[sequtils, sysrand, math, options],
  testutils/unittests,
  chronos,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/multiaddress,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/multihash,
  secp256k1
import
  logos_delivery/waku/
    [waku_core, node/peer_manager, waku_node, factory/validator_signed],
  tools/confutils/cli_args,
  ../testlib/wakucore,
  ../testlib/wakunode

suite "WakuNode2 - Validators":
  asyncTest "Spam protected topic accepts signed messages":
    # Create 5 nodes
    let nodes = toSeq(0 ..< 5).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )

    # Protected shard and key to sign
    let spamProtectedShard = RelayShard(clusterId: 0, shardId: 7)
    let secretKey = SkSecretKey
      .fromHex("5526a8990317c9b7b58d07843d270f9cd1d9aaee129294c1c478abf7261dd9e6")
      .expect("valid key")
    let publicKey = secretKey.toPublicKey()
    let shardsPrivateKeys = {spamProtectedShard: secretKey}.toTable
    let shardsPublicKeys = {spamProtectedShard: publicKey}.toTable

    # Start all the nodes and mount relay with protected topic
    await allFutures(nodes.mapIt(it.start()))

    # Mount relay for all nodes
    await allFutures(nodes.mapIt(it.mountRelay()))

    # Add signed message validator to all nodes. They will only route signed messages
    for node in nodes:
      var signedShards: seq[ProtectedShard]
      for shard, publicKey in shardsPublicKeys:
        signedShards.add(ProtectedShard(shard: shard.shardId, key: publicKey))
      node.wakuRelay.addSignedShardsValidator(
        signedShards, spamProtectedShard.clusterId
      )

    # Connect the nodes in a full mesh
    for i in 0 ..< 5:
      for j in 0 ..< 5:
        if i == j:
          continue
        let connOk = await nodes[i].peerManager.connectPeer(
          nodes[j].switch.peerInfo.toRemotePeerInfo()
        )
        require connOk

    # Connection triggers different actions, wait for them
    await sleepAsync(500.millis)

    var msgReceived = 0
    proc handler(pubsubTopic: PubsubTopic, data: WakuMessage) {.async, gcsafe.} =
      msgReceived += 1

    # Subscribe all nodes to the same topic/handler
    for node in nodes:
      node.subscribe((kind: PubsubSub, topic: $spamProtectedShard), handler).isOkOr:
        assert false, "Failed to subscribe to topic: " & $error

    await sleepAsync(500.millis)

    # Each node publishes 10 signed messages
    for i in 0 ..< 5:
      for j in 0 ..< 10:
        var msg = WakuMessage(
          payload: urandom(1 * (10 ^ 3)),
          contentTopic: spamProtectedShard,
          version: 2,
          timestamp: now(),
          ephemeral: true,
        )

        # Include signature
        msg.meta =
          secretKey.sign(SkMessage(spamProtectedShard.msgHash(msg))).toRaw()[0 .. 63]

        discard await nodes[i].publish(some($spamProtectedShard), msg)

    # Wait for gossip
    await sleepAsync(2.seconds)

    # 50 messages were sent to 5 peers = 250 messages
    check:
      msgReceived == 250

    # No invalid messages were received by any peer
    for i in 0 ..< 5:
      for k, v in nodes[i].wakuRelay.peerStats.mpairs:
        check:
          v.topicInfos[spamProtectedShard].invalidMessageDeliveries == 0.0

    # Stop all nodes
    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Spam protected topic rejects non-signed/wrongly-signed/no-timestamp messages":
    # Create 5 nodes
    let nodes = toSeq(0 ..< 5).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )

    # Protected shard and key to sign
    let spamProtectedShard = RelayShard(clusterId: 0, shardId: 7)
    let secretKey = SkSecretKey
      .fromHex("5526a8990317c9b7b58d07843d270f9cd1d9aaee129294c1c478abf7261dd9e6")
      .expect("valid key")
    let publicKey = secretKey.toPublicKey()
    let shardsPrivateKeys = {spamProtectedShard: secretKey}.toTable
    let shardsPublicKeys = {spamProtectedShard: publicKey}.toTable

    # Non whitelisted secret key
    let wrongSecretKey = SkSecretKey
      .fromHex("32ad0cc8edeb9f8a3e8635c5fe5bd200b9247a33da5e7171bd012691805151f3")
      .expect("valid key")

    # Start all the nodes and mount relay with protected topic
    await allFutures(nodes.mapIt(it.start()))

    # Mount relay with spam protected topics
    await allFutures(nodes.mapIt(it.mountRelay()))

    # Add signed message validator to all nodes. They will only route signed messages
    for node in nodes:
      var signedShards: seq[ProtectedShard]
      for shard, publicKey in shardsPublicKeys:
        signedShards.add(ProtectedShard(shard: shard.shardId, key: publicKey))
      node.wakuRelay.addSignedShardsValidator(
        signedShards, spamProtectedShard.clusterId
      )

    # Connect the nodes in a full mesh
    for i in 0 ..< 5:
      for j in 0 ..< 5:
        if i == j:
          continue
        let connOk = await nodes[i].peerManager.connectPeer(
          nodes[j].switch.peerInfo.toRemotePeerInfo()
        )
        require connOk

    var msgReceived = 0
    proc handler(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      msgReceived += 1

    # Connection triggers different actions, wait for them
    await sleepAsync(500.millis)

    # Subscribe all nodes to the same topic/handler
    for node in nodes:
      node.subscribe((kind: PubsubSub, topic: $spamProtectedShard), handler).isOkOr:
        assert false, "Failed to subscribe to topic: " & $error

    await sleepAsync(500.millis)

    # Each node sends 5 messages, signed but with a non-whitelisted key (total = 25)
    for i in 0 ..< 5:
      for j in 0 ..< 5:
        var msg = WakuMessage(
          payload: urandom(1 * (10 ^ 3)),
          contentTopic: spamProtectedShard,
          version: 2,
          timestamp: now(),
          ephemeral: true,
        )

        # Sign the message with a wrong key
        msg.meta = wrongSecretKey.sign(SkMessage(spamProtectedShard.msgHash(msg))).toRaw()[
          0 .. 63
        ]

        discard await nodes[i].publish(some($spamProtectedShard), msg)

    # Each node sends 5 messages that are not signed (total = 25)
    for i in 0 ..< 5:
      for j in 0 ..< 5:
        let unsignedMessage = WakuMessage(
          payload: urandom(1 * (10 ^ 3)),
          contentTopic: spamProtectedShard,
          version: 2,
          timestamp: now(),
          ephemeral: true,
        )
        discard await nodes[i].publish(some($spamProtectedShard), unsignedMessage)

    # Each node sends 5 messages that dont contain timestamp (total = 25)
    for i in 0 ..< 5:
      for j in 0 ..< 5:
        let unsignedMessage = WakuMessage(
          payload: urandom(1 * (10 ^ 3)),
          contentTopic: spamProtectedShard,
          version: 2,
          timestamp: 0,
          ephemeral: true,
        )
        discard await nodes[i].publish(some($spamProtectedShard), unsignedMessage)

    # Each node sends 5 messages way BEFORE than the current timestmap (total = 25)
    for i in 0 ..< 5:
      for j in 0 ..< 5:
        let beforeTimestamp = now() - getNanosecondTime(6 * 60)
        let unsignedMessage = WakuMessage(
          payload: urandom(1 * (10 ^ 3)),
          contentTopic: spamProtectedShard,
          version: 2,
          timestamp: beforeTimestamp,
          ephemeral: true,
        )
        discard await nodes[i].publish(some($spamProtectedShard), unsignedMessage)

    # Each node sends 5 messages way LATER than the current timestmap (total = 25)
    for i in 0 ..< 5:
      for j in 0 ..< 5:
        let afterTimestamp = now() - getNanosecondTime(6 * 60)
        let unsignedMessage = WakuMessage(
          payload: urandom(1 * (10 ^ 3)),
          contentTopic: spamProtectedShard,
          version: 2,
          timestamp: afterTimestamp,
          ephemeral: true,
        )
        discard await nodes[i].publish(some($spamProtectedShard), unsignedMessage)

    # Since we have a full mesh with 5 nodes and each one publishes 25+25+25+25+25 msgs
    # there are 625 messages being sent.
    # 125 are received ok in the handler (first hop)
    # 500 are wrong so rejected (rejected not relayed)

    var msgRejected = 0

    # Active wait for the messages to be delivered across the mesh
    for i in 0 ..< 100:
      msgRejected = 0
      for i in 0 ..< 5:
        for k, v in nodes[i].wakuRelay.peerStats.mpairs:
          msgRejected += v.topicInfos[spamProtectedShard].invalidMessageDeliveries.int

      if msgReceived == 125 and msgRejected == 500:
        break
      else:
        await sleepAsync(100.milliseconds)

    check:
      msgReceived == 125
      msgRejected == 500

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Spam protected topic rejects a spammer node":
    # Create 5 nodes
    let nodes = toSeq(0 ..< 5).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )

    # Protected shard and key to sign
    let spamProtectedShard = RelayShard(clusterId: 0, shardId: 7)
    let secretKey = SkSecretKey
      .fromHex("5526a8990317c9b7b58d07843d270f9cd1d9aaee129294c1c478abf7261dd9e6")
      .expect("valid key")
    let publicKey = secretKey.toPublicKey()
    let shardsPrivateKeys = {spamProtectedShard: secretKey}.toTable
    let shardsPublicKeys = {spamProtectedShard: publicKey}.toTable

    # Non whitelisted secret key
    let wrongSecretKey = SkSecretKey
      .fromHex("32ad0cc8edeb9f8a3e8635c5fe5bd200b9247a33da5e7171bd012691805151f3")
      .expect("valid key")

    # Start all the nodes and mount relay with protected topic
    await allFutures(nodes.mapIt(it.start()))

    # Mount relay for all nodes
    await allFutures(nodes.mapIt(it.mountRelay()))

    var msgReceived = 0
    proc handler(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      msgReceived += 1

    # Subscribe all nodes to the same topic/handler
    for node in nodes:
      node.subscribe((kind: PubsubSub, topic: $spamProtectedShard), handler).isOkOr:
        assert false, "Failed to subscribe to topic: " & $error
    await sleepAsync(500.millis)

    # Add signed message validator to all nodes. They will only route signed messages
    for node in nodes:
      var signedShards: seq[ProtectedShard]
      for shard, publicKey in shardsPublicKeys:
        signedShards.add(ProtectedShard(shard: shard.shardId, key: publicKey))
      node.wakuRelay.addSignedShardsValidator(
        signedShards, spamProtectedShard.clusterId
      )

    # nodes[0] is connected only to nodes[1]
    let connOk1 = await nodes[0].peerManager.connectPeer(
      nodes[1].switch.peerInfo.toRemotePeerInfo()
    )
    require connOk1

    # rest of nodes[1..4] are connected in a full mesh
    for i in 1 ..< 5:
      for j in 1 ..< 5:
        if i == j:
          continue
        let connOk2 = await nodes[i].peerManager.connectPeer(
          nodes[j].switch.peerInfo.toRemotePeerInfo()
        )
        require connOk2

    # Connection triggers different actions, wait for them
    await sleepAsync(500.millis)

    # nodes[0] spams 50 non signed messages (nodes[0] just knows of nodes[1])
    for j in 0 ..< 50:
      let unsignedMessage = WakuMessage(
        payload: urandom(1 * (10 ^ 3)),
        contentTopic: spamProtectedShard,
        version: 2,
        timestamp: now(),
        ephemeral: true,
      )
      discard await nodes[0].publish(some($spamProtectedShard), unsignedMessage)

    # nodes[0] spams 50 wrongly signed messages (nodes[0] just knows of nodes[1])
    for j in 0 ..< 50:
      var msg = WakuMessage(
        payload: urandom(1 * (10 ^ 3)),
        contentTopic: spamProtectedShard,
        version: 2,
        timestamp: now(),
        ephemeral: true,
      )
      # Sign the message with a wrong key
      msg.meta =
        wrongSecretKey.sign(SkMessage(spamProtectedShard.msgHash(msg))).toRaw()[0 .. 63]
      discard await nodes[0].publish(some($spamProtectedShard), msg)

    # Wait for gossip
    await sleepAsync(2.seconds)

    # only 100 messages are received (50 + 50) which demonstrate
    # nodes[1] doest gossip invalid messages.
    check:
      msgReceived == 100

    # peer1 got invalid messages from peer0
    let p0Id = nodes[0].peerInfo.peerId
    check:
      nodes[1].wakuRelay.peerStats[p0Id].topicInfos[spamProtectedShard].invalidMessageDeliveries ==
        100.0

    # peer1 did not gossip further, so no other node rx invalid messages
    for i in 0 ..< 5:
      for k, v in nodes[i].wakuRelay.peerStats.mpairs:
        if k == p0Id and i == 1:
          continue
        check:
          v.topicInfos[spamProtectedShard].invalidMessageDeliveries == 0.0

    # Stop all nodes
    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Tests vectors":
    # keys
    let privateKey = "5526a8990317c9b7b58d07843d270f9cd1d9aaee129294c1c478abf7261dd9e6"
    let publicKey =
      "049c5fac802da41e07e6cdf51c3b9a6351ad5e65921527f2df5b7d59fd9b56ab02bab736cdcfc37f25095e78127500da371947217a8cd5186ab890ea866211c3f6"

    # message
    let contentTopic = "content-topic"
    let pubsubTopic = "pubsub-topic"
    let payload =
      "1A12E077D0E89F9CAC11FBBB6A676C86120B5AD3E248B1F180E98F15EE43D2DFCF62F00C92737B2FF6F59B3ABA02773314B991C41DC19ADB0AD8C17C8E26757B"
    let timestamp = 1683208172339052800
    let ephemeral = true

    # expected values
    let expectedMsgAppHash =
      "662F8C20A335F170BD60ABC1F02AD66F0C6A6EE285DA2A53C95259E7937C0AE9"
    let expectedSignature =
      "127FA211B2514F0E974A055392946DC1A14052182A6ABEFB8A6CD7C51DA1BF2E40595D28EF1A9488797C297EED3AAC45430005FB3A7F037BDD9FC4BD99F59E63"

    let secretKey = SkSecretKey.fromHex(privateKey).expect("valid key")

    check:
      secretKey.toPublicKey().toHex() == publicKey
      secretKey.toHex() == privateKey

    var msg = WakuMessage(
      payload: payload.fromHex(),
      contentTopic: contentTopic,
      version: 2,
      timestamp: timestamp,
      ephemeral: ephemeral,
    )

    let msgAppHash = pubsubTopic.msgHash(msg)
    let signature = secretKey.sign(SkMessage(msgAppHash)).toRaw()

    check:
      msgAppHash.toHex() == expectedMsgAppHash
      signature.toHex() == expectedSignature

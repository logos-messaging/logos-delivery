{.used.}

import
  std/[net, sequtils, strutils],
  results,
  testutils/unittests,
  chronos,
  metrics,
  libp2p/crypto/crypto

import
  logos_delivery/waku/[
    waku_node,
    node/peer_manager,
    waku_core,
    waku_archive,
    waku_archive/archive_metrics,
    waku_store_sync,
    waku_store_sync/protocols_metrics,
  ],
  ../waku_relay/utils,
  ../waku_archive/archive_utils,
  ../testlib/[wakucore, wakunode, testasync]

const
  listenIp = parseIpAddress("0.0.0.0")
  listenPort = Port(0)
  raisedMaxMessageSize = 200 * 1024

proc newStoreSyncNode(driver: ArchiveDriver): Future[WakuNode] {.async.} =
  ## A store node whose sync interval is long enough that only the test starts sessions.
  let node = newTestWakuNode(generateSecp256k1Key(), listenIp, listenPort)
  node.mountArchive(driver).isOkOr:
    raiseAssert error
  (
    await node.mountStoreSync(
      DefaultClusterId,
      @[DefaultShardId],
      @[],
      storeSyncRange = 3600,
      storeSyncInterval = 300,
      storeSyncRelayJitter = 0,
    )
  ).isOkOr:
    raiseAssert error
  return node

proc syncWith(node, peer: WakuNode): Future[Result[void, string]] {.async.} =
  return await node.wakuStoreReconciliation.storeSynchronization(
    Opt.some(peer.switch.peerInfo.toRemotePeerInfo())
  )

proc transferCount(direction: string): float64 =
  try:
    return logos_delivery_total_transfer_messages_exchanged.valueByName(
      "logos_delivery_total_transfer_messages_exchanged_total", [direction]
    )
  except ValueError:
    return 0.0

suite "Waku Store Sync - End to End":
  var nodes {.threadvar.}: seq[WakuNode]

  asyncTeardown:
    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "A node syncs what its peer's archive held before store sync was mounted":
    # Given a node whose archive already holds messages, and an empty node
    let
      msgs = @[
        fakeWakuMessage(@[byte 0]),
        fakeWakuMessage(@[byte 1]),
        fakeWakuMessage(@[byte 2]),
      ]
      hashes = msgs.mapIt(computeMessageHash(DefaultPubsubTopic, it))
      server = await newStoreSyncNode(
        await newArchiveDriverWithMessages(DefaultPubsubTopic, msgs)
      )
      client = await newStoreSyncNode(newSqliteArchiveDriver())
    nodes = @[server, client]
    await allFutures(nodes.mapIt(it.start()))

    # When the empty node syncs with it
    let res = await client.syncWith(server)

    # Then the empty node's archive holds the messages
    check res.isOk()
    checkUntilTimeout:
      await client.wakuArchive.holdsMessages(hashes)

  asyncTest "A message received through store sync is synced to the next peer":
    # Given a message only node A holds
    let
      msg = fakeWakuMessage()
      hash = computeMessageHash(DefaultPubsubTopic, msg)
      nodeA = await newStoreSyncNode(
        await newArchiveDriverWithMessages(DefaultPubsubTopic, @[msg])
      )
      nodeB = await newStoreSyncNode(newSqliteArchiveDriver())
      nodeC = await newStoreSyncNode(newSqliteArchiveDriver())
    nodes = @[nodeA, nodeB, nodeC]
    await allFutures(nodes.mapIt(it.start()))

    # When B syncs with A, then C with B
    let resB = await nodeB.syncWith(nodeA)
    check resB.isOk()
    checkUntilTimeout:
      await nodeB.wakuArchive.holdsMessages(@[hash])

    let resC = await nodeC.syncWith(nodeB)

    # Then C's archive holds the message
    check resC.isOk()
    checkUntilTimeout:
      await nodeC.wakuArchive.holdsMessages(@[hash])

  asyncTest "One session gives two relay nodes each other's messages":
    # Given two relay nodes that each archived their own messages while not connected
    let
      nodeA = await newStoreSyncNode(newSqliteArchiveDriver())
      nodeB = await newStoreSyncNode(newSqliteArchiveDriver())
    nodes = @[nodeA, nodeB]
    await allFutures(nodes.mapIt(it.mountRelay()))
    await allFutures(nodes.mapIt(it.start()))
    for node in nodes:
      node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), noopRawHandler()).isOkOr:
        raiseAssert error

    let
      msgsA = @[
        fakeWakuMessage(@[byte 0]),
        fakeWakuMessage(@[byte 1]),
        fakeWakuMessage(@[byte 2]),
      ]
      msgsB = @[
        fakeWakuMessage(@[byte 3]),
        fakeWakuMessage(@[byte 4]),
        fakeWakuMessage(@[byte 5]),
      ]
      hashesA = msgsA.mapIt(computeMessageHash(DefaultPubsubTopic, it))
      hashesB = msgsB.mapIt(computeMessageHash(DefaultPubsubTopic, it))

    # With no peer the publish fails, after the node's own handler archived the message.
    for msg in msgsA:
      discard await nodeA.publish(Opt.some(DefaultPubsubTopic), msg)
    for msg in msgsB:
      discard await nodeB.publish(Opt.some(DefaultPubsubTopic), msg)
    checkUntilTimeout:
      await nodeA.wakuArchive.holdsMessages(hashesA)
      await nodeB.wakuArchive.holdsMessages(hashesB)

    let syncInsertsBefore = insertCount(syncIngress)

    # When they connect and A syncs with B
    await nodeA.connectToNodes(@[nodeB.switch.peerInfo.toRemotePeerInfo()])
    let res = await nodeA.syncWith(nodeB)

    # Then both archives hold all six messages, each one a node lacked written by sync
    check res.isOk()
    checkUntilTimeout:
      await nodeA.wakuArchive.holdsMessages(hashesA & hashesB)
      await nodeB.wakuArchive.holdsMessages(hashesA & hashesB)
    check insertCount(syncIngress) == syncInsertsBefore + 6

  asyncTest "A message above the default size limit is not synced, nor the messages sent after it in its session":
    # TODO: sync-transfer-max-size
    # Given a relay node with a raised max message size that archived a message above the default limit, then three small ones
    let
      nodeA = await newStoreSyncNode(newSqliteArchiveDriver())
      nodeB = await newStoreSyncNode(newSqliteArchiveDriver())
    nodes = @[nodeA, nodeB]
    (await nodeA.mountRelay(maxMessageSize = raisedMaxMessageSize)).isOkOr:
      raiseAssert error
    await allFutures(nodes.mapIt(it.start()))
    nodeA.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), noopRawHandler()).isOkOr:
      raiseAssert error

    let
      msgs = @[
        fakeWakuMessage(newSeq[byte](160_000)),
        fakeWakuMessage(@[byte 1]),
        fakeWakuMessage(@[byte 2]),
        fakeWakuMessage(@[byte 3]),
      ]
      hashes = msgs.mapIt(computeMessageHash(DefaultPubsubTopic, it))
    for msg in msgs:
      discard await nodeA.publish(Opt.some(DefaultPubsubTopic), msg)
    checkUntilTimeout:
      await nodeA.wakuArchive.holdsMessages(hashes)

    let
      sentBefore = transferCount(Sending)
      receivedBefore = transferCount(Receiving)

    # When the empty node syncs with it
    let res = await nodeB.syncWith(nodeA)

    # Then the sender counts all four as sent, and the empty node's archive holds none of them
    check res.isOk()
    checkUntilTimeout:
      transferCount(Sending) == sentBefore + 4
    await sleepAsync(500.milliseconds)
    check transferCount(Receiving) == receivedBefore
    for hash in hashes:
      check not await nodeB.wakuArchive.holdsMessages(@[hash])

  asyncTest "Two messages above the default size limit sent over TCP stop the sender's transfers to every peer until that peer disconnects":
    # TODO: sync-transfer-max-size
    # Given a relay node with a raised max message size that archived two messages above the default limit
    let
      nodeA = await newStoreSyncNode(newSqliteArchiveDriver())
      nodeB = await newStoreSyncNode(newSqliteArchiveDriver())
      nodeC = await newStoreSyncNode(newSqliteArchiveDriver())
    nodes = @[nodeA, nodeB, nodeC]
    (await nodeA.mountRelay(maxMessageSize = raisedMaxMessageSize)).isOkOr:
      raiseAssert error
    await allFutures(nodes.mapIt(it.start()))
    nodeA.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), noopRawHandler()).isOkOr:
      raiseAssert error

    let
      largeMsgs = @[
        fakeWakuMessage(newSeq[byte](160_000)), fakeWakuMessage(newSeq[byte](160_000))
      ]
      largeHashes = largeMsgs.mapIt(computeMessageHash(DefaultPubsubTopic, it))
    for msg in largeMsgs:
      discard await nodeA.publish(Opt.some(DefaultPubsubTopic), msg)
    checkUntilTimeout:
      await nodeA.wakuArchive.holdsMessages(largeHashes)

    let sentBefore = transferCount(Sending)

    # When a peer connected to it over TCP syncs with it, then another peer does
    await nodeB.connectToNodes(
      @[
        RemotePeerInfo.init(
          nodeA.peerInfo.peerId, nodeA.peerInfo.addrs.filterIt("/quic-v1" notin $it)
        )
      ]
    )
    let resB = await nodeB.syncWith(nodeA)
    check resB.isOk()
    checkUntilTimeout:
      transferCount(Sending) == sentBefore + 1

    let resC = await nodeC.syncWith(nodeA)

    # Then the sender writes nothing after its first message until the TCP peer disconnects
    check resC.isOk()
    await sleepAsync(500.milliseconds)
    check transferCount(Sending) == sentBefore + 1

    await nodeB.stop()
    nodes = @[nodeA, nodeC]
    checkUntilTimeout:
      transferCount(Sending) == sentBefore + 3

  asyncTest "Seven messages above the default size limit sent over QUIC stop the sender after six":
    # TODO: sync-transfer-max-size
    # Given a relay node with a raised max message size that archived seven messages above the default limit
    let
      nodeA = await newStoreSyncNode(newSqliteArchiveDriver())
      nodeB = await newStoreSyncNode(newSqliteArchiveDriver())
    nodes = @[nodeA, nodeB]
    (await nodeA.mountRelay(maxMessageSize = raisedMaxMessageSize)).isOkOr:
      raiseAssert error
    await allFutures(nodes.mapIt(it.start()))
    nodeA.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), noopRawHandler()).isOkOr:
      raiseAssert error

    let
      largeMsgs = toSeq(0 ..< 7).mapIt(fakeWakuMessage(newSeq[byte](160_000)))
      largeHashes = largeMsgs.mapIt(computeMessageHash(DefaultPubsubTopic, it))
    for msg in largeMsgs:
      discard await nodeA.publish(Opt.some(DefaultPubsubTopic), msg)
    checkUntilTimeout:
      await nodeA.wakuArchive.holdsMessages(largeHashes)

    let sentBefore = transferCount(Sending)

    # When a peer connected to it over QUIC syncs with it
    await nodeB.connectToNodes(
      @[
        RemotePeerInfo.init(
          nodeA.peerInfo.peerId, nodeA.peerInfo.addrs.filterIt("/quic-v1" in $it)
        )
      ]
    )
    let res = await nodeB.syncWith(nodeA)

    # Then the sender writes six of them and nothing after
    check res.isOk()
    checkUntilTimeout:
      transferCount(Sending) == sentBefore + 6
    await sleepAsync(500.milliseconds)
    check transferCount(Sending) == sentBefore + 6

    # A node whose transfer write is stuck does not stop while its peer stays connected.
    await nodeB.stop()
    nodes = @[nodeA]
    checkUntilTimeout:
      not nodeA.switch.isConnected(nodeB.peerInfo.peerId)

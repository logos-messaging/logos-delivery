{.used.}

import
  std/[net, sequtils],
  results,
  testutils/unittests,
  chronos,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/mcache

import
  logos_delivery/waku/[
    waku_node,
    node/peer_manager,
    waku_core,
    waku_archive,
    waku_archive/archive_metrics,
    waku_store_sync,
  ],
  ../waku_relay/utils,
  ../waku_archive/archive_utils,
  ../testlib/[wakucore, wakunode, testasync]

const
  listenIp = parseIpAddress("0.0.0.0")
  listenPort = Port(0)

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

    # A message still in gossipsub's message cache window reaches a newly connected peer
    # through relay.
    checkUntilTimeout:
      nodeA.wakuRelay.mcache.window(DefaultPubsubTopic).len == 0
      nodeB.wakuRelay.mcache.window(DefaultPubsubTopic).len == 0

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

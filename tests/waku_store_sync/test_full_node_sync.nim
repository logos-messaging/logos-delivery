{.used.}

## Integration test for the "store as a startup-only dependency" experiment:
## two full nodes (no store service) wired exactly like `mountStoreSync` —
## reconciliation + transfer sharing one peer manager and the three async
## queues, backed by small in-memory archives — must recover missed
## messages from each other end to end.

import results, testutils/unittests, chronos, chronicles
import
  ../../logos_delivery/waku/[
    node/peer_manager,
    waku_core,
    waku_core/message/digest,
    waku_store_sync/common,
    waku_store_sync/reconciliation,
    waku_store_sync/transfer,
    waku_archive/archive,
    waku_archive/driver,
    waku_archive/common,
  ],
  ../testlib/[wakucore, testasync],
  ../waku_archive/archive_utils

type FullNode = object
  switch: Switch
  driver: ArchiveDriver
  archive: WakuArchive
  recon: SyncReconciliation
  transfer: SyncTransfer
  peerInfo: RemotePeerInfo
  peerManager: PeerManager

proc newFullNode(
    msgValidator: Opt[TransferValidator] = Opt.none(TransferValidator)
): Future[FullNode] {.async.} =
  ## Mirrors the wiring of WakuNode.mountStoreSync: one peer manager and
  ## three shared channels connect reconciliation and transfer.
  let switch = newTestSwitch()
  await switch.start()

  let driver = newSqliteArchiveDriver()
  let archive = newWakuArchive(driver)
  let peerManager = PeerManager.new(switch)

  let idsChannel = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)]()
  let wantsChannel = newAsyncQueue[PeerId]()
  let needsChannel = newAsyncQueue[(PeerId, WakuMessageHash)]()

  let recon = (
    await SyncReconciliation.new(
      pubsubTopics = @[],
      contentTopics = @[],
      peerManager = peerManager,
      wakuArchive = archive,
      relayJitter = 0.seconds,
      idsRx = idsChannel,
      localWantsTx = wantsChannel,
      remoteNeedsTx = needsChannel,
    )
  ).valueOr:
    raiseAssert error

  await recon.start()
  switch.mount(recon)

  let transfer = SyncTransfer.new(
    peerManager = peerManager,
    wakuArchive = archive,
    idsTx = idsChannel,
    localWantsRx = wantsChannel,
    remoteNeedsRx = needsChannel,
    msgValidator = msgValidator,
  )

  await transfer.start()
  switch.mount(transfer)

  return FullNode(
    switch: switch,
    driver: driver,
    archive: archive,
    recon: recon,
    transfer: transfer,
    peerInfo: switch.peerInfo.toRemotePeerInfo(),
    peerManager: peerManager,
  )

proc stop(node: FullNode) {.async.} =
  await node.transfer.stop()
  await node.recon.stop()
  await node.switch.stop()

proc insertMessage(node: FullNode, msg: WakuMessage) =
  ## Live-ingest path: relay would archive the message and feed the
  ## reconciliation storage (subscription_manager archive + sync handlers).
  discard node.driver.put(DefaultPubsubTopic, @[msg])
  node.recon.messageIngress(DefaultPubsubTopic, msg)

proc hasMessage(node: FullNode, hash: WakuMessageHash): Future[bool] {.async.} =
  var query = ArchiveQuery()
  query.includeData = true
  query.hashes = @[hash]

  let response = (await node.archive.findMessages(query)).valueOr:
    raiseAssert $error

  return response.messages.len > 0

suite "Waku Sync: full node miss recovery":
  var nodeA {.threadvar.}: FullNode
  var nodeB {.threadvar.}: FullNode

  asyncSetup:
    nodeA = await newFullNode()
    nodeB = await newFullNode()

    nodeA.peerManager.addPeer(nodeB.peerInfo)
    nodeB.peerManager.addPeer(nodeA.peerInfo)

  asyncTeardown:
    await nodeA.stop()
    await nodeB.stop()

  asyncTest "node recovers a missed message from a full-node peer":
    let msg = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let hash = computeMessageHash(DefaultPubsubTopic, msg)

    nodeA.insertMessage(msg)

    check not await nodeB.hasMessage(hash)

    let res = await nodeB.recon.storeSynchronization(Opt.some(nodeA.peerInfo))
    assert res.isOk(), $res.error

    # transfer of the missing message happens asynchronously after the
    # reconciliation session ends
    await sleepAsync(1.seconds)

    check await nodeB.hasMessage(hash)

  asyncTest "one session converges both nodes to the union":
    let msgA = fakeWakuMessage(payload = @[byte 1], contentTopic = DefaultContentTopic)
    let msgB = fakeWakuMessage(payload = @[byte 2], contentTopic = DefaultContentTopic)
    let hashA = computeMessageHash(DefaultPubsubTopic, msgA)
    let hashB = computeMessageHash(DefaultPubsubTopic, msgB)

    nodeA.insertMessage(msgA)
    nodeB.insertMessage(msgB)

    let res = await nodeB.recon.storeSynchronization(Opt.some(nodeA.peerInfo))
    assert res.isOk(), $res.error

    await sleepAsync(1.seconds)

    check:
      await nodeA.hasMessage(hashB)
      await nodeB.hasMessage(hashA)

  asyncTest "messages failing transfer validation are not archived":
    await nodeB.stop()

    let rejectAll: TransferValidator = proc(msg: WakuMessage): Future[bool] {.async.} =
      return false

    nodeB = await newFullNode(msgValidator = Opt.some(rejectAll))
    nodeA.peerManager.addPeer(nodeB.peerInfo)
    nodeB.peerManager.addPeer(nodeA.peerInfo)

    let msg = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let hash = computeMessageHash(DefaultPubsubTopic, msg)

    nodeA.insertMessage(msg)

    let res = await nodeB.recon.storeSynchronization(Opt.some(nodeA.peerInfo))
    assert res.isOk(), $res.error

    await sleepAsync(1.seconds)

    check not await nodeB.hasMessage(hash)

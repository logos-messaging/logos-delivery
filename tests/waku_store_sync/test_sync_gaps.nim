{.used.}

## Regression tests for the store-sync gaps seen in status.prod on 2026-10-22: a message over
## the transfer read limit ended the receiving session and dropped the batch behind it, a
## relay message that the archive rejected stayed out of sync, and the first write on a stream
## that the remote had closed was lost.

import std/sets, results, testutils/unittests, chronos, chronicles
import
  ../../logos_delivery/waku/[
    node/peer_manager,
    waku_core,
    waku_core/message,
    waku_core/message/digest,
    waku_store_sync/common,
    waku_store_sync/reconciliation,
    waku_store_sync/transfer,
    waku_archive/archive,
    waku_archive/driver,
    waku_archive/common,
    libp2p_backend/host,
  ],
  ../testlib/[wakucore, testasync],
  ../waku_archive/archive_utils

type SyncNode = object
  switch: Switch
  peerManager: PeerManager
  archive: WakuArchive
  driver: ArchiveDriver
  recon: SyncReconciliation
  transfer: SyncTransfer
  wants: AsyncQueue[PeerId]
  needs: AsyncQueue[(PeerId, WakuMessageHash)]
  info: RemotePeerInfo

proc newSyncNode(
    maxMessageSize: int = int(DefaultMaxWakuMessageSize)
): Future[SyncNode] {.async.} =
  let
    switch = newTestSwitch()
    driver = newSqliteArchiveDriver()
    archive = newWakuArchive(driver)

  await switch.start()

  let
    peerManager = PeerManager.new(switch)
    ids = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)]()
    wants = newAsyncQueue[PeerId]()
    needs = newAsyncQueue[(PeerId, WakuMessageHash)]()
    recon = (
      await SyncReconciliation.new(
        pubsubTopics = @[],
        contentTopics = @[],
        peerManager = peerManager,
        wakuArchive = archive,
        syncRange = DefaultSyncRange,
        relayJitter = 0.seconds,
        idsRx = ids,
        localWantsTx = wants,
        remoteNeedsTx = needs,
      )
    ).get()
    transfer = SyncTransfer.new(peerManager, archive, ids, wants, needs, maxMessageSize)

  await recon.start()
  await transfer.start()

  let host = Libp2pHost.new(switch)
  host.mountHandler(WakuReconciliationCodec, recon)
  host.mountHandler(WakuTransferCodec, transfer)

  return SyncNode(
    switch: switch,
    peerManager: peerManager,
    archive: archive,
    driver: driver,
    recon: recon,
    transfer: transfer,
    wants: wants,
    needs: needs,
    info: switch.peerInfo.toRemotePeerInfo(),
  )

proc stop(n: SyncNode) {.async.} =
  await n.transfer.stop()
  await n.recon.stop()
  await n.switch.stop()

proc holds(n: SyncNode, hash: WakuMessageHash): Future[bool] {.async.} =
  return await n.archive.holdsMessages(@[hash])

proc holds(n: SyncNode, msg: WakuMessage): Future[bool] {.async.} =
  return await n.holds(computeMessageHash(DefaultPubsubTopic, msg))

proc holdsAll(n: SyncNode, msgs: seq[WakuMessage]): Future[bool] {.async.} =
  for m in msgs:
    if not (await n.holds(m)):
      return false
  return true

proc offer(n: SyncNode, msgs: seq[WakuMessage]) {.async.} =
  ## Stores the messages and adds them to the sync index, as a node that received them in time
  discard await n.driver.put(DefaultPubsubTopic, msgs)
  for m in msgs:
    n.recon.messageIngress(DefaultPubsubTopic, m)

suite "Waku Sync: gaps seen in status.prod":
  var
    a {.threadvar.}: SyncNode
    b {.threadvar.}: SyncNode

  asyncTeardown:
    await allFutures(a.stop(), b.stop())

  proc connect() =
    a.peerManager.addPeer(b.info)
    b.peerManager.addPeer(a.info)

  asyncTest "a message over the size limit is skipped and the ones behind it still sync":
    a = await newSyncNode()
    b = await newSyncNode()
    connect()

    let
      ts = now() - 60_000_000_000
      big = fakeWakuMessage(payload = newSeq[byte](200 * 1024), ts = ts)
      small1 = fakeWakuMessage(ts = ts + 1)
      small2 = fakeWakuMessage(ts = ts + 2)
      small3 = fakeWakuMessage(ts = ts + 3)

    await a.offer(@[big, small1, small2, small3])

    (await b.recon.storeSynchronization(Opt.some(a.info))).isOkOr:
      assert false, error

    checkUntilTimeout:
      await b.holdsAll(@[small1, small2, small3])

    check:
      not (await b.holds(big))

  asyncTest "a message over the default limit syncs when the nodes allow it":
    a = await newSyncNode(maxMessageSize = 1024 * 1024)
    b = await newSyncNode(maxMessageSize = 1024 * 1024)
    connect()

    let
      ts = now() - 60_000_000_000
      big = fakeWakuMessage(payload = newSeq[byte](600 * 1024), ts = ts)
      small = fakeWakuMessage(ts = ts + 1)

    await a.offer(@[big, small])

    (await b.recon.storeSynchronization(Opt.some(a.info))).isOkOr:
      assert false, error

    checkUntilTimeout:
      await b.holdsAll(@[big, small])

  asyncTest "a relay message rejected by the archive is synced":
    a = await newSyncNode()
    b = await newSyncNode()
    connect()

    let
      ts = now() - 60_000_000_000
      stale = fakeWakuMessage(ts = ts)
      control = fakeWakuMessage(ts = ts + 1)

    await a.offer(@[stale, control])

    # the relay handler chain on b when the message arrives 60 s late: the archive rejects
    # it, so it must not reach the sync index either
    check:
      (await b.archive.storeMessage(DefaultPubsubTopic, stale)).isErr()
      not (await b.holds(stale))

    (await b.recon.storeSynchronization(Opt.some(a.info))).isOkOr:
      assert false, error

    checkUntilTimeout:
      await b.holdsAll(@[stale, control])

  asyncTest "a message sent after the remote dropped the connection still arrives":
    a = await newSyncNode()
    b = await newSyncNode()
    connect()

    let
      ts = now() - 60_000_000_000
      msg1 = fakeWakuMessage(ts = ts)
      msg2 = fakeWakuMessage(ts = ts + 1)
      msg3 = fakeWakuMessage(ts = ts + 2)

    discard await a.driver.put(DefaultPubsubTopic, @[msg1, msg2, msg3])
    await b.wants.put(a.info.peerId)

    await a.needs.put((b.info.peerId, computeMessageHash(DefaultPubsubTopic, msg1)))
    checkUntilTimeout:
      await b.holds(msg1)

    await b.switch.disconnect(a.info.peerId)
    await sleepAsync(200.milliseconds)

    await a.needs.put((b.info.peerId, computeMessageHash(DefaultPubsubTopic, msg2)))
    await a.needs.put((b.info.peerId, computeMessageHash(DefaultPubsubTopic, msg3)))

    checkUntilTimeout:
      await b.holdsAll(@[msg2, msg3])

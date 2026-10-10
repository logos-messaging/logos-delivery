import std/random, chronos, chronicles, metrics

import
  logos_delivery/waku/[
    node/peer_manager,
    waku_core,
    waku_store_sync/common,
    waku_store_sync/reconciliation,
    waku_store_sync/transfer,
    waku_store_sync/protocols_metrics,
  ],
  ../testlib/wakucore

randomize()

proc transferCount*(direction: string): float64 =
  try:
    return logos_delivery_total_transfer_messages_exchanged.valueByName(
      "logos_delivery_total_transfer_messages_exchanged_total", [direction]
    )
  except ValueError:
    return 0.0

proc randomHash*(rng: var Rand): WakuMessageHash =
  var hash = EmptyWakuMessageHash

  for i in 0 ..< hash.len:
    hash[i] = rng.rand(uint8)

  return hash

proc newTestWakuRecon*(
    switch: Switch,
    pubsubTopics: seq[PubsubTopic] = @[],
    contentTopics: seq[ContentTopic] = @[],
    syncRange: timer.Duration = DefaultSyncRange,
    idsRx: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)],
    wantsTx: AsyncQueue[PeerId],
    needsTx: AsyncQueue[(PeerId, WakuMessageHash)],
    relayJitter: timer.Duration = 0.seconds,
    clock: proc(): Timestamp {.gcsafe, raises: [].} = getNowInNanosecondTime,
): Future[SyncReconciliation] {.async.} =
  let peerManager = PeerManager.new(switch)

  let res = await SyncReconciliation.new(
    pubsubTopics = pubsubTopics,
    contentTopics = contentTopics,
    peerManager = peerManager,
    wakuArchive = nil,
    syncRange = syncRange,
    relayJitter = relayJitter,
    idsRx = idsRx,
    localWantsTx = wantsTx,
    remoteNeedsTx = needsTx,
    clock = clock,
  )

  let proto = res.get()

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuTransfer*(
    switch: Switch,
    idsTx: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)],
    wantsRx: AsyncQueue[PeerId],
    needsRx: AsyncQueue[(PeerId, WakuMessageHash)],
): Future[SyncTransfer] {.async.} =
  let peerManager = PeerManager.new(switch)

  let proto = SyncTransfer.new(
    peerManager = peerManager,
    wakuArchive = nil,
    idsTx = idsTx,
    localWantsRx = wantsRx,
    remoteNeedsRx = needsRx,
  )

  await proto.start()
  switch.mount(proto)

  return proto

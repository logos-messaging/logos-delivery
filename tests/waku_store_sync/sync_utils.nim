import std/[random, sets], chronos, metrics

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

var requestedInTest* {.threadvar.}: HashSet[WakuMessageHash]
  ## The hashes that a test receiver accepts as asked for by a round.

proc checkPushInTest*(id: SyncID): PushCheck {.gcsafe, raises: [].} =
  if requestedInTest.contains(id.hash): PushCheck.Wanted else: PushCheck.Unwanted

var pendingNowInTest* {.threadvar.}: Moment
  ## The time of the promises of a reconciliation that uses `pendingClockInTest`,
  ## which a test moves forward in place of a wait.

proc pendingClockInTest*(): Moment {.gcsafe, raises: [].} =
  pendingNowInTest

func syncId*(msg: WakuMessage, pubsubTopic = DefaultPubsubTopic): SyncID =
  SyncID(time: msg.timestamp, hash: computeMessageHash(pubsubTopic, msg))

func containsPush*(
    queue: AsyncQueue[(PeerId, SyncID)], peer: PeerId, hash: WakuMessageHash
): bool =
  ## True when `queue` holds a push of `hash` to `peer`.
  for (queuedPeer, id) in queue:
    if queuedPeer == peer and id.hash == hash:
      return true
  return false

type TransferDirection* {.pure.} = enum
  Sent
  Received

proc transferCount*(direction: TransferDirection): float64 =
  let label =
    case direction
    of TransferDirection.Sent: Sending
    of TransferDirection.Received: Receiving
  try:
    return logos_delivery_total_transfer_messages_exchanged.valueByName(
      "logos_delivery_total_transfer_messages_exchanged_total", [label]
    )
  except ValueError:
    return 0.0

proc reasonCount(counter: Counter, reason: string): float64 =
  ## Counters are registered with the '_total' suffix; see archive_utils.insertCount.
  try:
    return counter.valueByName(counter.name & "_total", [reason])
  except ValueError:
    return 0.0

# The counters are globals; reading them from a test is safe.
proc failureCount*(reason: string): float64 =
  {.gcsafe.}:
    reasonCount(logos_delivery_transfer_receive_failures, reason)

proc reconciliationFailures*(reason: string): float64 =
  {.gcsafe.}:
    reasonCount(logos_delivery_reconciliation_failures, reason)

proc randomHash*(rng: var Rand): WakuMessageHash =
  var hash = EmptyWakuMessageHash

  for i in 0 ..< hash.len:
    hash[i] = rng.rand(uint8)

  return hash

proc newTestWakuRecon*(
    switch: Switch,
    shards: seq[uint16] = @[],
    syncRange: timer.Duration = DefaultSyncRange,
    idsRx: AsyncQueue[(SyncID, PubsubTopic, PeerId)],
    wantsTx: AsyncQueue[PeerId],
    needsTx: AsyncQueue[(PeerId, SyncID)],
    relayJitter: timer.Duration = 0.seconds,
    syncInterval: timer.Duration = DefaultSyncInterval,
    clock: proc(): Timestamp {.gcsafe, raises: [].} = getNowInNanosecondTime,
    cluster: uint16 = DefaultClusterId,
    pendingTimeout: timer.Duration = DefaultSyncInterval,
    pendingClock: proc(): Moment {.gcsafe, raises: [].} = monotonicNow,
    peerManager: PeerManager = nil,
    frameSizeLimit = DefaultMaxPayloadSize,
): Future[SyncReconciliation] {.async.} =
  let peerManager =
    if peerManager.isNil():
      PeerManager.new(switch)
    else:
      peerManager

  let res = await SyncReconciliation.new(
    cluster = cluster,
    shards = shards,
    peerManager = peerManager,
    wakuArchive = nil,
    syncRange = syncRange,
    syncInterval = syncInterval,
    relayJitter = relayJitter,
    idsRx = idsRx,
    localWantsTx = wantsTx,
    remoteNeedsTx = needsTx,
    clock = clock,
    pendingTimeout = pendingTimeout,
    pendingClock = pendingClock,
    frameSizeLimit = frameSizeLimit,
  )

  let proto = res.get()

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuTransfer*(
    switch: Switch,
    idsTx: AsyncQueue[(SyncID, PubsubTopic, PeerId)],
    wantsRx: AsyncQueue[PeerId],
    needsRx: AsyncQueue[(PeerId, SyncID)],
): Future[SyncTransfer] {.async.} =
  let peerManager = PeerManager.new(switch)

  let proto = SyncTransfer.new(
    peerManager = peerManager,
    wakuArchive = nil,
    idsTx = idsTx,
    localWantsRx = wantsRx,
    remoteNeedsRx = needsRx,
    maxMessageSize = int(DefaultMaxWakuMessageSize),
    checkPush = checkPushInTest,
  )

  await proto.start()
  switch.mount(proto)

  return proto

{.push raises: [].}

import
  std/[deques, sequtils, sets, tables],
  stew/byteutils,
  results,
  chronicles,
  chronos,
  metrics,
  libp2p/protocols/protocol,
  libp2p/stream/connection,
  libp2p/crypto/crypto,
  eth/p2p/discoveryv5/enr
import
  ../common/nimchronos,
  ../common/protobuf,
  ../common/paging,
  ../waku_enr,
  ../waku_core/codecs,
  ../waku_core/time,
  ../waku_core/topics/pubsub_topic,
  ../waku_core/topics/content_topic,
  ../waku_core/message/digest,
  ../waku_core/message/message,
  ../node/peer_manager/peer_manager,
  ../waku_archive,
  ./common,
  ./codec,
  ./storage/storage,
  ./storage/seq_storage,
  ./storage/range_processing,
  ./protocols_metrics

logScope:
  topics = "waku reconciliation"

const DefaultStorageCap = 50_000

const DefaultMaxPayloadSize = 64 * 1024 * 1024
  ## The largest reconciliation payload that a node reads. An item set entry
  ## takes at most 41 bytes, so this is about 1.6 million entries in one round.

type SyncReconciliation* = ref object of LPProtocol
  cluster: uint16
  shards: HashSet[uint16] # Empty set means all shards.

  peerManager: PeerManager

  wakuArchive: WakuArchive

  storage: SyncStorage

  # Receive IDs from transfer protocol for storage
  idsRx: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)]

  # Send Hashes to transfer protocol for reception
  localWantsTx: AsyncQueue[(PeerId)]

  # Send Hashes to transfer protocol for transmission
  remoteNeedsTx: AsyncQueue[(PeerId, WakuMessageHash)]

  # params
  syncInterval: timer.Duration # Time between each synchronization attempt
  syncRange: timer.Duration # Amount of time in the past to sync
  relayJitter: Duration # Amount of time since the present to ignore when syncing
  clock: proc(): Timestamp {.gcsafe, raises: [].} # Source of the present time

  # Elements a peer promised in a round. They are in the storage under
  # PendingPubsubTopic until they arrive or their deadline passes.
  pendingTimeout: Duration
  pendingSet: HashSet[WakuMessageHash]
  pendingQueue: Deque[(SyncID, Moment)] # with their deadline, in order
  # Peers that asked for a pending element. They get it when it arrives.
  deferredTx: Table[WakuMessageHash, HashSet[PeerId]]

  # futures
  periodicSyncFut: Future[void]
  periodicPruneFut: Future[void]
  idsReceiverFut: Future[void]

proc queueTransfer(self: SyncReconciliation, peer: PeerId, hash: WakuMessageHash) =
  ## Queues `hash` to be sent to `peer`. A full queue drops the transfer, and the
  ## next round finds the same difference again.
  try:
    self.remoteNeedsTx.addLastNoWait((peer, hash))
  except AsyncQueueFullError as exc:
    error "failed to queue message for transfer",
      msg_hash = byteutils.toHex(hash), peer_id = peer, error = exc.msg

proc insertConfirmed(
    self: SyncReconciliation,
    id: SyncID,
    pubsubTopic: PubsubTopic,
    contentTopic: ContentTopic,
) =
  if self.pendingSet.contains(id.hash):
    self.pendingSet.excl(id.hash)
    # The pending entry has no real topic, so it is replaced rather than kept.
    self.storage.remove(id).isOkOr:
      error "failed to remove pending message",
        msg_hash = byteutils.toHex(id.hash), error = $error
    var peers: HashSet[PeerId]
    if self.deferredTx.pop(id.hash, peers):
      for peer in peers:
        self.queueTransfer(peer, id.hash)

  self.storage.insert(id, pubsubTopic, contentTopic).isOkOr:
    error "failed to insert new message",
      msg_hash = byteutils.toHex(id.hash), error = $error

proc expirePending(self: SyncReconciliation) =
  ## Drops the promised elements that did not arrive by their deadline, so that
  ## the next round asks for them again.
  let now = Moment.now()
  while self.pendingQueue.len > 0:
    let (id, deadline) = self.pendingQueue.peekFirst()
    if deadline > now:
      break
    discard self.pendingQueue.popFirst()
    if not self.pendingSet.contains(id.hash):
      continue

    self.pendingSet.excl(id.hash)
    self.deferredTx.del(id.hash)
    self.storage.remove(id).isOkOr:
      error "failed to remove pending message",
        msg_hash = byteutils.toHex(id.hash), error = $error

proc messageIngress*(
    self: SyncReconciliation, pubsubTopic: PubsubTopic, msg: WakuMessage
) =
  trace "message ingress", pubsub_topic = pubsubTopic, msg = msg

  if msg.ephemeral:
    return

  let msgHash = computeMessageHash(pubsubTopic, msg)

  let id = SyncID(time: msg.timestamp, hash: msgHash)

  self.insertConfirmed(id, pubsubTopic, msg.contentTopic)

proc messageIngress*(
    self: SyncReconciliation,
    msgHash: WakuMessageHash,
    pubsubTopic: PubsubTopic,
    msg: WakuMessage,
) =
  trace "message ingress", msg_hash = byteutils.toHex(msgHash), msg = msg

  if msg.ephemeral:
    return

  let id = SyncID(time: msg.timestamp, hash: msgHash)

  self.insertConfirmed(id, pubsubTopic, msg.contentTopic)

proc messageIngress*(
    self: SyncReconciliation,
    id: SyncID,
    pubsubTopic: PubsubTopic,
    contentTopic: ContentTopic,
) =
  self.insertConfirmed(id, pubsubTopic, contentTopic)

proc preProcessPayload*(
    self: SyncReconciliation, payload: RangesData, lowerBound: Timestamp
): Opt[RangesData] =
  ## Check the received payload for cluster, shards and/or time mismatch.

  var payload = payload

  if payload.cluster != self.cluster:
    return Opt.none(RangesData)

  # Always use the smallest shard scope possible
  if payload.shards.len > 0 and self.shards.len > 0:
    let shardIntersection = self.shards * payload.shards.toHashSet()

    if shardIntersection.len < 1:
      return Opt.none(RangesData)

    payload.shards = shardIntersection.toSeq()
  elif self.shards.len > 0:
    payload.shards = self.shards.toSeq()

  # for non skip ranges check if they happen before any of our ranges
  # convert to skip range before processing.
  # The range that crosses our lower bound is split into a skip part and the
  # part we process, which keeps the peer's fingerprint or item set. That
  # fingerprint also covers the peer's elements before our bound, so a
  # mismatch there costs one more round trip, never a false match.
  for i in 0 ..< payload.ranges.len:
    let rangeType = payload.ranges[i][1]
    if rangeType == RangeType.Skip:
      continue

    let
      bounds = payload.ranges[i][0]
      split = SyncID(time: lowerBound, hash: EmptyFingerprint)
    # The upper bound is exclusive, so a range ending at the split is all older.
    if not (split < bounds.b):
      payload.ranges[i][1] = RangeType.Skip

      if rangeType == RangeType.Fingerprint:
        payload.fingerprints.delete(0)
      elif rangeType == RangeType.ItemSet:
        payload.itemSets.delete(0)
    else:
      if bounds.a.time < lowerBound:
        payload.ranges[i] = (split .. bounds.b, rangeType)
        payload.ranges.insert((bounds.a .. split, RangeType.Skip), i)

        if rangeType == RangeType.ItemSet:
          payload.itemSets[0].elements.keepItIf(not (it < split))

      break

  return Opt.some(payload)

func isFinished(payload: RangesData): bool =
  ## A payload with no range left to reconcile ends the session.
  payload.ranges.len == 0 or payload.ranges.allIt(it[1] == RangeType.Skip)

func isOutOfScope(self: SyncReconciliation, payload: RangesData): bool =
  ## A peer on another cluster or with no shared shard answers with its header
  ## alone, which would otherwise end the session like one that is in sync.
  payload.ranges.len == 0 and (
    payload.cluster != self.cluster or (
      self.shards.len > 0 and payload.shards.len > 0 and
      (self.shards * payload.shards.toHashSet()).len == 0
    )
  )

proc readPayload(conn: Connection): Future[Result[RangesData, string]] {.async.} =
  ## Closes the connection on error.
  let buffer =
    try:
      await conn.readLp(DefaultMaxPayloadSize)
    except LPStreamError as exc:
      await conn.close()
      return err("remote " & $conn.peerId & " connection read error: " & exc.msg)

  logos_delivery_total_bytes_exchanged.inc(
    buffer.len, labelValues = [Reconciliation, Receiving]
  )

  let payload = RangesData.deltaDecode(buffer).valueOr:
    await conn.close()
    return err("remote " & $conn.peerId & " payload decoding error: " & error)

  return ok(payload)

proc writePayload(
    conn: Connection, payload: RangesData
): Future[Result[void, string]] {.async.} =
  ## Closes the connection on error.
  let rawPayload = payload.deltaEncode()

  logos_delivery_total_bytes_exchanged.inc(
    rawPayload.len, labelValues = [Reconciliation, Sending]
  )

  try:
    await conn.writeLP(rawPayload)
  except LPStreamError as exc:
    await conn.close()
    return err("remote " & $conn.peerId & " connection write error: " & exc.msg)

  return ok()

proc trackPromised(self: SyncReconciliation, idsToRecv: seq[SyncID]) =
  ## Promised elements count as present from here on, so that a round that
  ## overlaps their transfer does not ask for them again.
  let deadline = Moment.now() + self.pendingTimeout
  for id in idsToRecv:
    self.storage.insert(id, PendingPubsubTopic, "").isOkOr:
      error "failed to insert pending message",
        msg_hash = byteutils.toHex(id.hash), error = $error
      continue
    self.pendingSet.incl(id.hash)
    self.pendingQueue.addLast((id, deadline))

proc scheduleTransfers(
    self: SyncReconciliation, peerId: PeerId, hashToSend: seq[WakuMessageHash]
): int =
  ## Returns the number of hashes queued now. A deferred hash is not counted.
  var queued = 0
  for hash in hashToSend:
    # A pending element is not in the archive yet, so it is sent on arrival.
    if self.pendingSet.contains(hash):
      self.deferredTx.mgetOrPut(hash, initHashSet[PeerId]()).incl(peerId)
      continue
    self.queueTransfer(peerId, hash)
    queued.inc()
  return queued

proc reconcileRound(
    self: SyncReconciliation,
    recvPayload: RangesData,
    lowerBound: Timestamp,
    peerId: PeerId,
): (RangesData, int) =
  ## Returns the reply and the number of differences in this round.
  ## It must not become async: nothing may await between processPayload and
  ## trackPromised, so that none of the promised elements is here yet.
  var
    idsToRecv: seq[SyncID]
    hashToSend: seq[WakuMessageHash]
    sendPayload: RangesData
    diffs = 0
    # the scope the reply's ranges cover; ours when there is none
    replyShards = self.shards.toSeq()

  let preProcessedPayloadRes = self.preProcessPayload(recvPayload, lowerBound)
  if preProcessedPayloadRes.isSome():
    let preProcessedPayload = preProcessedPayloadRes.get()
    replyShards = preProcessedPayload.shards

    trace "pre-processed payload",
      local = self.peerManager.switch.peerInfo.peerId,
      remote = peerId,
      payload = preProcessedPayload

    sendPayload =
      self.storage.processPayload(preProcessedPayload, hashToSend, idsToRecv)

    trace "sync payload processed", hash_to_send = hashToSend, ids_to_recv = idsToRecv

    self.trackPromised(idsToRecv)
    # A promise counts as a difference even if its placeholder insert fails.
    diffs = idsToRecv.len + self.scheduleTransfers(peerId, hashToSend)
  else:
    debug "Sync scope mismatch",
      remote = peerId,
      remote_cluster = recvPayload.cluster,
      remote_shards = recvPayload.shards,
      local_cluster = self.cluster,
      local_shards = self.shards

  # On another cluster or with no shared shard, the reply has no ranges: the
  # header alone is the empty payload of WAKU-SYNC.
  sendPayload.cluster = self.cluster
  sendPayload.shards = replyShards

  return (sendPayload, diffs)

proc processRequest(
    self: SyncReconciliation, conn: Connection
): Future[Result[void, string]] {.async.} =
  var
    roundTrips = 0
    diffs = 0

  # Signal to transfer protocol that this reconciliation is starting
  await self.localWantsTx.addLast(conn.peerId)

  self.expirePending()

  # Fixed for the session, so that a range the peer sends back in a later
  # round never crosses a bound that moved by the round-trip time.
  let lowerBound = calculateTimeRange(self.clock(), self.relayJitter, self.syncRange).a

  while true:
    let recvPayload = (await readPayload(conn)).valueOr:
      return err(error)

    roundTrips.inc()

    trace "sync payload received",
      local = self.peerManager.switch.peerInfo.peerId,
      remote = conn.peerId,
      payload = recvPayload

    if self.isOutOfScope(recvPayload):
      await conn.close()
      return err(
        "remote " & $conn.peerId & " is outside the sync scope: cluster " &
          $recvPayload.cluster & ", shards " & $recvPayload.shards
      )

    if recvPayload.isFinished():
      break

    let (sendPayload, roundDiffs) =
      self.reconcileRound(recvPayload, lowerBound, conn.peerId)
    diffs += roundDiffs

    (await writePayload(conn, sendPayload)).isOkOr:
      return err(error)

    trace "sync payload sent",
      local = self.peerManager.switch.peerInfo.peerId,
      remote = conn.peerId,
      payload = sendPayload

    if sendPayload.isFinished():
      break

  # Signal to transfer protocol that this reconciliation is done
  await self.localWantsTx.addLast(conn.peerId)

  logos_delivery_reconciliation_roundtrips.observe(roundTrips)
  logos_delivery_reconciliation_differences.observe(diffs)

  await conn.close()

  return ok()

proc initiate(
    self: SyncReconciliation,
    connection: Connection,
    offset: Duration,
    syncRange: Duration,
    shards: seq[uint16],
): Future[Result[void, string]] {.async.} =
  self.expirePending()

  let
    timeRange = calculateTimeRange(self.clock(), offset, syncRange)
    lower = SyncID(time: timeRange.a, hash: EmptyFingerprint)
    upper = SyncID(time: timeRange.b, hash: FullFingerprint)
    bounds = lower .. upper
    pubsubTopics = shards.mapIt($RelayShard(clusterId: self.cluster, shardId: it))

    fingerprint = self.storage.computeFingerprint(bounds, pubsubTopics, @[])

    initPayload = RangesData(
      cluster: self.cluster,
      shards: shards,
      ranges: @[(bounds, RangeType.Fingerprint)],
      fingerprints: @[fingerprint],
      itemSets: @[],
    )

  let sendPayload = initPayload.deltaEncode()

  logos_delivery_total_bytes_exchanged.inc(
    sendPayload.len, labelValues = [Reconciliation, Sending]
  )

  try:
    await connection.writeLP(sendPayload)
  except LPStreamError as exc:
    await connection.close()
    return err("remote " & $connection.peerId & " connection write error: " & exc.msg)

  trace "sync payload sent",
    local = self.peerManager.switch.peerInfo.peerId,
    remote = connection.peerId,
    payload = initPayload

  ?await self.processRequest(connection)

  return ok()

proc storeSynchronization*(
    self: SyncReconciliation,
    peerInfo: Opt[RemotePeerInfo] = Opt.none(RemotePeerInfo),
    offset: Duration = self.relayJitter,
    syncRange: Duration = self.syncRange,
    shards: HashSet[uint16] = self.shards,
): Future[Result[void, string]] {.async.} =
  let peer = peerInfo.valueOr:
    self.peerManager.selectPeer(WakuReconciliationCodec).valueOr:
      return err("no suitable peer found for sync")

  let connOpt = await self.peerManager.dialPeer(peer, WakuReconciliationCodec)

  let conn: Connection = connOpt.valueOr:
    return err("fail to dial remote " & $peer.peerId)

  debug "Sync session initialized",
    local = self.peerManager.switch.peerInfo.peerId, remote = conn.peerId

  (await self.initiate(conn, offset, syncRange, shards.toSeq())).isOkOr:
    debug "Sync session failed",
      local = self.peerManager.switch.peerInfo.peerId, remote = conn.peerId, err = error

    return err("sync request error: " & error)

  debug "Sync session ended gracefully",
    local = self.peerManager.switch.peerInfo.peerId, remote = conn.peerId

  return ok()

proc initFillStorage(
    syncRange: timer.Duration, wakuArchive: WakuArchive, now: Timestamp
): Future[Result[SeqStorage, string]] {.async.} =
  if wakuArchive.isNil():
    return err("waku archive unavailable")

  let endTime = now
  let starTime = endTime - syncRange.nanos

  var query = ArchiveQuery(
    includeData: true,
    cursor: Opt.none(ArchiveCursor),
    startTime: Opt.some(starTime),
    endTime: Opt.some(endTime),
    pageSize: 100,
    direction: PagingDirection.FORWARD,
  )

  debug "Initial storage filling started"

  var storage = SeqStorage.new(DefaultStorageCap)

  while true:
    let response = (await wakuArchive.findMessages(query)).valueOr:
      return err("archive retrival failed: " & $error)

    # we assume IDs are already in order
    for i in 0 ..< response.hashes.len:
      let hash = response.hashes[i]
      let msg = response.messages[i]
      let pubsubTopic = response.topics[i]

      let id = SyncID(time: msg.timestamp, hash: hash)
      discard storage.insert(id, pubsubTopic, msg.contentTopic)

    if response.cursor.isNone():
      break

    query.cursor = response.cursor

  debug "Initial storage filling done", elements = storage.length()

  return ok(storage)

proc new*(
    T: type SyncReconciliation,
    cluster: uint16,
    shards: seq[uint16],
    peerManager: PeerManager,
    wakuArchive: WakuArchive,
    syncRange: timer.Duration = DefaultSyncRange,
    syncInterval: timer.Duration = DefaultSyncInterval,
    relayJitter: timer.Duration = DefaultGossipSubJitter,
    idsRx: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)],
    localWantsTx: AsyncQueue[PeerId],
    remoteNeedsTx: AsyncQueue[(PeerId, WakuMessageHash)],
    clock: proc(): Timestamp {.gcsafe, raises: [].} = getNowInNanosecondTime,
    pendingTimeout: timer.Duration = DefaultSyncInterval,
): Future[Result[T, string]] {.async.} =
  let timeRetention =
    if wakuArchive.isNil():
      Opt.none(Duration)
    else:
      wakuArchive.getShortestTimeRetention()
  let effectiveRange = clampSyncRange(syncRange, relayJitter, timeRetention)
  if effectiveRange != syncRange:
    warn "Store sync range reduced to fit the message time retention",
      requested_sync_range = syncRange,
      relay_jitter = relayJitter,
      time_retention = timeRetention.get(),
      effective_sync_range = effectiveRange,
      fix = "lower --store-sync-range or raise the time retention"

  let res = await initFillStorage(effectiveRange, wakuArchive, clock())
  let storage =
    if res.isErr():
      warn "will not sync messages before this point in time", error = res.error
      SeqStorage.new(DefaultStorageCap)
    else:
      res.get()

  var sync = SyncReconciliation(
    cluster: cluster,
    shards: shards.toHashSet(),
    peerManager: peerManager,
    storage: storage,
    syncRange: effectiveRange,
    syncInterval: syncInterval,
    relayJitter: relayJitter,
    clock: clock,
    pendingTimeout: pendingTimeout,
    idsRx: idsRx,
    localWantsTx: localWantsTx,
    remoteNeedsTx: remoteNeedsTx,
  )

  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    try:
      (await sync.processRequest(conn)).isOkOr:
        debug "Request processing error", error = error
    except CancelledError as exc:
      raise exc
    except CatchableError:
      error "exception in reconciliation handler", error = getCurrentExceptionMsg()

  sync.handler = handler
  sync.codec = WakuReconciliationCodec

  info "Store Reconciliation protocol initialized",
    sync_range = effectiveRange,
    sync_interval = syncInterval,
    relay_jitter = relayJitter

  return ok(sync)

func getEffectiveSyncRange*(self: SyncReconciliation): Duration =
  ## The sync range in use, after clamping to the archive's time retention.
  self.syncRange

proc periodicSync(self: SyncReconciliation) {.async.} =
  debug "Periodic sync initialized", interval = $self.syncInterval

  while true: # infinite loop
    await sleepAsync(self.syncInterval)

    debug "Periodic sync started"

    (await self.storeSynchronization()).isOkOr:
      debug "Periodic sync failed", err = error
      continue

    debug "Periodic sync done"

proc periodicPrune(self: SyncReconciliation) {.async.} =
  debug "Periodic prune initialized", interval = $self.syncInterval

  # preventing sync and prune loops of happening at the same time.
  await sleepAsync((self.syncInterval div 2))

  while true: # infinite loop
    await sleepAsync(self.syncInterval)

    debug "Periodic prune started"

    let time = self.clock() - self.syncRange.nanos

    let count = self.storage.prune(time)

    logos_delivery_total_messages_cached.set(self.storage.length())

    debug "Periodic prune done", elements_pruned = count

proc idsReceiverLoop(self: SyncReconciliation) {.async.} =
  while true: # infinite loop
    let (id, pubsub, content) = await self.idsRx.popfirst()

    self.messageIngress(id, pubsub, content)

method start*(self: SyncReconciliation) {.async: (raises: [CancelledError]).} =
  if self.started:
    return

  self.started = true

  if self.syncInterval > ZeroDuration:
    self.periodicSyncFut = self.periodicSync()

  if self.syncInterval > ZeroDuration:
    self.periodicPruneFut = self.periodicPrune()

  self.idsReceiverFut = self.idsReceiverLoop()

  info "Store Sync Reconciliation protocol started"

method stop*(self: SyncReconciliation) {.async: (raises: []).} =
  defer:
    self.started = false

  if self.syncInterval > ZeroDuration:
    await self.periodicSyncFut.cancelAndWait()

  if self.syncInterval > ZeroDuration:
    await self.periodicPruneFut.cancelAndWait()

  await self.idsReceiverFut.cancelAndWait()

  info "Store Sync Reconciliation protocol stopped"

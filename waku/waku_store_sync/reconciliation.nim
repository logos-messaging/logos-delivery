{.push raises: [].}

import
  std/[sequtils, options, sets],
  stew/byteutils,
  results,
  chronicles,
  chronos,
  metrics,
  libp2p/utility,
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

type SyncReconciliation* = ref object of LPProtocol
  pubsubTopics: HashSet[PubsubTopic] # Empty set means accept all. See spec.
  contentTopics: HashSet[ContentTopic] # Empty set means accept all. See spec.

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

  # futures
  periodicSyncFut: Future[void]
  periodicPruneFut: Future[void]
  idsReceiverFut: Future[void]

proc messageIngress*(
    self: SyncReconciliation, pubsubTopic: PubsubTopic, msg: WakuMessage
) =
  trace "message ingress", pubsub_topic = pubsubTopic, msg = msg

  if msg.ephemeral:
    return

  let msgHash = computeMessageHash(pubsubTopic, msg)

  let id = SyncID(time: msg.timestamp, hash: msgHash)

  self.storage.insert(id, pubsubTopic, msg.contentTopic).isOkOr:
    error "failed to insert new message", msg_hash = $byteutils.toHex(id.hash), error = $error

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

  self.storage.insert(id, pubsubTopic, msg.contentTopic).isOkOr:
    error "failed to insert new message", msg_hash = $byteutils.toHex(id.hash), error = $error

proc messageIngress*(
    self: SyncReconciliation,
    id: SyncID,
    pubsubTopic: PubsubTopic,
    contentTopic: ContentTopic,
) =
  self.storage.insert(id, pubsubTopic, contentTopic).isOkOr:
    error "failed to insert new message", msg_hash = $byteutils.toHex(id.hash), error = $error

proc preProcessPayload(
    self: SyncReconciliation, payload: RangesData
): Option[RangesData] =
  ## Check the received payload for topics and/or time mismatch.

  var payload = payload

  # Always use the smallest pubsub topic scope possible
  if payload.pubsubTopics.len > 0 and self.pubsubTopics.len > 0:
    let pubsubIntersection = self.pubsubTopics * payload.pubsubTopics.toHashSet()

    if pubsubIntersection.len < 1:
      return none(RangesData)

    payload.pubsubTopics = pubsubIntersection.toSeq()
  elif self.pubsubTopics.len > 0:
    payload.pubsubTopics = self.pubsubTopics.toSeq()

  # Always use the smallest content topic scope possible
  if payload.contentTopics.len > 0 and self.contentTopics.len > 0:
    let contentIntersection = self.contentTopics * payload.contentTopics.toHashSet()

    if contentIntersection.len < 1:
      return none(RangesData)

    payload.contentTopics = contentIntersection.toSeq()
  elif self.contentTopics.len > 0:
    payload.contentTopics = self.contentTopics.toSeq()

  let timeRange = calculateTimeRange(self.relayJitter, self.syncRange)
  let selfLowerBound = timeRange.a

  # for non skip ranges check if they happen before any of our ranges
  # convert to skip range before processing
  for i in 0 ..< payload.ranges.len:
    let rangeType = payload.ranges[i][1]
    if rangeType != RangeType.Skip:
      continue

    let upperBound = payload.ranges[i][0].b.time
    if selfLowerBound > upperBound:
      payload.ranges[i][1] = RangeType.Skip

      if rangeType == RangeType.Fingerprint:
        payload.fingerprints.delete(0)
      elif rangeType == RangeType.ItemSet:
        payload.itemSets.delete(0)
    else:
      break

  return some(payload)

proc processRequest(
    self: SyncReconciliation, conn: Connection
): Future[Result[void, string]] {.async.} =
  var
    roundTrips = 0
    diffs = 0

  # Signal to transfer protocol that this reconciliation is starting
  await self.localWantsTx.addLast(conn.peerId)

  while true:
    let readRes = catch:
      await conn.readLp(int.high)

    let buffer: seq[byte] = readRes.valueOr:
      await conn.close()
      return err("remote " & $conn.peerId & " connection read error: " & error.msg)

    total_bytes_exchanged.inc(buffer.len, labelValues = [Reconciliation, Receiving])

    let recvPayload = RangesData.deltaDecode(buffer).valueOr:
      await conn.close()
      return err("remote " & $conn.peerId & " payload decoding error: " & error)

    roundTrips.inc()

    trace "sync payload received",
      local = self.peerManager.switch.peerInfo.peerId,
      remote = conn.peerId,
      payload = recvPayload

    if recvPayload.ranges.len == 0 or recvPayload.ranges.allIt(it[1] == RangeType.Skip):
      break

    var
      hashToRecv: seq[WakuMessageHash]
      hashToSend: seq[WakuMessageHash]
      sendPayload: RangesData
      rawPayload: seq[byte]

    let preProcessedPayloadRes = self.preProcessPayload(recvPayload)
    if preProcessedPayloadRes.isSome():
      let preProcessedPayload = preProcessedPayloadRes.get()

      trace "pre-processed payload",
        local = self.peerManager.switch.peerInfo.peerId,
        remote = conn.peerId,
        payload = preProcessedPayload

      sendPayload =
        self.storage.processPayload(preProcessedPayload, hashToSend, hashToRecv)

      trace "sync payload processed",
        hash_to_send = hashToSend, hash_to_recv = hashToRecv

      sendPayload.pubsubTopics = self.pubsubTopics.toSeq()
      sendPayload.contentTopics = self.contentTopics.toSeq()

      for hash in hashToSend:
        self.remoteNeedsTx.addLastNoWait((conn.peerId, hash))
        diffs.inc()

      for hash in hashToRecv:
        diffs.inc()

      rawPayload = sendPayload.deltaEncode()

    total_bytes_exchanged.inc(rawPayload.len, labelValues = [Reconciliation, Sending])

    let writeRes = catch:
      await conn.writeLP(rawPayload)

    writeRes.isOkOr:
      await conn.close()
      return err("remote " & $conn.peerId & " connection write error: " & error.msg)

    trace "sync payload sent",
      local = self.peerManager.switch.peerInfo.peerId,
      remote = conn.peerId,
      payload = sendPayload

    if sendPayload.ranges.len == 0 or sendPayload.ranges.allIt(it[1] == RangeType.Skip):
      break

    continue

  # Signal to transfer protocol that this reconciliation is done
  await self.localWantsTx.addLast(conn.peerId)

  reconciliation_roundtrips.observe(roundTrips)
  reconciliation_differences.observe(diffs)

  await conn.close()

  return ok()

proc initiate(
    self: SyncReconciliation,
    connection: Connection,
    offset: Duration,
    syncRange: Duration,
    pubsubTopics: seq[PubsubTopic],
    contentTopics: seq[ContentTopic],
): Future[Result[void, string]] {.async.} =
  let
    timeRange = calculateTimeRange(offset, syncRange)
    lower = SyncID(time: timeRange.a, hash: EmptyFingerprint)
    upper = SyncID(time: timeRange.b, hash: FullFingerprint)
    bounds = lower .. upper

    fingerprint = self.storage.computeFingerprint(bounds, pubsubTopics, contentTopics)

    initPayload = RangesData(
      pubsubTopics: pubsubTopics,
      contentTopics: contentTopics,
      ranges: @[(bounds, RangeType.Fingerprint)],
      fingerprints: @[fingerprint],
      itemSets: @[],
    )

  let sendPayload = initPayload.deltaEncode()

  total_bytes_exchanged.inc(sendPayload.len, labelValues = [Reconciliation, Sending])

  let writeRes = catch:
    await connection.writeLP(sendPayload)

  writeRes.isOkOr:
    await connection.close()
    return err("remote " & $connection.peerId & " connection write error: " & error.msg)

  trace "sync payload sent",
    local = self.peerManager.switch.peerInfo.peerId,
    remote = connection.peerId,
    payload = initPayload

  ?await self.processRequest(connection)

  return ok()

proc storeSynchronization*(
    self: SyncReconciliation,
    peerInfo: Option[RemotePeerInfo] = none(RemotePeerInfo),
    offset: Duration = self.relayJitter,
    syncRange: Duration = self.syncRange,
    pubsubTopics: HashSet[PubsubTopic] = self.pubsubTopics,
    contentTopics: HashSet[ContentTopic] = self.contentTopics,
): Future[Result[void, string]] {.async.} =
  let peer = peerInfo.valueOr:
    self.peerManager.selectPeer(WakuReconciliationCodec).valueOr:
      return err("no suitable peer found for sync")

  let connOpt = await self.peerManager.dialPeer(peer, WakuReconciliationCodec)

  let conn: Connection = connOpt.valueOr:
    return err("fail to dial remote " & $peer.peerId)

  info "sync session initialized",
    local = self.peerManager.switch.peerInfo.peerId, remote = conn.peerId

  (
    await self.initiate(
      conn, offset, syncRange, pubsubTopics.toSeq(), contentTopics.toSeq()
    )
  ).isOkOr:
    error "sync session failed",
      local = self.peerManager.switch.peerInfo.peerId, remote = conn.peerId, err = error

    return err("sync request error: " & error)

  info "sync session ended gracefully",
    local = self.peerManager.switch.peerInfo.peerId, remote = conn.peerId

  return ok()

proc initFillStorage(
    syncRange: timer.Duration, wakuArchive: WakuArchive
): Future[Result[SeqStorage, string]] {.async.} =
  if wakuArchive.isNil():
    return err("waku archive unavailable")

  let endTime = getNowInNanosecondTime()
  let starTime = endTime - syncRange.nanos

  var query = ArchiveQuery(
    includeData: true,
    cursor: none(ArchiveCursor),
    startTime: some(starTime),
    endTime: some(endTime),
    pageSize: 100,
    direction: PagingDirection.FORWARD,
  )

  info "initial storage filling started"

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

  info "initial storage filling done", elements = storage.length()

  return ok(storage)

proc new*(
    T: type SyncReconciliation,
    pubsubTopics: seq[PubSubTopic],
    contentTopics: seq[ContentTopic],
    peerManager: PeerManager,
    wakuArchive: WakuArchive,
    syncRange: timer.Duration = DefaultSyncRange,
    syncInterval: timer.Duration = DefaultSyncInterval,
    relayJitter: timer.Duration = DefaultGossipSubJitter,
    idsRx: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)],
    localWantsTx: AsyncQueue[PeerId],
    remoteNeedsTx: AsyncQueue[(PeerId, WakuMessageHash)],
): Future[Result[T, string]] {.async.} =
  let res = await initFillStorage(syncRange, wakuArchive)
  let storage =
    if res.isErr():
      warn "will not sync messages before this point in time", error = res.error
      SeqStorage.new(DefaultStorageCap)
    else:
      res.get()

  var sync = SyncReconciliation(
    pubsubTopics: pubsubTopics.toHashSet(),
    contentTopics: contentTopics.toHashSet(),
    peerManager: peerManager,
    storage: storage,
    syncRange: syncRange,
    syncInterval: syncInterval,
    relayJitter: relayJitter,
    idsRx: idsRx,
    localWantsTx: localWantsTx,
    remoteNeedsTx: remoteNeedsTx,
  )

  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    try:
      (await sync.processRequest(conn)).isOkOr:
        error "request processing error", error = error
    except CatchableError:
      error "exception in reconciliation handler", error = getCurrentExceptionMsg()

  sync.handler = handler
  sync.codec = WakuReconciliationCodec

  info "Store Reconciliation protocol initialized",
    sync_range = syncRange, sync_interval = syncInterval, relay_jitter = relayJitter

  return ok(sync)

proc periodicSync(self: SyncReconciliation) {.async.} =
  info "periodic sync initialized", interval = $self.syncInterval

  while true: # infinite loop
    await sleepAsync(self.syncInterval)

    info "periodic sync started"

    (await self.storeSynchronization()).isOkOr:
      error "periodic sync failed", err = error
      continue

    info "periodic sync done"

proc periodicPrune(self: SyncReconciliation) {.async.} =
  info "periodic prune initialized", interval = $self.syncInterval

  # preventing sync and prune loops of happening at the same time.
  await sleepAsync((self.syncInterval div 2))

  while true: # infinite loop
    await sleepAsync(self.syncInterval)

    info "periodic prune started"

    let time = getNowInNanosecondTime() - self.syncRange.nanos

    let count = self.storage.prune(time)

    total_messages_cached.set(self.storage.length())

    info "periodic prune done", elements_pruned = count

proc idsReceiverLoop(self: SyncReconciliation) {.async.} =
  while true: # infinite loop
    let (id, pubsub, content) = await self.idsRx.popfirst()

    self.messageIngress(id, pubsub, content)

proc start*(self: SyncReconciliation) =
  if self.started:
    return

  self.started = true

  if self.syncInterval > ZeroDuration:
    self.periodicSyncFut = self.periodicSync()

  if self.syncInterval > ZeroDuration:
    self.periodicPruneFut = self.periodicPrune()

  self.idsReceiverFut = self.idsReceiverLoop()

  info "Store Sync Reconciliation protocol started"

proc stop*(self: SyncReconciliation) =
  if self.syncInterval > ZeroDuration:
    self.periodicSyncFut.cancelSoon()

  if self.syncInterval > ZeroDuration:
    self.periodicPruneFut.cancelSoon()

  self.idsReceiverFut.cancelSoon()

  info "Store Sync Reconciliation protocol stopped"

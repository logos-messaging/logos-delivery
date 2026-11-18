{.push raises: [].}

import
  std/[deques, sets, tables],
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
  ../common/rate_limit/timed_map,
  ../waku_enr,
  ../waku_core/codecs,
  ../waku_core/topics/pubsub_topic,
  ../waku_core/topics/content_topic,
  ../waku_core/message/digest,
  ../waku_core/message/message,
  ../waku_core/message/default_values,
  ../waku_core/time,
  ../node/peer_manager/peer_manager,
  ../waku_archive,
  ../waku_archive/common,
  ./common,
  ./codec,
  ./protocols_metrics

logScope:
  topics = "waku transfer"

# A node at the default --max-msg-size never archives a message above this, so
# only larger messages can be refused by a peer at or above the default.
const DefaultReadCap =
  int(DefaultMaxWakuMessageSize) + DefaultSafetyBufferProtocolOverhead

const MaxConcurrentPeers = 4
  ## Peers that pushes are sent to at the same time. Each one runs its own
  ## archive queries, so this caps the load that the pushes put on the database.

const MaxBatchSize = 10
  ## Pushes to one peer that are looked up in one archive query. The messages of
  ## a batch stay in memory until it is sent, up to MaxConcurrentPeers batches.

const MaxBatchSpan = Timestamp(5 * 60 * 1_000_000_000)
  ## Time between the oldest and the newest message of a batch, in nanoseconds,
  ## so that its lookup stays within few partitions.

type RequestedCheck* = proc(hash: WakuMessageHash): bool {.gcsafe, raises: [].}
  ## True when a reconciliation round asked for the message.

type PeerQueue = object
  ids: Deque[SyncID] # in the order that they were queued
  queued: HashSet[WakuMessageHash] # waiting or being sent

type SyncTransfer* = ref object of LPProtocol
  wakuArchive: WakuArchive
  peerManager: PeerManager

  isRequested: RequestedCheck

  # Send IDs to reconciliation protocol for storage
  idsTx: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)]

  # Receive Hashes from reconciliation protocol for reception
  localWantsRx: AsyncQueue[PeerId]
  localWantsRxFut: Future[void]
  inSessions: HashSet[PeerId]

  # Receive Hashes from reconciliation protocol for transmission
  remoteNeedsRx: AsyncQueue[(PeerId, SyncID)]
  remoteNeedsRxFut: Future[void]
  outSessions: Table[PeerId, Connection]

  # Pushes waiting, by peer. A peer is in `readyPeers` or with a sender while it
  # has an entry, so that its pushes leave in order.
  outQueues: Table[PeerId, PeerQueue]
  readyPeers: AsyncQueue[PeerId]
  sendersFut: seq[Future[void]]

  # Hashes above DefaultReadCap written into the open session to each peer
  largeSent: Table[PeerId, seq[WakuMessageHash]]
  # Not sent again until they leave the sync window
  refusedByPeer: TimedMap[(PeerId, WakuMessageHash), bool]

  # Largest encoded WakuMessageAndTopic the handler reads from a peer
  maxRpcSize: int

proc sendMessage(
    conn: Connection, payload: WakuMessageAndTopic
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  let rawPayload = payload.encode()

  logos_delivery_total_bytes_exchanged.inc(
    rawPayload.len, labelValues = [Transfer, Sending]
  )

  # SyncTransfer.stop waits for the loop that awaits this write.
  try:
    await conn.writeLP(rawPayload)
  except LPStreamError as exc:
    return err("remote [" & $conn.peerId & "] connection write error: " & exc.msg)

  logos_delivery_total_transfer_messages_exchanged.inc(labelValues = [Sending])

  return ok()

proc openConnection(
    self: SyncTransfer, peerId: PeerId
): Future[Result[Connection, string]] {.async.} =
  let connOpt = await self.peerManager.dialPeer(peerId, WakuTransferCodec)

  let conn: Connection = connOpt.valueOr:
    return err("fail to dial remote " & $peerId)

  debug "Transfer session initialized",
    local = self.peerManager.switch.peerInfo.peerId, remote = conn.peerId

  return ok(conn)

proc wantsReceiverLoop(self: SyncTransfer) {.async.} =
  ## Waits for peer ids of nodes
  ## we are reconciliating with

  while true: # infinite loop
    let peerId = await self.localWantsRx.popFirst()

    if self.inSessions.containsOrIncl(peerId):
      self.inSessions.excl(peerId)

  return

proc markRefused(self: SyncTransfer, peerId: PeerId) =
  ## A receiver resets the session on a message above its limit without saying
  ## which one, so any large message of an ended session may be it.
  var hashes: seq[WakuMessageHash]
  if self.largeSent.pop(peerId, hashes):
    for hash in hashes:
      discard self.refusedByPeer.mgetOrPut((peerId, hash), true)

proc queuePush(self: SyncTransfer, peerId: PeerId, id: SyncID) =
  ## A push that is already waiting or being sent to the peer is not queued again.
  self.outQueues.withValue(peerId, queue):
    if queue.queued.containsOrIncl(id.hash):
      trace "Skipping message already queued for the peer",
        remote_peer_id = peerId, msg_hash = id.hash.to0xHex()
      return
    queue.ids.addLast(id)
  do:
    var queue = PeerQueue(ids: initDeque[SyncID]())
    queue.ids.addLast(id)
    queue.queued.incl(id.hash)
    self.outQueues[peerId] = queue
    try:
      self.readyPeers.addLastNoWait(peerId)
    except AsyncQueueFullError:
      raiseAssert "readyPeers is unbounded"

proc needsReceiverLoop(self: SyncTransfer) {.async.} =
  ## Waits for the messages that peers need, and queues them by peer.
  while true: # infinite loop
    let (peerId, id) = await self.remoteNeedsRx.popFirst()
    self.queuePush(peerId, id)

proc findBatch(
    self: SyncTransfer, ids: seq[SyncID]
): Future[Result[Table[WakuMessageHash, WakuMessageAndTopic], string]] {.async.} =
  ## Looks the messages up in one query. The time bounds let a partitioned
  ## database search only the partitions that hold them.
  var
    startTime = ids[0].time
    endTime = ids[0].time
    query = ArchiveQuery(includeData: true, pageSize: uint(ids.len))
  for id in ids:
    startTime = min(startTime, id.time)
    endTime = max(endTime, id.time)
    query.hashes.add(id.hash)
  query.startTime = Opt.some(startTime)
  query.endTime = Opt.some(endTime + 1) # exclusive

  let response = (await self.wakuArchive.findMessages(query)).valueOr:
    return err("failed to query archive: " & $error)

  var found: Table[WakuMessageHash, WakuMessageAndTopic]
  for i in 0 ..< response.hashes.len:
    found[response.hashes[i]] =
      WakuMessageAndTopic(pubsub: response.topics[i], message: response.messages[i])
  return ok(found)

proc isRefused(self: SyncTransfer, peerId: PeerId, hash: WakuMessageHash): bool =
  # The ended session is checked first, so a hash refused in it is skipped even
  # when it is the first one queued again for that peer.
  var ended = false
  self.outSessions.withValue(peerId, conn):
    ## isClosedRemotely is a sanity check, should not be possible
    ended = conn[].closed() or conn[].isClosedRemotely
  if ended:
    ## quite possibly remote end has closed the connection, believing transfer to be done
    self.markRefused(peerId)
    self.outSessions.del(peerId)

  self.refusedByPeer.expire()
  if (peerId, hash) in self.refusedByPeer:
    debug "Skipping message the peer refused",
      remote_peer_id = peerId, msg_hash = hash.to0xHex()
    return true
  return false

proc sendBatch(
    self: SyncTransfer, peerId: PeerId, batch: seq[SyncID]
): Future[bool] {.async.} =
  ## Returns false when the peer cannot be dialled.
  # Filtered before the lookup, so a refused message is not read from the archive.
  var ids: seq[SyncID]
  for id in batch:
    if not self.isRefused(peerId, id.hash):
      ids.add(id)
  if ids.len == 0:
    return true

  var found = (await self.findBatch(ids)).valueOr:
    error "failed to find messages to push", remote_peer_id = peerId, error = error
    return true

  for id in ids:
    # Again, as the session may have ended while the batch was being sent.
    if self.isRefused(peerId, id.hash):
      continue

    var msg: WakuMessageAndTopic
    if not found.pop(id.hash, msg):
      debug "Message not found in db", msg_hash = id.hash.to0xHex()
      continue

    if not self.outSessions.hasKey(peerId):
      debug "Opening transfer connection to remote peer",
        my_peer_id = self.peerManager.switch.peerInfo.peerId, remote_peer_id = peerId

      let connection = (await self.openConnection(peerId)).valueOr:
        debug "Failed to establish transfer connection", error = error
        return false

      self.outSessions[peerId] = connection

    let connection = self.outSessions[peerId]

    trace "sending transfer message",
      my_peer_id = self.peerManager.switch.peerInfo.peerId,
      remote_peer_id = peerId,
      msg = msg

    # Recorded before the write: a message larger than the flow-control window
    # fails on its own write, and is then marked with the rest of the session.
    if msg.encode().len > DefaultReadCap:
      self.largeSent.mgetOrPut(peerId, @[]).add(id.hash)

    (await sendMessage(connection, msg)).isOkOr:
      self.markRefused(peerId)
      self.outSessions.del(peerId)
      await connection.close()
      debug "Failed to send message", error = error
      continue

  return true

proc senderLoop(self: SyncTransfer) {.async.} =
  ## Sends the pushes of one ready peer at a time, a batch per turn, so that a
  ## long backlog to one peer does not hold back the others.
  while true: # infinite loop
    let peerId = await self.readyPeers.popFirst()

    var batch: seq[SyncID]
    self.outQueues.withValue(peerId, queue):
      if queue.ids.len > 0:
        var
          minTime = queue.ids.peekFirst().time
          maxTime = minTime
        while batch.len < MaxBatchSize and queue.ids.len > 0:
          let time = queue.ids.peekFirst().time
          if max(maxTime, time) - min(minTime, time) > MaxBatchSpan:
            break
          minTime = min(minTime, time)
          maxTime = max(maxTime, time)
          batch.add(queue.ids.popFirst())

    # A raise must not end the loop, or the peer keeps an entry that no sender
    # serves, and its later pushes are queued and never sent.
    var reachable = true
    if batch.len > 0:
      try:
        reachable = await self.sendBatch(peerId, batch)
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        error "failed to push messages", remote_peer_id = peerId, error = exc.msg

    var hasMore = false
    self.outQueues.withValue(peerId, queue):
      for id in batch:
        queue.queued.excl(id.hash)
      hasMore = reachable and queue.ids.len > 0

    # A peer that cannot be dialled loses all its pushes, not only the batch, so
    # that a later batch does not reach it before an earlier one. A later round
    # finds them again.

    if hasMore:
      await self.readyPeers.addLast(peerId)
    else:
      self.outQueues.del(peerId)

proc initProtocolHandler(self: SyncTransfer) =
  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    var endReason = ""
    while true:
      ## removed DOS prototection until we can design something better
      #[ if not self.inSessions.contains(conn.peerId):
        error "unwanted peer, disconnecting", remote = conn.peerId
        break ]#

      let readRes = catch:
        await conn.readLp(self.maxRpcSize)

      let buffer: seq[byte] = readRes.valueOr:
        endReason = error.msg
        if error of MaxSizeError:
          # Only the length prefix was read. A reset makes the sender's write
          # fail instead of blocking on the bytes left unread (#4485).
          debug "Transfer message too large",
            remote_peer_id = conn.peerId, max_rpc_size = self.maxRpcSize
          logos_delivery_transfer_receive_failures.inc(labelValues = ["too_large"])
          await conn.reset()
        elif not (error of LPStreamEOFError or error of CancelledError):
          # Every session ends with an EOF, so only the other errors are failures.
          # The stream can no longer be framed, so it is reset like an oversized one.
          debug "Transfer read failed", remote_peer_id = conn.peerId, error = error.msg
          logos_delivery_transfer_receive_failures.inc(labelValues = ["read_error"])
          await conn.reset()
        break

      logos_delivery_total_bytes_exchanged.inc(
        buffer.len, labelValues = [Transfer, Receiving]
      )

      let payload = WakuMessageAndTopic.decode(buffer).valueOr:
        debug "Decoding error", error = $error
        logos_delivery_transfer_receive_failures.inc(labelValues = ["decode_error"])
        continue

      logos_delivery_total_transfer_messages_exchanged.inc(labelValues = [Receiving])

      let msg = payload.message
      let pubsub = payload.pubsub

      let hash = computeMessageHash(pubsub, msg)

      # A requested message that arrives after its pending entry expired is
      # dropped, and a later round asks for it again.
      if not self.isRequested(hash):
        debug "Transfer message not requested",
          remote_peer_id = conn.peerId, msg_hash = hash.to0xHex()
        logos_delivery_transfer_receive_failures.inc(labelValues = ["not_requested"])
        continue

      try:
        #TODO verify msg RLN proof...
        (await self.wakuArchive.syncMessageIngress(hash, pubsub, msg)).isOkOr:
          error "failed to archive message", error = $error
          continue
      except CancelledError as exc:
        raise exc
      except CatchableError:
        error "syncMessageIngress failed",
          remote_peer_id = conn.peerId, error = getCurrentExceptionMsg()
        continue

      let id = SyncID(time: msg.timestamp, hash: hash)

      await self.idsTx.addLast((id, pubsub, msg.contentTopic))

      continue

    await conn.close()

    debug "Transfer session ended",
      local = self.peerManager.switch.peerInfo.peerId,
      remote = conn.peerId,
      reason = endReason

    return

  self.handler = handler
  self.codec = WakuTransferCodec

proc new*(
    T: type SyncTransfer,
    peerManager: PeerManager,
    wakuArchive: WakuArchive,
    idsTx: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)],
    localWantsRx: AsyncQueue[PeerId],
    remoteNeedsRx: AsyncQueue[(PeerId, SyncID)],
    maxMessageSize: int,
    syncRange: Duration = DefaultSyncRange,
    isRequested: RequestedCheck,
): T =
  doAssert not isRequested.isNil(), "SyncTransfer needs a request check"

  var transfer = SyncTransfer(
    peerManager: peerManager,
    wakuArchive: wakuArchive,
    isRequested: isRequested,
    idsTx: idsTx,
    localWantsRx: localWantsRx,
    remoteNeedsRx: remoteNeedsRx,
    readyPeers: newAsyncQueue[PeerId](),
    refusedByPeer: TimedMap[(PeerId, WakuMessageHash), bool].init(syncRange),
    maxRpcSize: maxMessageSize + DefaultSafetyBufferProtocolOverhead,
  )

  transfer.initProtocolHandler()

  info "Store Transfer protocol initialized"

  return transfer

method start*(self: SyncTransfer) {.async: (raises: [CancelledError]).} =
  if self.started:
    return

  self.started = true

  self.localWantsRxFut = self.wantsReceiverLoop()
  self.remoteNeedsRxFut = self.needsReceiverLoop()
  self.sendersFut.setLen(0)
  for _ in 0 ..< MaxConcurrentPeers:
    self.sendersFut.add(self.senderLoop())

  info "Store Sync Transfer protocol started"

method stop*(self: SyncTransfer) {.async: (raises: []).} =
  defer:
    self.started = false

  await self.localWantsRxFut.cancelAndWait()
  await self.remoteNeedsRxFut.cancelAndWait()
  for fut in self.sendersFut:
    await fut.cancelAndWait()
  # A cancelled sender leaves its peer out of `readyPeers`, so nothing is kept.
  self.outQueues.clear()
  self.readyPeers.clear()

  info "Store Sync Transfer protocol stopped"

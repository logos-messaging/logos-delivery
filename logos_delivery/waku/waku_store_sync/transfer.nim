{.push raises: [].}

import
  std/[sets, tables],
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

# A push can overtake the reply that names it, so a few in a row are expected.
const MaxUnrequestedInARow = 10

type RequestedCheck* = proc(hash: WakuMessageHash): bool {.gcsafe, raises: [].}
  ## True when a reconciliation round asked for the message.

type SyncTransfer* = ref object of LPProtocol
  wakuArchive: WakuArchive
  peerManager: PeerManager

  # Nil accepts every message.
  isRequested: RequestedCheck

  # Send IDs to reconciliation protocol for storage
  idsTx: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)]

  # Receive Hashes from reconciliation protocol for reception
  localWantsRx: AsyncQueue[PeerId]
  localWantsRxFut: Future[void]
  inSessions: HashSet[PeerId]

  # Receive Hashes from reconciliation protocol for transmission
  remoteNeedsRx: AsyncQueue[(PeerId, WakuMessageHash)]
  remoteNeedsRxFut: Future[void]
  outSessions: Table[PeerId, Connection]

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

proc needsReceiverLoop(self: SyncTransfer) {.async.} =
  ## Waits for message hashes,
  ## open connection to the other peers,
  ## get the messages from DB and then send them.

  while true: # infinite loop
    let (peerId, fingerprint) = await self.remoteNeedsRx.popFirst()

    # Before the skip check, so a hash refused in the ended session is skipped
    # even when it is the first one queued again for that peer.
    if self.outSessions.hasKey(peerId) and (
      self.outSessions[peerId].closed() or
      ## sanity check, should not be possible
      self.outSessions[peerId].isClosedRemotely
    ):
      ## quite possibly remote end has closed the connection, believing transfer to be done
      self.markRefused(peerId)
      self.outSessions.del(peerId)

    self.refusedByPeer.expire()
    if (peerId, fingerprint) in self.refusedByPeer:
      debug "Skipping message the peer refused",
        remote_peer_id = peerId, msg_hash = fingerprint.to0xHex()
      continue

    if not self.outSessions.hasKey(peerId):
      debug "Opening transfer connection to remote peer",
        my_peer_id = self.peerManager.switch.peerInfo.peerId, remote_peer_id = peerId

      let connection = (await self.openConnection(peerId)).valueOr:
        debug "Failed to establish transfer connection", error = error
        continue

      self.outSessions[peerid] = connection

    let connection = self.outSessions[peerId]

    var query = ArchiveQuery()
    query.includeData = true
    query.hashes = @[fingerprint]

    let response = (await self.wakuArchive.findMessages(query)).valueOr:
      error "failed to query archive", error = error
      continue

    if response.messages.len < 1:
      debug "Message not found in db"
      continue

    let msg =
      WakuMessageAndTopic(pubsub: response.topics[0], message: response.messages[0])

    trace "sending transfer message",
      my_peer_id = self.peerManager.switch.peerInfo.peerId,
      remote_peer_id = peerId,
      msg = msg

    # Recorded before the write: a message larger than the flow-control window
    # fails on its own write, and is then marked with the rest of the session.
    if msg.encode().len > DefaultReadCap:
      self.largeSent.mgetOrPut(peerId, @[]).add(fingerprint)

    (await sendMessage(connection, msg)).isOkOr:
      self.markRefused(peerId)
      self.outSessions.del(peerId)
      await connection.close()
      debug "Failed to send message", error = error
      continue

  return

proc initProtocolHandler(self: SyncTransfer) =
  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    var endReason = ""
    var unrequestedInARow = 0
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

      # Under packet loss on QUIC a push can overtake the reply that names it,
      # and is dropped. The reply still marks it pending, so a round after the
      # pending entry expires asks for it again.
      if not self.isRequested.isNil() and not self.isRequested(hash):
        debug "Transfer message not requested",
          remote_peer_id = conn.peerId, msg_hash = hash.to0xHex()
        logos_delivery_transfer_receive_failures.inc(labelValues = ["not_requested"])
        unrequestedInARow.inc()
        if unrequestedInARow >= MaxUnrequestedInARow:
          endReason = "too many messages not requested"
          await conn.reset()
          break
        continue
      unrequestedInARow = 0

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
    remoteNeedsRx: AsyncQueue[(PeerId, WakuMessageHash)],
    maxMessageSize: int,
    syncRange: Duration = DefaultSyncRange,
    isRequested: RequestedCheck = nil,
): T =
  var transfer = SyncTransfer(
    peerManager: peerManager,
    wakuArchive: wakuArchive,
    isRequested: isRequested,
    idsTx: idsTx,
    localWantsRx: localWantsRx,
    remoteNeedsRx: remoteNeedsRx,
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

  info "Store Sync Transfer protocol started"

method stop*(self: SyncTransfer) {.async: (raises: []).} =
  defer:
    self.started = false

  await self.localWantsRxFut.cancelAndWait()
  await self.remoteNeedsRxFut.cancelAndWait()

  info "Store Sync Transfer protocol stopped"

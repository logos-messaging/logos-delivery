{.push raises: [].}

import
  std/[sets, tables],
  results,
  chronicles,
  chronos,
  metrics,
  libp2p/crypto/crypto,
  eth/p2p/discoveryv5/enr
import
  ../libp2p_iface/stream,
  ../libp2p_backend/host,
  ../common/nimchronos,
  ../common/protobuf,
  ../waku_enr,
  ../waku_core/codecs,
  ../waku_core/topics/pubsub_topic,
  ../waku_core/topics/content_topic,
  ../waku_core/message/codec,
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

type SyncTransfer* = ref object
  started: bool
  wakuArchive: WakuArchive
  peerManager: PeerManager
  maxMessageSize: int
    ## Largest encoded WakuMessage the node relays, so the largest it can be asked to sync

  # Send IDs to reconciliation protocol for storage
  idsTx: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)]

  # Receive Hashes from reconciliation protocol for reception
  localWantsRx: AsyncQueue[PeerId]
  localWantsRxFut: Future[void]
  inSessions: HashSet[PeerId]

  # Receive Hashes from reconciliation protocol for transmission
  remoteNeedsRx: AsyncQueue[(PeerId, WakuMessageHash)]
  remoteNeedsRxFut: Future[void]
  outSessions: Table[PeerId, Libp2pStream]

proc sendMessage[S: IStream](
    conn: S, payload: WakuMessageAndTopic
): Future[Result[void, string]] {.async.} =
  let rawPayload = payload.encode().buffer

  logos_delivery_total_bytes_exchanged.inc(
    rawPayload.len, labelValues = [Transfer, Sending]
  )

  let writeRes = catch:
    await conn.writeLP(rawPayload)

  writeRes.isOkOr:
    return err("remote [" & $conn.peerId & "] connection write error: " & error.msg)

  logos_delivery_total_transfer_messages_exchanged.inc(labelValues = [Sending])

  return ok()

proc openConnection(
    self: SyncTransfer, peerId: PeerId
): Future[Result[Libp2pStream, string]] {.async.} =
  let connOpt = await self.peerManager.dialPeer(peerId, WakuTransferCodec)

  let conn = connOpt.valueOr:
    return err("fail to dial remote " & $peerId)

  debug "Transfer session initialized",
    local = self.peerManager.selfPeerId(), remote = conn.peerId

  return ok(conn)

proc wantsReceiverLoop(self: SyncTransfer) {.async.} =
  ## Waits for peer ids of nodes
  ## we are reconciliating with

  while true: # infinite loop
    let peerId = await self.localWantsRx.popFirst()

    if self.inSessions.containsOrIncl(peerId):
      self.inSessions.excl(peerId)

  return

proc needsReceiverLoop(self: SyncTransfer) {.async.} =
  ## Waits for message hashes,
  ## open connection to the other peers,
  ## get the messages from DB and then send them.

  while true: # infinite loop
    let (peerId, fingerprint) = await self.remoteNeedsRx.popFirst()

    if (not self.outSessions.hasKey(peerId)) or self.outSessions[peerId].closed() or
      ## sanity check, should not be possible
    self.outSessions[peerId].isClosedRemotely:
      ## quite possibly remote end has closed the connection, believing transfer to be done
      debug "Opening transfer connection to remote peer",
        my_peer_id = self.peerManager.selfPeerId(), remote_peer_id = peerId

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

    ## The receiver ends its session at a message it cannot read, and drops the rest
    ## of the batch with it
    let encodedSize = msg.message.encode().buffer.len
    if encodedSize > self.maxMessageSize:
      debug "Skipping message over the transfer size limit",
        remote_peer_id = peerId, size = encodedSize, limit = self.maxMessageSize
      continue

    trace "sending transfer message",
      my_peer_id = self.peerManager.selfPeerId(), remote_peer_id = peerId, msg = msg

    let sent = await sendMessage(connection, msg)
    if sent.isErr():
      ## The remote may have closed the cached stream since the last round, which only
      ## shows on this write. Resend on a new stream instead of losing the message.
      debug "Failed to send message on cached connection, retrying", error = sent.error
      self.outSessions.del(peerId)
      await connection.close()

      let retryConnection = (await self.openConnection(peerId)).valueOr:
        debug "Failed to establish transfer connection", error = error
        continue

      self.outSessions[peerId] = retryConnection

      (await sendMessage(retryConnection, msg)).isOkOr:
        self.outSessions.del(peerId)
        await retryConnection.close()
        debug "Failed to send message", error = error
        continue

  return

proc handleStream*[S: IStream](
    self: SyncTransfer, conn: S, proto: string
) {.async: (raises: [CancelledError]).} =
  while true:
    ## removed DOS prototection until we can design something better
    #[ if not self.inSessions.contains(conn.peerId):
      error "unwanted peer, disconnecting", remote = conn.peerId
      break ]#

    let readRes = catch:
      await conn.readLp(
        int64(self.maxMessageSize + DefaultSafetyBufferProtocolOverhead)
      )

    let buffer: seq[byte] = readRes.valueOr:
      # connection closed normally
      break

    logos_delivery_total_bytes_exchanged.inc(
      buffer.len, labelValues = [Transfer, Receiving]
    )

    let payload = WakuMessageAndTopic.decode(buffer).valueOr:
      debug "Decoding error", error = $error
      continue

    logos_delivery_total_transfer_messages_exchanged.inc(labelValues = [Receiving])

    let msg = payload.message
    let pubsub = payload.pubsub

    let hash = computeMessageHash(pubsub, msg)

    try:
      #TODO verify msg RLN proof...
      (await self.wakuArchive.syncMessageIngress(hash, pubsub, msg)).isOkOr:
        error "failed to archive message", error = $error
        continue
    except CatchableError:
      error "syncMessageIngress failed",
        remote_peer_id = conn.peerId, error = getCurrentExceptionMsg()
      continue

    let id = SyncID(time: msg.timestamp, hash: hash)

    await self.idsTx.addLast((id, pubsub, msg.contentTopic))

    continue

  await conn.close()

  debug "Transfer session ended",
    local = self.peerManager.selfPeerId(), remote = conn.peerId

  return

proc new*(
    T: type SyncTransfer,
    peerManager: PeerManager,
    wakuArchive: WakuArchive,
    idsTx: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)],
    localWantsRx: AsyncQueue[PeerId],
    remoteNeedsRx: AsyncQueue[(PeerId, WakuMessageHash)],
    maxMessageSize: int = int(DefaultMaxWakuMessageSize),
): T =
  var transfer = SyncTransfer(
    peerManager: peerManager,
    wakuArchive: wakuArchive,
    idsTx: idsTx,
    localWantsRx: localWantsRx,
    remoteNeedsRx: remoteNeedsRx,
    maxMessageSize: maxMessageSize,
  )

  info "Store Transfer protocol initialized"

  return transfer

proc start*(self: SyncTransfer) {.async: (raises: [CancelledError]).} =
  if self.started:
    return

  self.started = true

  self.localWantsRxFut = self.wantsReceiverLoop()
  self.remoteNeedsRxFut = self.needsReceiverLoop()

  info "Store Sync Transfer protocol started"

proc stop*(self: SyncTransfer) {.async: (raises: []).} =
  if not self.started:
    return

  defer:
    self.started = false

  await self.localWantsRxFut.cancelAndWait()
  await self.remoteNeedsRxFut.cancelAndWait()

  info "Store Sync Transfer protocol stopped"

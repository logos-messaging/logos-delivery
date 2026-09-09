## Reliable Channel type.
##
## A `ReliableChannel` orchestrates segmentation, SDS (end-to-end
## reliability), optional per-channel encryption, and dispatch on top of
## the Messaging API for a single channel.
##
## Outgoing pipeline: Segment -> Encrypt -> SDS -> Dispatch
## Incoming pipeline: SDS -> Decrypt -> Reassemble -> Emit event
##
## Encryption sits *inside* the SDS wrap: only the `content` field is
## ciphertext, so routing metadata (channelId, causal history) stays
## readable and SDS's own history never holds plaintext.
##
## Channels are owned by a `ReliableChannelManager`. Lifecycle and send
## operations are addressed by `ChannelId`, so callers only need to keep
## an opaque handle around.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/tables
import results, chronos, chronicles
import bearssl/rand
import stew/byteutils
import libp2p/crypto/crypto as libp2p_crypto

import logos_delivery/api/types
import logos_delivery/api/reliable_channel_manager_api
import logos_delivery/api/events/messaging_client_events
import logos_delivery/api/messaging_client_api
import logos_delivery/api/events/reliable_channel_manager_events
import logos_delivery/messaging/messaging_client
import logos_delivery/waku/waku_core/topics

import ./segmentation/channel_segmentation
import ./scalable_data_sync/scalable_data_sync
import ./encryption/channel_encryption

export
  types, reliable_channel_manager_api, channel_segmentation, scalable_data_sync,
  channel_encryption

logScope:
  topics = "reliable-channel"

const LipWireReliableChannelVersion* = "RELIABLE-CHANNEL-API/1"
  ## Wire-format spec marker for the Reliable Channel layer, as defined
  ## in the reliable-channel-api LIP (`Wire Format / Spec Marker`).
  ## A `WakuMessage` whose `meta` field does not equal these bytes is
  ## not addressed to this layer and is silently dropped on ingress.
  ## The trailing `/N` is the wire-format version and is bumped only
  ## on breaking on-the-wire changes; implementations pin one version.

type
  MessagePersistence {.pure.} = enum
    Persistent
    Ephemeral

  ChannelReqState = object
    ## Per channel-level request, tracks how many of its segments are
    ## still in flight or have terminated. The channel-level final event
    ## fires when `confirmedCount + failedCount` reaches
    ## `totalExpectedSegments` AND no segments are still in flight.
    persistenceReqType: MessagePersistence
    totalExpectedSegments: int
      ## Total segments produced by `segmentation.performSegmentation`
      ## for this `channelReqId`. Set once in `send`, never mutated.
    inflightMessagingIds: seq[RequestId]
      ## Messaging-layer ids minted by the send handler that have not
      ## yet produced a final event. Removed on `MessageSentEvent` / `MessageErrorEvent`.
    confirmedCount: int
    failedCount: int

  ChannelReqs = Table[RequestId, ChannelReqState]
    ## Key: channelReqId (the parent id returned by channel `send`). Value:
    ## per-request state, see `ChannelReqState`.

  ReliableChannel* = ref object
    ## Spec-defined public type. Fields are private so callers cannot
    ## mutate internals and break invariants. Getters are added below
    ## for the few values consumers may need.
    channelId: ChannelId
    contentTopic: ContentTopic
    senderId: SdsParticipantID
    rng: libp2p_crypto.Rng
    segmentation: SegmentationHandler
    cleanupInterval: Duration
    cleanupFut: Future[void]
    sdsHandler: SdsHandler

    channelReqs: ChannelReqs
    brokerCtx: BrokerContext
    ingressLock: AsyncLock
      ## Serializes decrypt-and-report. SDS releases its own lock before
      ## returning, and an app cipher may suspend, so without this two
      ## concurrent arrivals could interleave and lose the causal order
      ## SDS exists to provide.
    encryption: ChannelEncryptionRegistry
      ## A cipher can be registered before the channel exists, and outlives its close.
    receivedListener: MessageReceivedEventListener
    sentListener: MessageSentEventListener
    errorListener: MessageErrorEventListener
    closed: bool

func init(
    T: type ChannelReqState,
    persistenceReqType: MessagePersistence,
    totalExpectedSegments: int,
): T =
  return ChannelReqState(
    persistenceReqType: persistenceReqType,
    totalExpectedSegments: totalExpectedSegments,
    inflightMessagingIds: @[],
    confirmedCount: 0,
    failedCount: 0,
  )

func getChannelId*(self: ReliableChannel): ChannelId {.inline.} =
  self.channelId

func getContentTopic*(self: ReliableChannel): ContentTopic {.inline.} =
  self.contentTopic

func getSenderId*(self: ReliableChannel): SdsParticipantID {.inline.} =
  self.senderId

proc stop*(self: ReliableChannel) {.async: (raises: []).} =
  ## Drops the event listeners and stops the SDS loops. Persisted SDS state survives.
  ## `closed` gates any in-flight receive handler that survives the listener drop.
  self.closed = true
  await MessageReceivedEvent.dropListener(self.brokerCtx, self.receivedListener)
  await MessageSentEvent.dropListener(self.brokerCtx, self.sentListener)
  await MessageErrorEvent.dropListener(self.brokerCtx, self.errorListener)
  if not self.cleanupFut.isNil():
    await self.cleanupFut.cancelAndWait()
  await self.sdsHandler.stop()

proc tryFinalizeChannelReq(self: ReliableChannel, channelReqId: RequestId) =
  ## Tries to finalize the channel-level request identified by `channelReqId` if
  ## certain conditions are met, i.e., no segments are still in flight and the
  ## total number of confirmed + failed segments equals the total expected segments.
  ## Therefore, the channel-level request is removed from `self.channelReqs`
  ## and the appropriate final event is emitted.
  ##
  let state = self.channelReqs.getOrDefault(channelReqId)
  if state.totalExpectedSegments == 0:
    ## Either already finalized (and removed) or never inserted.
    return
  if state.inflightMessagingIds.len != 0:
    return
  if state.confirmedCount + state.failedCount < state.totalExpectedSegments:
    return

  self.channelReqs.del(channelReqId)

  if state.failedCount > 0:
    ChannelMessageErrorEvent.emit(
      self.brokerCtx,
      ChannelMessageErrorEvent(
        channelId: self.channelId,
        requestId: channelReqId,
        error: "one or more segments failed",
      ),
    )
  else:
    ChannelMessageSentEvent.emit(
      self.brokerCtx,
      ChannelMessageSentEvent(channelId: self.channelId, requestId: channelReqId),
    )

type MessagingOutcome {.pure.} = enum
  Sent
  Failed

proc onMessageFinal(
    self: ReliableChannel, messagingReqId: RequestId, outcome: MessagingOutcome
) =
  for channelReqId, state in self.channelReqs.mpairs:
    let idx = state.inflightMessagingIds.find(messagingReqId)
    if idx < 0:
      continue
    state.inflightMessagingIds.del(idx)
    case outcome
    of MessagingOutcome.Sent:
      state.confirmedCount.inc()
    of MessagingOutcome.Failed:
      state.failedCount.inc()
    self.tryFinalizeChannelReq(channelReqId)
    return

proc markSegmentFailed(self: ReliableChannel, channelReqId: RequestId) =
  try:
    self.channelReqs[channelReqId].failedCount.inc()
  except KeyError as e:
    error "unreachable: channelReqId not found in markSegmentFailed",
      channelReqId = $channelReqId, error = e.msg
    return
  self.tryFinalizeChannelReq(channelReqId)

proc markSegmentInflight(
    self: ReliableChannel, channelReqId: RequestId, messagingReqId: RequestId
) =
  try:
    self.channelReqs[channelReqId].inflightMessagingIds.add(messagingReqId)
  except KeyError as e:
    error "unreachable: channelReqId not found in markSegmentInflight",
      channelReqId = $channelReqId, error = e.msg

func channelCrypto(self: ReliableChannel): Opt[ChannelCrypto] =
  ## Resolve once per message, never per segment: re-reading the registry
  ## mid-send would let a concurrent `clearChannelEncryption` push the
  ## remaining segments out in the clear.
  self.encryption.getChannelCrypto(self.channelId)

proc send*(
    self: ReliableChannel, payload: seq[byte], ephemeral: bool = false
): Future[Result[RequestId, string]] {.async: (raises: []).} =
  ## Single application-level send:
  ##
  ##   segmentation -> encryption -> sds -> dispatch
  ##
  ## The returned `RequestId` is the channel-level parent of one-or-more
  ## messaging-layer `RequestId`s; the mapping is held in
  ## `self.channelReqs` until every segment is final.
  if payload.len == 0:
    return err("empty payload")
  if self.closed:
    return err("channel is closed")

  let channelReqId = RequestId.new(self.rng)
  let persistenceReqType =
    if ephemeral: MessagePersistence.Ephemeral else: MessagePersistence.Persistent

  let segments = self.segmentation.performSegmentation(payload).valueOr:
    return err("segmentation failed: " & error)

  ## Encrypt every segment before wrapping any of them. `wrapOutgoing`
  ## registers a segment in SDS's outgoing buffer and causal history, so a
  ## half-wrapped send would leave orphans there that SDS retransmits on its
  ## own. Each ciphertext becomes one SDS `content` field.
  let cipher = self.channelCrypto()
  let encryptedSegments =
    if cipher.isNone():
      segments ## not encrypted: the segments go out as they are
    else:
      (await cipher.get().encrypt(segments)).valueOr:
        return err("encryption failed: " & error)

  var sdsSegments: seq[seq[byte]]
  for encrypted in encryptedSegments:
    if self.closed:
      return err("channel closed mid-send")

    ## Segments arrive already encoded; the segmentation module owns
    ## the wire format so SDS only ever sees opaque bytes.
    let sdsBytes = (await self.sdsHandler.wrapOutgoing(encrypted)).valueOr:
      debug "SDS wrap failed",
        channelId = self.channelId,
        error = error,
        wrapped = sdsSegments.len,
        total = encryptedSegments.len
      return err("SDS wrap failed: " & error)
    sdsSegments.add(sdsBytes)

  self.channelReqs[channelReqId] =
    ChannelReqState.init(persistenceReqType, sdsSegments.len)

  for i, sdsBytes in sdsSegments:
    if self.closed:
      self.channelReqs.del(channelReqId)
      debug "Channel closed mid-send, some segments already reached the wire",
        channelId = self.channelId, dispatched = i, total = sdsSegments.len
      return err("channel closed mid-send")

    ## The `meta` field carries the Reliable Channel wire-format spec
    ## marker so the ingress side of any peer can route this WakuMessage
    ## to its Reliable Channel layer.
    let envelope = MessageEnvelope(
      contentTopic: self.contentTopic,
      payload: sdsBytes,
      ephemeral: ephemeral,
      meta: LipWireReliableChannelVersion.toBytes(),
    )

    let messagingReqId = (await MessagingSend.request(self.brokerCtx, envelope)).valueOr:
      MessageErrorEvent.emit(
        self.brokerCtx,
        MessageErrorEvent(
          requestId: channelReqId,
          messageHash: "",
          error: "messaging send failed: " & error,
        ),
      )
      self.markSegmentFailed(channelReqId)
      continue

    self.markSegmentInflight(channelReqId, messagingReqId)

  return ok(channelReqId)

proc reportReceived(self: ReliableChannel, deliverable: SdsDeliverable) =
  ## Tail of the ingress pipeline (reassemble -> emit).
  if self.closed:
    return
  let reassembled = self.segmentation.handleIncomingSegment(deliverable.content).valueOr:
    error "Segmentation failed on an incoming segment",
      channelId = self.channelId, error = error
    return
  if reassembled.isNone():
    ## Stored but incomplete, or discarded.
    return

  info "Message received on reliable channel",
    channelId = self.channelId, senderId = deliverable.senderId
  ChannelMessageReceivedEvent.emit(
    self.brokerCtx,
    ChannelMessageReceivedEvent(
      channelId: self.channelId,
      senderId: deliverable.senderId,
      payload: reassembled.get().payload,
    ),
  )

proc dispatchRepair(self: ReliableChannel, wire: seq[byte]) {.async: (raises: []).} =
  ## SDS-driven repair rebroadcast. Pacing is done by SDS itself.
  ## No encryption step: `wire` is a re-serialized SDS message whose
  ## `content` was encrypted before the wrap, so replaying it verbatim
  ## cannot leak plaintext even if the cipher has since been cleared.
  ##
  ## Ephemeral: the original message is already store-persisted.
  let envelope = MessageEnvelope(
    contentTopic: self.contentTopic,
    payload: wire,
    ephemeral: true,
    meta: LipWireReliableChannelVersion.toBytes(),
  )

  (await MessagingSend.request(self.brokerCtx, envelope)).isOkOr:
    debug "SDS repair rebroadcast dropped: dispatch failed",
      channelId = self.channelId, error = error

proc dispatchRepairForTest*(
    self: ReliableChannel, wire: seq[byte]
): Future[void] {.async: (raises: []), used.} =
  ## SDS drives `dispatchRepair` from its own loop; tests reach it directly
  ## to check that a repair replays the wire verbatim.
  await self.dispatchRepair(wire)

proc deliverInOrder(
    self: ReliableChannel, deliverables: seq[SdsDeliverable], messageHash: string
) {.async: (raises: []).} =
  ## Decrypts and reports SDS's causally-ordered deliverables, one arrival at
  ## a time. A cipher may suspend and SDS releases its own lock before
  ## returning, so without serialising here a fast arrival would overtake a
  ## slow one and the application would see them out of order.
  try:
    await self.ingressLock.acquire()
  except CancelledError:
    # `stop` dropped this channel's listener: nobody left to deliver to.
    debug "inbound message dropped, channel closed during ingress",
      channelId = self.channelId, messageHash = messageHash
    return

  var ready: seq[SdsDeliverable]
  let crypto = self.channelCrypto()
  if crypto.isNone():
    ## Not encrypted: the SDS content is already plaintext.
    ready = deliverables
  else:
    let cipher = crypto.get()
    for item in deliverables:
      ## SDS already dropped traffic addressed to other channels, so a failure
      ## here is this channel's own message under the wrong key — a real
      ## misconfiguration the application needs to see, not routing noise.
      let plaintext = (await cipher.decrypt(item.content)).valueOr:
        ChannelMessageLostEvent.emit(
          self.brokerCtx,
          ChannelMessageLostEvent(
            channelId: self.channelId,
            payloadHash: @[], ## unknowable: the payload never decrypted
            reason:
              "decryption failed: " & error & " (messageHash: " & messageHash & ")",
          ),
        )
        continue
      ready.add(SdsDeliverable(content: plaintext, senderId: item.senderId))

  for item in ready:
    self.reportReceived(item)

  ## Nothing in the loop raises, so the lock is always released.
  try:
    self.ingressLock.release()
  except AsyncLockError as e:
    error "unreachable: channel ingress lock release failed",
      channelId = self.channelId, error = e.msg

proc onMessageReceived(
    self: ReliableChannel, messageHash: string, payload: seq[byte]
) {.async: (raises: []).} =
  ## Ingress pipeline made visible:
  ##
  ##   payload -> sds -> decrypt -> reassemble -> emit
  ##
  ## Invoked from this channel's `MessageReceivedEvent` listener, which
  ## already filtered on the spec marker and on `contentTopic`. The
  ## channel only sees the raw payload bytes for itself.
  if self.closed:
    return

  ## The SDS envelope travels in the clear, so SDS can route by `channelId`
  ## before anything is decrypted; only its `content` is ciphertext.
  ##
  ## SDS returns every payload deliverable now, in causal order — the
  ## message itself plus any parked segments it released. Empty = consumed
  ## by SDS (parked or duplicate). `err` is a real ingress failure here: the
  ## marker/contentTopic filter already ran, so surface it as an error event
  ## rather than dropping it silently.
  let deliverables = (await self.sdsHandler.handleIncoming(payload)).valueOr:
    MessageErrorEvent.emit(
      self.brokerCtx,
      MessageErrorEvent(
        requestId: RequestId(""),
        messageHash: messageHash,
        error: "SDS handleIncoming failed: " & error,
      ),
    )
    return

  await self.deliverInOrder(deliverables, messageHash)

proc segmentCleanupLoop(self: ReliableChannel) {.async.} =
  ## `handleIncomingSegment` sweeps on every arrival, so only a quiet channel needs this
  while not self.closed:
    await sleepAsync(self.cleanupInterval)
    self.segmentation.cleanupSegments()

proc new*(
    T: type ReliableChannel,
    channelId: ChannelId,
    contentTopic: ContentTopic,
    senderId: SdsParticipantID,
    segConfig: ChannelSegmentationConfig,
    sdsConfig: SdsConfig,
    brokerCtx: BrokerContext = globalBrokerContext(),
    encryption: ChannelEncryptionRegistry = nil,
): Result[T, string] =
  ## Pipeline handlers (segmentation/SDS) are constructed inside the
  ## channel rather than handed in by the caller — they are implementation
  ## details of the channel, not knobs the API consumer should be wiring
  ## up. `encryption` is the manager's registry, shared by reference; `nil`
  ## means plaintext.
  ##
  ## Segmentation is built first: it validates `segConfig`, and failing here
  ## leaves no started loop or installed listener behind.
  let segmentation = ?SegmentationHandler.new(segConfig, channelId, brokerCtx)

  let chn = T(
    channelId: channelId,
    contentTopic: contentTopic,
    senderId: senderId,
    rng: libp2p_crypto.newRng(),
    segmentation: segmentation,
    cleanupInterval: segConfig.cleanupInterval,
    sdsHandler: SdsHandler.new(sdsConfig, channelId, senderId),
    channelReqs: initTable[RequestId, ChannelReqState](),
    brokerCtx: brokerCtx,
    ingressLock: newAsyncLock(),
    encryption: encryption,
  )

  ## SDS-R repair rebroadcasts go straight to the dispatch tail.
  chn.sdsHandler.onRebroadcast = proc(wire: seq[byte]) {.gcsafe, raises: [].} =
    asyncSpawn chn.dispatchRepair(wire)
  chn.sdsHandler.start()
  chn.cleanupFut = chn.segmentCleanupLoop()

  ## Each channel owns its own ingress + send-completion listeners on
  ## `chn.brokerCtx`, filtered to traffic addressed to this channel.
  ## Keeping the listeners (and the handler procs they call) inside the
  ## channel lets `onMessageReceived` / `onMessageFinal` stay private —
  ## the manager doesn't need to know about them.
  chn.receivedListener = MessageReceivedEvent.listen(
    chn.brokerCtx,
    proc(evt: MessageReceivedEvent): Future[void] {.async: (raises: []).} =
      ## Drop foreign traffic (non-Reliable-Channel `meta`) and traffic
      ## for other channels before doing any decode work.
      if string.fromBytes(evt.message.meta) != LipWireReliableChannelVersion:
        return
      if evt.message.contentTopic != chn.contentTopic:
        return
      await chn.onMessageReceived(evt.messageHash, evt.message.payload)
    ,
  ).valueOr:
    error "MessageReceivedEvent.listen failed", channelId = channelId, error = error
    MessageReceivedEventListener()

  ## Send-completion events are tagged with the per-segment messaging
  ## `requestId` — globally unique, so we don't need any channel filter
  ## up front. The handler scans this channel's pending entries for a
  ## match and is a no-op when the id belongs to a different channel.
  chn.sentListener = MessageSentEvent.listen(
    chn.brokerCtx,
    proc(evt: MessageSentEvent): Future[void] {.async: (raises: []).} =
      chn.onMessageFinal(evt.requestId, MessagingOutcome.Sent),
  ).valueOr:
    error "MessageSentEvent.listen failed", channelId = channelId, error = error
    MessageSentEventListener()

  chn.errorListener = MessageErrorEvent.listen(
    chn.brokerCtx,
    proc(evt: MessageErrorEvent): Future[void] {.async: (raises: []).} =
      chn.onMessageFinal(evt.requestId, MessagingOutcome.Failed),
  ).valueOr:
    error "MessageErrorEvent.listen failed", channelId = channelId, error = error
    MessageErrorEventListener()

  return ok(chn)

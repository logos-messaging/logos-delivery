## Reliable Channel type.
##
## A `ReliableChannel` orchestrates segmentation, SDS (end-to-end
## reliability), optional per-channel encryption, and dispatch on top of
## the Messaging API for a single channel.
##
## Outgoing pipeline: Segment -> SDS -> Encrypt -> Dispatch
## Incoming pipeline: Decrypt -> SDS -> Reassemble -> Emit event
##
## Channels are owned by a `ReliableChannelManager`. Lifecycle and send
## operations are addressed by `ChannelId`, so callers only need to keep
## an opaque handle around.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/[sequtils, tables]
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

const SegmentRetryInterval = chronos.seconds(1)
  ## The pause before the next send of a segment that got `QueueFull`.

const QueueFullRetryWindow = chronos.minutes(1)
  ## How long the channel sends a segment again while the node holds too many sends.

const RateLimitedRetryWindow = chronos.minutes(30)
  ## How long the channel sends a segment again while the rate-limit budget is spent.

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
    inflightMessageHashes: seq[string]
      ## The message hashes that the messaging `send` returned and that have not
      ## yet produced a final event. Removed on `MessageSentEvent` / `MessageErrorEvent`.
    confirmedCount: int
    failedCount: int
    lastError: string

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
    crypto: Opt[ChannelCrypto] ## `none` means the channel is not encrypted
    receivedListener: MessageReceivedEventListener
    sentListener: MessageSentEventListener
    errorListener: MessageErrorEventListener
    closed: bool
    segmentRetries: seq[Future[void]] ## One `retrySegment` for each refused segment.
    segmentRetryInterval: Duration
    queueFullRetryWindow: Duration
    rateLimitedRetryWindow: Duration

func init(
    T: type ChannelReqState,
    persistenceReqType: MessagePersistence,
    totalExpectedSegments: int,
): T =
  return ChannelReqState(
    persistenceReqType: persistenceReqType,
    totalExpectedSegments: totalExpectedSegments,
    inflightMessageHashes: @[],
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
  await cancelAndWait(self.segmentRetries)
  self.segmentRetries = @[]
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
  if state.inflightMessageHashes.len != 0:
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
        error: "one or more segments failed: " & state.lastError,
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
    self: ReliableChannel, messageHash: string, outcome: MessagingOutcome, error = ""
) =
  for channelReqId, state in self.channelReqs.mpairs:
    let idx = state.inflightMessageHashes.find(messageHash)
    if idx < 0:
      continue
    state.inflightMessageHashes.del(idx)
    case outcome
    of MessagingOutcome.Sent:
      state.confirmedCount.inc()
    of MessagingOutcome.Failed:
      state.failedCount.inc()
      state.lastError = error
    self.tryFinalizeChannelReq(channelReqId)
    return

proc markSegmentFailed(self: ReliableChannel, channelReqId: RequestId, error: string) =
  try:
    self.channelReqs[channelReqId].failedCount.inc()
    self.channelReqs[channelReqId].lastError = error
  except KeyError as e:
    error "unreachable: channelReqId not found in markSegmentFailed",
      channelReqId = $channelReqId, error = e.msg
    return
  self.tryFinalizeChannelReq(channelReqId)

proc markSegmentInflight(
    self: ReliableChannel, channelReqId: RequestId, messageHash: string
) =
  try:
    self.channelReqs[channelReqId].inflightMessageHashes.add(messageHash)
  except KeyError as e:
    error "unreachable: channelReqId not found in markSegmentInflight",
      channelReqId = $channelReqId, error = e.msg

proc sendSegment(
    self: ReliableChannel, envelope: MessageEnvelope
): Future[SendResult] {.async: (raises: []).} =
  let sendResult = (await MessagingSend.request(self.brokerCtx, envelope)).valueOr:
    return err(SendError.init(SendErrorKind.Other, error))
  return sendResult

func retryWindow(self: ReliableChannel, error: SendError): Duration =
  ## How long the channel sends a refused segment again.
  ## Zero for a refusal that a later send cannot clear.
  case error.kind
  of SendErrorKind.QueueFull:
    self.queueFullRetryWindow
  of SendErrorKind.RateLimited:
    self.rateLimitedRetryWindow
  of SendErrorKind.TooLarge, SendErrorKind.Duplicate, SendErrorKind.Other:
    ZeroDuration

proc retrySegment(
    self: ReliableChannel,
    channelReqId: RequestId,
    envelope: MessageEnvelope,
    refusal: SendError,
) {.async: (raises: [CancelledError]).} =
  ## The messaging layer keeps no message that it refused, so the channel does.
  let started = Moment.now()
  var lastError = refusal
  while true:
    let pause =
      if lastError.kind == SendErrorKind.RateLimited and
          lastError.retryAfter > ZeroDuration:
        lastError.retryAfter
      else:
        self.segmentRetryInterval
    # The window is the window of the last refusal, because its kind can change.
    let window = self.retryWindow(lastError)
    if window == ZeroDuration or Moment.now() + pause > started + window:
      break
    await sleepAsync(pause)
    let messageHash = (await self.sendSegment(envelope)).valueOr:
      lastError = error
      continue
    self.markSegmentInflight(channelReqId, messageHash.to0xHex())
    return

  self.markSegmentFailed(channelReqId, "messaging send failed: " & $lastError)

proc startSegmentRetry(
    self: ReliableChannel,
    channelReqId: RequestId,
    envelope: MessageEnvelope,
    refusal: SendError,
) =
  ## The channel request stays open while it runs, as the segment has no result yet.
  self.segmentRetries.keepItIf(not it.finished())
  self.segmentRetries.add(self.retrySegment(channelReqId, envelope, refusal))

proc send*(
    self: ReliableChannel, payload: seq[byte], ephemeral: bool = false
): Future[Result[RequestId, string]] {.async: (raises: []).} =
  ## Single application-level send:
  ##
  ##   segmentation -> sds -> encryption -> dispatch
  ##
  ## The returned `RequestId` is the channel-level parent of one-or-more
  ## messaging-layer message hashes; the mapping is held in
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

  var sdsSegments: seq[seq[byte]]
  for segmentBytes in segments:
    ## Segments arrive already encoded; the segmentation module owns
    ## the wire format so SDS only ever sees opaque bytes.
    let sdsBytes = (await self.sdsHandler.wrapOutgoing(segmentBytes)).valueOr:
      debug "SDS wrap failed",
        channelId = self.channelId,
        error = error,
        wrapped = sdsSegments.len,
        total = segments.len
      return err("SDS wrap failed: " & error)
    sdsSegments.add(sdsBytes)

  ## Encrypt every wrapped segment before dispatching any, so a cipher
  ## failure never puts part of a message on the wire.
  let wireSegments =
    if self.crypto.isNone():
      sdsSegments
    else:
      (await self.crypto.get().encrypt(sdsSegments)).valueOr:
        return err("encryption failed: " & error)

  self.channelReqs[channelReqId] =
    ChannelReqState.init(persistenceReqType, wireSegments.len)

  for i, wireBytes in wireSegments:
    if self.closed:
      self.channelReqs.del(channelReqId)
      debug "Channel closed mid-send, some segments already reached the wire",
        channelId = self.channelId, dispatched = i, total = wireSegments.len
      return err("channel closed mid-send")

    ## The `meta` field carries the Reliable Channel wire-format spec
    ## marker so the ingress side of any peer can route this WakuMessage
    ## to its Reliable Channel layer.
    let envelope = MessageEnvelope(
      contentTopic: self.contentTopic,
      payload: wireBytes,
      ephemeral: ephemeral,
      meta: LipWireReliableChannelVersion.toBytes(),
    )

    let messageHash = (await self.sendSegment(envelope)).valueOr:
      if self.retryWindow(error) > ZeroDuration:
        self.startSegmentRetry(channelReqId, envelope, error)
      else:
        self.markSegmentFailed(channelReqId, "messaging send failed: " & $error)
      continue

    self.markSegmentInflight(channelReqId, messageHash.to0xHex())

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
  ## SDS-driven repair rebroadcast; SDS paces it. `wire` is SDS's cached
  ## cleartext copy, so it is sealed again like any other send. Ephemeral
  ## because the original is already store-persisted.
  var payload = wire
  if self.crypto.isSome():
    let sealed = (await self.crypto.get().encrypt(@[wire])).valueOr:
      debug "SDS repair rebroadcast dropped: encryption failed",
        channelId = self.channelId, error = error
      return
    payload = sealed[0]

  let envelope = MessageEnvelope(
    contentTopic: self.contentTopic,
    payload: payload,
    ephemeral: true,
    meta: LipWireReliableChannelVersion.toBytes(),
  )

  let sendResult = (await MessagingSend.request(self.brokerCtx, envelope)).valueOr:
    debug "SDS repair rebroadcast dropped: dispatch failed",
      channelId = self.channelId, error = error
    return
  sendResult.isOkOr:
    debug "SDS repair rebroadcast dropped: send refused",
      channelId = self.channelId, error = $error

proc onMessageReceived(
    self: ReliableChannel, messageHash: string, payload: seq[byte]
) {.async: (raises: []).} =
  ## Ingress pipeline made visible:
  ##
  ##   payload -> decrypt -> sds -> reassemble -> emit
  ##
  ## Invoked from this channel's `MessageReceivedEvent` listener, which
  ## already filtered on the spec marker and on `contentTopic`. The
  ## channel only sees the raw payload bytes for itself.
  if self.closed:
    return

  ## Channels sharing a content topic tell their traffic apart by whether it
  ## decrypts, so a failure here is routine rather than an error.
  let sdsWire =
    if self.crypto.isNone():
      payload
    else:
      (await self.crypto.get().decrypt(payload)).valueOr:
        debug "channel decryption failed",
          channelId = self.channelId, messageHash = messageHash, error = error
        return

  ## SDS returns every payload deliverable now, in causal order — the
  ## message itself plus any parked segments it released. Empty = consumed
  ## by SDS (parked or duplicate). `err` is a real ingress failure here: the
  ## marker/contentTopic filter already ran. `MessageErrorEvent` reports only a
  ## send of this node, so the failure goes to the log.
  let deliverables = (await self.sdsHandler.handleIncoming(sdsWire)).valueOr:
    debug "SDS handleIncoming failed",
      channelId = self.channelId, messageHash = messageHash, error = error
    return

  for item in deliverables:
    self.reportReceived(item)

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
    encryption: Opt[ChannelCrypto] = Opt.none(ChannelCrypto),
): Result[T, string] =
  ## Pipeline handlers (segmentation/SDS) are constructed inside the
  ## channel rather than handed in by the caller — they are implementation
  ## details of the channel, not knobs the API consumer should be wiring
  ## up. `encryption` is fixed for the channel's life; `none` means plaintext.
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
    crypto: encryption,
    segmentRetryInterval: SegmentRetryInterval,
    queueFullRetryWindow: QueueFullRetryWindow,
    rateLimitedRetryWindow: RateLimitedRetryWindow,
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

  ## Send-completion events are tagged with the per-segment message
  ## hash — globally unique, so we don't need any channel filter
  ## up front. The handler scans this channel's pending entries for a
  ## match and is a no-op when the hash belongs to a different channel.
  chn.sentListener = MessageSentEvent.listen(
    chn.brokerCtx,
    proc(evt: MessageSentEvent): Future[void] {.async: (raises: []).} =
      chn.onMessageFinal(evt.messageHash, MessagingOutcome.Sent),
  ).valueOr:
    error "MessageSentEvent.listen failed", channelId = channelId, error = error
    MessageSentEventListener()

  chn.errorListener = MessageErrorEvent.listen(
    chn.brokerCtx,
    proc(evt: MessageErrorEvent): Future[void] {.async: (raises: []).} =
      chn.onMessageFinal(evt.messageHash, MessagingOutcome.Failed, evt.error),
  ).valueOr:
    error "MessageErrorEvent.listen failed", channelId = channelId, error = error
    MessageErrorEventListener()

  return ok(chn)

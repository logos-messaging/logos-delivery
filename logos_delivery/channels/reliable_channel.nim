import logos_delivery/waku/compat/option_valueor
## Reliable Channel type.
##
## A `ReliableChannel` orchestrates segmentation, SDS (end-to-end
## reliability), optional encryption, and rate-limited dispatch on top
## of the Messaging API for a single channel.
##
## Outgoing pipeline: Segment -> SDS -> Rate Limit -> Encrypt -> Dispatch
## Incoming pipeline: Decrypt -> SDS -> Reassemble -> Emit event
##
## Channels are owned by a `ReliableChannelManager`. Lifecycle and send
## operations are addressed by `ChannelId`, so callers only need to keep
## an opaque handle around.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/[options, tables]
import results
import chronos
import bearssl/rand
import stew/byteutils
import libp2p/crypto/crypto as libp2p_crypto

import logos_delivery/api/messaging_client_interface as mci
import logos_delivery/api/types
import logos_delivery/waku/waku_core/topics

import ./events
import ./segmentation/segmentation
import ./scalable_data_sync/scalable_data_sync
import ./rate_limit_manager/rate_limit_manager
import ./encryption/encryption

export types, events, segmentation, scalable_data_sync, rate_limit_manager, encryption

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
    ## still queued, in flight, or have terminated. The channel-level
    ## final event fires when `confirmedCount + failedCount` reaches
    ## `totalExpectedSegments` AND no segments are still awaiting dispatch
    ## or in flight.
    persistenceReqType: MessagePersistence
    totalExpectedSegments: int
      ## Total segments produced by `segmentation.performSegmentation`
      ## for this `channelReqId`. Set once in `send`, never mutated.
    awaitingDispatch: int
      ## Segments enqueued in `rate_limit_manager` but not yet claimed
      ## by `onReadyToSend`. Decremented when `onReadyToSend` picks a
      ## message and assigns it to this `channelReqId`.
    inflightMessagingIds: seq[RequestId]
      ## Messaging-layer ids minted by the send handler that have not
      ## yet produced a final event. Removed on `MessageSentEvent` / `MessageErrorEvent`.
    confirmedCount: int
    failedCount: int

  ChannelReqs = OrderedTable[RequestId, ChannelReqState]
    ## Key: channelReqId (the parent id returned by channel `send`). Value:
    ## per-request state, see `ChannelReqState`.
    ##
    ## `OrderedTable` preserves insertion order, which matches the FIFO
    ## order `rate_limit_manager` re-emits messages in: `onReadyToSend`
    ## routes each segment to the first entry with `awaitingDispatch > 0`,
    ## and that scan is correct precisely because the outer iteration
    ## order matches the order `send` pushed entries.

  ReliableChannel* = ref object
    ## Spec-defined public type. Fields are private so callers cannot
    ## mutate internals and break invariants. Getters are added below
    ## for the few values consumers may need.
    messagingClient: MessagingClientInterface
    channelId: ChannelId
    contentTopic: ContentTopic
    senderId: SdsParticipantID
    rng: libp2p_crypto.Rng
    segmentation: SegmentationHandler
    sdsHandler: SdsHandler
    rateLimit: RateLimitManager

    channelReqs: ChannelReqs
    brokerCtx: BrokerContext

func init(
    T: type ChannelReqState,
    persistenceReqType: MessagePersistence,
    totalExpectedSegments: int,
): T =
  return ChannelReqState(
    persistenceReqType: persistenceReqType,
    totalExpectedSegments: totalExpectedSegments,
    awaitingDispatch: totalExpectedSegments,
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
  ## Stops the SDS background loops. Persisted SDS state survives.
  await self.sdsHandler.stop()

proc tryFinalizeChannelReq(
    self: ReliableChannel, channelReqId: RequestId
) {.async: (raises: []).} =
  ## Tries to finalize the channel-level request identified by `channelReqId` if
  ## certain conditions are met, i.e., no segments are still awaiting dispatch or in flight,
  ## and the total number of confirmed + failed segments equals the total expected segments.
  ## Therefore, the channel-level request is removed from `self.channelReqs`
  ## and the appropriate final event is emitted.
  ##
  let state = self.channelReqs.getOrDefault(channelReqId)
  if state.totalExpectedSegments == 0:
    ## Either already finalized (and removed) or never inserted.
    return
  if state.awaitingDispatch != 0 or state.inflightMessagingIds.len != 0:
    return
  if state.confirmedCount + state.failedCount < state.totalExpectedSegments:
    return

  self.channelReqs.del(channelReqId)

  if state.failedCount > 0:
    ChannelMessageErrorEvent.emit(
      self.brokerCtx,
      channelId = self.channelId,
      requestId = channelReqId,
      error = "one or more segments failed",
    )
  else:
    ChannelMessageSentEvent.emit(
      self.brokerCtx, channelId = self.channelId, requestId = channelReqId
    )

type ClaimedSegment = object
  channelReqId: RequestId
  isEphemeral: bool

proc claimAwaitingChannelReq(self: ReliableChannel): Option[ClaimedSegment] =
  for channelReqId, state in self.channelReqs.mpairs:
    if state.awaitingDispatch > 0:
      state.awaitingDispatch.dec()
      return some(
        ClaimedSegment(
          channelReqId: channelReqId,
          isEphemeral: state.persistenceReqType == MessagePersistence.Ephemeral,
        )
      )
  return none(ClaimedSegment)

type MessagingOutcome {.pure.} = enum
  Sent
  Failed

proc onMessageFinal(
    self: ReliableChannel, messagingReqId: RequestId, outcome: MessagingOutcome
) {.async.} =
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
    await self.tryFinalizeChannelReq(channelReqId)
    return

proc markSegmentFailed(
    self: ReliableChannel, channelReqId: RequestId
) {.async: (raises: []).} =
  try:
    self.channelReqs[channelReqId].failedCount.inc()
  except KeyError as e:
    error "unreachable: channelReqId not found in markSegmentFailed",
      channelReqId = $channelReqId, error = e.msg
    return
  await self.tryFinalizeChannelReq(channelReqId)

proc markSegmentInflight(
    self: ReliableChannel, channelReqId: RequestId, messagingReqId: RequestId
) =
  try:
    self.channelReqs[channelReqId].inflightMessagingIds.add(messagingReqId)
  except KeyError as e:
    error "unreachable: channelReqId not found in markSegmentInflight",
      channelReqId = $channelReqId, error = e.msg

proc onReadyToSend(
    self: ReliableChannel, readyToSendEvent: ReadyToSendEvent
) {.async: (raises: []).} =
  ## Tail of the outgoing pipeline. Invoked from the `ReadyToSendEvent`
  ## listener once `rate_limit_manager` releases a batch of opaque
  ## blobs (already-encoded SDS messages):
  ##
  ##   ... -> rate_limit_manager -> [encryption] -> dispatch
  ##
  ## For each `m`, the next channelReqId still queued in rate-limit
  ## claims the slot (FIFO across sibling sends). The channelReqId is
  ## captured up front and used as a stable key for every later state
  ## update — no positional index is ever held across an `await`, so
  ## sibling events mutating other entries (or even this one's
  ## `inflightMessagingIds`) cannot corrupt this fiber's view.
  for m in readyToSendEvent.msgs:
    let claimed = self.claimAwaitingChannelReq().valueOr:
      ## rate_limit_manager emitted more messages than we have pending —
      ## should not happen given `send` increments `awaitingDispatch`
      ## once per enqueued SDS payload. Drop silently rather than
      ## corrupt state.
      break
    let channelReqId = claimed.channelReqId
    let isEphemeral = claimed.isEphemeral

    ## TODO: revisit which fields of the SDS message must be encrypted.
    ## Encrypting the whole encoded blob forces every receiver to attempt
    ## decryption before it can route, which breaks selective dispatch.
    ## Leave routing metadata (channelId, causal-history references) in
    ## clear and encrypt only the application payload.
    let encRes = await Encrypt.request(m)
    let encrypted = encRes.valueOr:
      ### TODO: Emitting of events from another layer is not completly ok to do so.
      mci.MessageErrorEvent.emit(
        self.brokerCtx,
        requestId = channelReqId,
        messageHash = "",
        error = "encryption failed: " & error,
      )
      ## Encryption failed *before* we could hand the segment to the
      await self.markSegmentFailed(channelReqId)
      continue
    let wireBytes = seq[byte](encrypted)

    ## The `meta` field carries the Reliable Channel wire-format spec
    ## marker so the ingress side of any peer can route this WakuMessage
    ## to its Reliable Channel layer.
    let envelope = MessageEnvelope(
      contentTopic: self.contentTopic,
      payload: wireBytes,
      ephemeral: isEphemeral,
      meta: LipWireReliableChannelVersion.toBytes(),
    )

    ## `messagingClient.send` is not annotated `(raises: [])`, but this listener is.
    ## Convert any raise to a Result error so the state machine handles
    ## both failure modes (Result.err and exception) through one path.
    let sendRes =
      try:
        await self.messagingClient.send(envelope)
      except CatchableError as e:
        Result[RequestId, string].err("messaging send raised: " & e.msg)

    let messagingReqId = sendRes.valueOr:
      ### TODO: Emitting of events from another layer is not completly ok to do so.
      mci.MessageErrorEvent.emit(
        self.brokerCtx,
        requestId = channelReqId,
        messageHash = "",
        error = "messaging send failed: " & error,
      )
      await self.markSegmentFailed(channelReqId)
      continue

    self.markSegmentInflight(channelReqId, messagingReqId)

proc send*(
    self: ReliableChannel, payload: seq[byte], ephemeral: bool = false
): Future[Result[RequestId, string]] {.async: (raises: []).} =
  ## Single application-level send. The first three stages of the
  ## outgoing pipeline are chained explicitly so the flow is visible
  ## at a glance:
  ##
  ##   segmentation -> sds -> rate_limit_manager
  ##
  ## `rate_limit_manager.enqueueToSend` emits a `ReadyToSendEvent` with
  ## the SDS messages cleared for transmission; the channel's listener
  ## then runs the final stage (encryption -> dispatch).
  ##
  ## The returned `RequestId` is the channel-level parent of one-or-more
  ## messaging-layer `RequestId`s; the mapping is held in
  ## `self.channelReqs` until every segment is final.
  if payload.len == 0:
    return err("empty payload")

  let channelReqId = RequestId.new(self.rng)
  let persistenceReqType =
    if ephemeral: MessagePersistence.Ephemeral else: MessagePersistence.Persistent

  var segmentCount = 0
  var enqueued: seq[seq[byte]]
  for segmentBytes in self.segmentation.performSegmentation(payload):
    ## Segments arrive already encoded; the segmentation module owns
    ## the wire format so SDS only ever sees opaque bytes.
    let sdsBytes = (await self.sdsHandler.wrapOutgoing(segmentBytes)).valueOr:
      return err("SDS wrap failed: " & error)
    enqueued.add(sdsBytes)
    segmentCount.inc()

  self.channelReqs[channelReqId] =
    ChannelReqState.init(persistenceReqType, segmentCount)

  for sdsBytes in enqueued:
    self.rateLimit.enqueueToSend(sdsBytes)

  return ok(channelReqId)

proc reportReceived(self: ReliableChannel, content: seq[byte]) =
  ## Tail of the ingress pipeline (reassemble -> emit).
  let reassembled = self.segmentation.handleIncomingSegment(content)
  if reassembled.isSome():
    ## Emit on the captured `brokerCtx` (the manager's), so the
    ## application listener that the manager has set up on that same
    ## context picks the event up.
    ChannelMessageReceivedEvent.emit(
      self.brokerCtx,
      ChannelMessageReceivedEvent(
        channelId: self.channelId,
        senderId: self.senderId,
        payload: reassembled.get().payload,
      ),
    )

proc dispatchRepair(self: ReliableChannel, wire: seq[byte]) {.async: (raises: []).} =
  ## Repair rebroadcasts skip the rate-limit queue — its emissions are
  ## claimed FIFO by pending sends. Pacing is done by SDS itself.
  let encRes = await Encrypt.request(wire)
  let encrypted = encRes.valueOr:
    debug "SDS repair rebroadcast dropped: encryption failed",
      channelId = self.channelId, error = error
    return

  ## Ephemeral: the original message is already store-persisted.
  let envelope = MessageEnvelope(
    contentTopic: self.contentTopic,
    payload: seq[byte](encrypted),
    ephemeral: true,
    meta: LipWireReliableChannelVersion.toBytes(),
  )

  let sendRes =
    try:
      await self.messagingClient.send(envelope)
    except CatchableError as e:
      Result[RequestId, string].err("messaging send raised: " & e.msg)
  if sendRes.isErr():
    debug "SDS repair rebroadcast dropped: dispatch failed",
      channelId = self.channelId, error = sendRes.error

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

  ## Notice that the following "request" is implemented implicitly as a broker call to
  ## the `Decrypt` request broker.
  let decRes = await Decrypt.request(payload)
  let plaintext = decRes.valueOr:
    ### TODO: Emitting of events from another layer is not completly ok to do so.
    mci.MessageErrorEvent.emit(
      self.brokerCtx,
      requestId = RequestId(""),
      messageHash = messageHash,
      error = "decryption failed: " & error,
    )
    return
  let plaintextBytes = seq[byte](plaintext)

  ## SDS returns every payload deliverable now, in causal order — the
  ## message itself plus any parked segments it released. Empty = consumed
  ## by SDS (parked or duplicate). `err` is a real ingress failure here: the
  ## marker/contentTopic filter already ran, so surface it as an error event
  ## rather than dropping it silently.
  let deliverable = (await self.sdsHandler.handleIncoming(plaintextBytes)).valueOr:
    mci.MessageErrorEvent.emit(
      self.brokerCtx,
      requestId = RequestId(""),
      messageHash = messageHash,
      error = "SDS handleIncoming failed: " & error,
    )
    return
  for content in deliverable:
    self.reportReceived(content)

proc new*(
    T: type ReliableChannel,
    messagingClient: MessagingClientInterface,
    channelId: ChannelId,
    contentTopic: ContentTopic,
    senderId: SdsParticipantID,
    segConfig: SegmentationConfig,
    sdsConfig: SdsConfig,
    rateConfig: RateLimitConfig,
    brokerCtx: BrokerContext = globalBrokerContext(),
): T =
  ## Pipeline handlers (segmentation/SDS/rate-limit) are constructed
  ## inside the channel rather than handed in by the caller — they are
  ## implementation details of the channel, not knobs the API consumer
  ## should be wiring up. Encryption is delegated to the `Encrypt`/
  ## `Decrypt` request brokers, so the channel keeps no per-instance
  ## encryption state either.
  ##
  ## `messagingClient` is the egress dispatch — the channel calls
  ## `messagingClient.send` to transmit. Tests pass a fake `MessagingClientInterface`
  ## to drive the send state machine without touching the network.
  let chn = T(
    messagingClient: messagingClient,
    channelId: channelId,
    contentTopic: contentTopic,
    senderId: senderId,
    rng: libp2p_crypto.newRng(),
    segmentation: SegmentationHandler.new(segConfig),
    sdsHandler: SdsHandler.new(sdsConfig, channelId, senderId),
    rateLimit: RateLimitManager.new(rateConfig, channelId, brokerCtx),
    channelReqs: initOrderedTable[RequestId, ChannelReqState](),
    brokerCtx: brokerCtx,
  )

  ## SDS-R repair rebroadcasts go straight to the dispatch tail.
  chn.sdsHandler.onRebroadcast = proc(wire: seq[byte]) {.gcsafe, raises: [].} =
    asyncSpawn chn.dispatchRepair(wire)
  chn.sdsHandler.start()

  ## Each channel owns its own egress + ingress + send-completion
  ## listeners on `chn.brokerCtx`, filtered to traffic addressed to
  ## this channel. Keeping the listeners (and the handler procs they
  ## call) inside the channel lets `onReadyToSend` /
  ## `onMessageReceived` / `onMessageFinal` stay private — the
  ## manager doesn't need to know about them.
  discard ReadyToSendEvent.listen(
    chn.brokerCtx,
    proc(evt: ReadyToSendEvent): Future[void] {.async: (raises: []).} =
      if evt.channelId == chn.channelId:
        await chn.onReadyToSend(evt)
    ,
  )

  discard MessageReceivedEvent.listen(
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
  )

  ## Send-completion events are tagged with the per-segment messaging
  ## `requestId` — globally unique, so we don't need any channel filter
  ## up front. The handler scans this channel's pending entries for a
  ## match and is a no-op when the id belongs to a different channel.
  discard MessageSentEvent.listen(
    chn.brokerCtx,
    proc(evt: MessageSentEvent): Future[void] {.async: (raises: []).} =
      chn.onMessageFinal(evt.requestId, MessagingOutcome.Sent),
  )

  discard mci.MessageErrorEvent.listen(
    chn.brokerCtx,
    proc(evt: mci.MessageErrorEvent): Future[void] {.async: (raises: []).} =
      chn.onMessageFinal(evt.requestId, MessagingOutcome.Failed),
  )

  return chn

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

import std/[options, sets, tables]
import results
import chronos
import bearssl/rand
import stew/byteutils
import libp2p/crypto/crypto as libp2p_crypto

import waku/api/api
import waku/factory/waku as waku_factory
import waku/node/delivery_service/send_service
import waku/waku_core/topics

import ./events
import ./segmentation/segmentation
import ./scalable_data_sync/scalable_data_sync
import ./rate_limit_manager/rate_limit_manager
import ./encryption/encryption

export
  api, waku_factory, events, segmentation, scalable_data_sync, rate_limit_manager,
  encryption

const LipWireReliableChannelVersion* = "RELIABLE-CHANNEL-API/1"
  ## Wire-format spec marker for the Reliable Channel layer, as defined
  ## in the reliable-channel-api LIP (`Wire Format / Spec Marker`).
  ## A `WakuMessage` whose `meta` field does not equal these bytes is
  ## not addressed to this layer and is silently dropped on ingress.
  ## The trailing `/N` is the wire-format version and is bumped only
  ## on breaking on-the-wire changes; implementations pin one version.

type
  SendHandler* = proc(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.
    async: (raises: [CatchableError]), gcsafe
  .}
    ## Egress dispatch boundary. Defaults to `waku.send`; tests inject a
    ## fake that records calls and returns canned `RequestId`s so the
    ## send state machine can be exercised end-to-end without a network.

  MessagePersistence {.pure.} = enum
    Persistent
    Ephemeral

  SegmentSendState {.pure.} = enum
    ## Lifecycle of a single segment as tracked by the channel. The
    ## messaging layer has its own richer `DeliveryState` (retries,
    ## propagated-vs-validated); here we only model what's needed to
    ## decide when a `channelReqId` is fully accounted for.
    AwaitingRateLimit ## Pushed by `send`; not yet released by rate_limit_manager.
    InFlight
      ## Released by rate_limit_manager and handed to delivery_service;
      ## `messagingReqId` is now set.
    Confirmed ## `MessageSentEvent` arrived for `messagingReqId`.
    Failed
      ## `MessageErrorEvent` arrived for `messagingReqId`, or the local
      ## delivery-task construction failed before any id was reachable.

  PendingMessagingRequest = object
    ## One entry per segment (i.e. per messaging-layer request). The
    ## relative order of `AwaitingRateLimit` entries must match the
    ## order in which `rate_limit_manager` re-emits messages, which is
    ## FIFO with `send()`.
    channelReqId*: RequestId
      ## The channel-layer parent id returned to the caller of `send()` in channel layer.
      ## One channel request maps to N pending messaging requests.
    messagingReqId*: Option[RequestId]
      ## Per-segment messaging layer id. `none` until `onReadyToSend` assigns it.
    persistenceReqType: MessagePersistence
    segmentSendState*: SegmentSendState

  ReliableChannel* = ref object
    ## Spec-defined public type. Fields are private so callers cannot
    ## mutate internals and break invariants. Getters are added below
    ## for the few values consumers may need.
    sendHandler: SendHandler
    channelId: ChannelId
    contentTopic: ContentTopic
    senderId: SdsParticipantID
    rng: ref HmacDrbgContext
    segmentation: SegmentationHandler
    sdsHandler: SdsHandler
    rateLimit: RateLimitManager

    requestIds: Table[RequestId, seq[RequestId]]
    pendingMessagingRequests: seq[PendingMessagingRequest]
      ## Entries are kept until the matching segment reaches a final
      ## state (`Confirmed` or `Failed`); a whole channel request is
      ## then pruned in one pass once all its segments are final.
    brokerCtx: BrokerContext

func getChannelId*(self: ReliableChannel): ChannelId {.inline.} =
  self.channelId

func getContentTopic*(self: ReliableChannel): ContentTopic {.inline.} =
  self.contentTopic

func getSenderId*(self: ReliableChannel): SdsParticipantID {.inline.} =
  self.senderId

func isFinal(state: SegmentSendState): bool {.inline.} =
  return state in {SegmentSendState.Confirmed, SegmentSendState.Failed}

proc pruneCompletedChannelReqs(self: ReliableChannel) =
  ## Drop every `pendingMessagingRequests` entry whose `channelReqId`
  ## has all of its segments in a final state. A single failing
  ## segment doesn't trigger a drop on its own — we wait until siblings
  ## are also accounted for, so the channel-level outcome is decided
  ## from a complete picture. For each fully-final `channelReqId`, emit
  ## the channel-level final event before the entries are dropped:
  ## `ChannelMessageSentEvent` if every sibling Confirmed,
  ## `ChannelMessageErrorEvent` if any sibling Failed.
  var hasPending = initHashSet[RequestId]()
  var anyFailed = initHashSet[RequestId]()
  for entry in self.pendingMessagingRequests:
    if not entry.segmentSendState.isFinal():
      hasPending.incl(entry.channelReqId)
    elif entry.segmentSendState == SegmentSendState.Failed:
      anyFailed.incl(entry.channelReqId)

  var emitted = initHashSet[RequestId]()
  for entry in self.pendingMessagingRequests:
    if entry.channelReqId in hasPending or entry.channelReqId in emitted:
      continue
    emitted.incl(entry.channelReqId)
    if entry.channelReqId in anyFailed:
      ChannelMessageErrorEvent.emit(
        self.brokerCtx,
        ChannelMessageErrorEvent(
          channelId: self.channelId,
          requestId: entry.channelReqId,
          error: "one or more segments failed",
        ),
      )
    else:
      ChannelMessageSentEvent.emit(
        self.brokerCtx,
        ChannelMessageSentEvent(
          channelId: self.channelId, requestId: entry.channelReqId
        ),
      )

  self.pendingMessagingRequests.keepItIf(it.channelReqId in hasPending)

proc onMessageSent(self: ReliableChannel, messagingReqId: RequestId) =
  ## Invoked from this channel's `MessageSentEvent` listener. Flips
  ## the matching `InFlight` segment to `Confirmed` and prunes. The
  ## listener routes every event through here; entries that don't
  ## belong to this channel simply don't match and are no-ops.
  self.pendingMessagingRequests.applyItIf(
    it.segmentSendState == SegmentSendState.InFlight and
      it.messagingReqId == some(messagingReqId)
  ):
    it.segmentSendState = SegmentSendState.Confirmed
  self.pruneCompletedChannelReqs()

proc onMessageError(self: ReliableChannel, messagingReqId: RequestId) =
  ## Symmetric to `onMessageSent` but for `MessageErrorEvent`.
  self.pendingMessagingRequests.applyItIf(
    it.segmentSendState == SegmentSendState.InFlight and
      it.messagingReqId == some(messagingReqId)
  ):
    it.segmentSendState = SegmentSendState.Failed
  self.pruneCompletedChannelReqs()

proc onReadyToSend(
    self: ReliableChannel, readyToSendEvent: ReadyToSendEvent
) {.async: (raises: []).} =
  ## Tail of the outgoing pipeline. Invoked from the `ReadyToSendEvent`
  ## listener once `rate_limit_manager` releases a batch of opaque
  ## blobs (already-encoded SDS messages):
  ##
  ##   ... -> rate_limit_manager -> [encryption] -> dispatch
  var idx = 0
  for m in readyToSendEvent.msgs:
    ## The first `AwaitingRateLimit` entry in push order is the one
    ## this `m` belongs to: `send()` adds one entry per segment, and
    ## `rate_limit_manager` re-emits them in the same FIFO order, so
    ## the two sequences advance in lockstep. Earlier entries may
    ## already be `InFlight` / `Confirmed` / `Failed` because they
    ## live on until every sibling of their `channelReqId` is final,
    ## so we walk past those to find the next one that was awaiting for this batch.
    while idx < self.pendingMessagingRequests.len and
        self.pendingMessagingRequests[idx].segmentSendState !=
        SegmentSendState.AwaitingRateLimit
    :
      idx.inc()
    if idx >= self.pendingMessagingRequests.len:
      ## rate_limit_manager emitted more messages than we have pending —
      ## should not happen given `send` pushes one entry per enqueued
      ## SDS payload. Drop silently rather than corrupt state.
      break

    let channelReqId = self.pendingMessagingRequests[idx].channelReqId
    let isEphemeral =
      self.pendingMessagingRequests[idx].persistenceReqType ==
      MessagePersistence.Ephemeral

    ## TODO: revisit which fields of the SDS message must be encrypted.
    ## Encrypting the whole encoded blob forces every receiver to attempt
    ## decryption before it can route, which breaks selective dispatch.
    ## Leave routing metadata (channelId, causal-history references) in
    ## clear and encrypt only the application payload.
    let encRes = await Encrypt.request(m)
    let encrypted = encRes.valueOr:
      MessageErrorEvent.emit(
        self.brokerCtx,
        MessageErrorEvent(
          requestId: channelReqId, messageHash: "", error: "encryption failed: " & error
        ),
      )
      ## Encryption failed *before* we could hand the segment to the
      ## delivery layer — no `messagingReqId` was minted and no
      ## `DeliveryTask` was queued on `sendService`. The delivery
      ## layer will therefore never emit a `MessageSentEvent` /
      ## `MessageErrorEvent` for this segment, so `onMessageError`
      ## won't fire either. Advance the state machine inline so the
      ## parent `channelReqId` can still be pruned once its siblings
      ## are also final.
      self.pendingMessagingRequests[idx].segmentSendState = SegmentSendState.Failed
      idx.inc()
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

    ## `waku.send` is not annotated `(raises: [])`, but this listener is.
    ## Convert any raise to a Result error so the state machine handles
    ## both failure modes (Result.err and exception) through one path.
    let sendRes =
      try:
        await self.sendHandler(envelope)
      except CatchableError as e:
        Result[RequestId, string].err("waku send raised: " & e.msg)

    let messagingReqId = sendRes.valueOr:
      MessageErrorEvent.emit(
        self.brokerCtx,
        MessageErrorEvent(
          requestId: channelReqId, messageHash: "", error: "waku send failed: " & error
        ),
      )
      self.pendingMessagingRequests[idx].segmentSendState = SegmentSendState.Failed
      idx.inc()
      continue

    self.pendingMessagingRequests[idx].messagingReqId = some(messagingReqId)
    self.pendingMessagingRequests[idx].segmentSendState = SegmentSendState.InFlight
    self.requestIds.mgetOrPut(channelReqId, @[]).add(messagingReqId)
    idx.inc()

  self.pruneCompletedChannelReqs()

proc send*(
    self: ReliableChannel, payload: seq[byte], ephemeral: bool = false
): Result[RequestId, string] =
  ## Single application-level send. The first three stages of the
  ## outgoing pipeline are chained explicitly so the flow is visible
  ## at a glance:
  ##
  ##   segmentation -> sds -> rate_limit_manager
  ##
  ## `rate_limit_manager.enqueueToSend` emits a `ReadyToSendEvent` with
  ## the SDS messages cleared for transmission; the channel's listener
  ## then runs the final stage (encryption -> dispatch). The
  ## `persistenceReqType` is carried alongside each segment in
  ## `pendingMessagingRequests` and stamped onto the eventual
  ## `MessageEnvelope`.
  ##
  ## The returned `RequestId` is the channel-level parent of one-or-more
  ## messaging-layer `RequestId`s; the mapping is recorded in
  ## `self.requestIds`.
  if payload.len == 0:
    return err("empty payload")

  let channelReqId = RequestId.new(self.rng)
  self.requestIds[channelReqId] = @[]

  let persistenceReqType =
    if ephemeral: MessagePersistence.Ephemeral else: MessagePersistence.Persistent

  for segmentBytes in self.segmentation.performSegmentation(payload):
    ## Segments arrive already encoded; the segmentation module owns
    ## the wire format so SDS only ever sees opaque bytes.
    let sdsBytes = self.sdsHandler.wrapOutgoing(
      self.channelId, self.senderId, segmentBytes
    ).valueOr:
      return err("SDS wrap failed: " & error)
    self.pendingMessagingRequests.add(
      PendingMessagingRequest(
        channelReqId: channelReqId,
        messagingReqId: none(RequestId),
        persistenceReqType: persistenceReqType,
        segmentSendState: SegmentSendState.AwaitingRateLimit,
      )
    )
    self.rateLimit.enqueueToSend(sdsBytes)

  return ok(channelReqId)

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
    MessageErrorEvent.emit(
      self.brokerCtx,
      MessageErrorEvent(
        requestId: RequestId(""),
        messageHash: messageHash,
        error: "decryption failed: " & error,
      ),
    )
    return
  let plaintextBytes = seq[byte](plaintext)

  let unwrapped = self.sdsHandler.handleIncoming(plaintextBytes)
  if unwrapped.isErr():
    return

  let reassembled = self.segmentation.handleIncomingSegment(unwrapped.get().content)
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

proc new*(
    T: type ReliableChannel,
    waku: Waku,
    channelId: ChannelId,
    contentTopic: ContentTopic,
    senderId: SdsParticipantID,
    segConfig: SegmentationConfig,
    sdsConfig: SdsConfig,
    rateConfig: RateLimitConfig,
    brokerCtx: BrokerContext = globalBrokerContext(),
    sendHandler: SendHandler = nil,
): T =
  ## Pipeline handlers (segmentation/SDS/rate-limit) are constructed
  ## inside the channel rather than handed in by the caller — they are
  ## implementation details of the channel, not knobs the API consumer
  ## should be wiring up. Encryption is delegated to the `Encrypt`/
  ## `Decrypt` request brokers, so the channel keeps no per-instance
  ## encryption state either.
  ##
  ## `sendHandler` defaults to `waku.send`; tests pass a fake to drive
  ## the send state machine without touching the network.
  let resolvedSendHandler =
    if sendHandler.isNil():
      proc(
          envelope: MessageEnvelope
      ): Future[Result[RequestId, string]] {.async: (raises: [CatchableError]), gcsafe.} =
        return await waku.send(envelope)
    else:
      sendHandler

  let chn = T(
    sendHandler: resolvedSendHandler,
    channelId: channelId,
    contentTopic: contentTopic,
    senderId: senderId,
    rng: libp2p_crypto.newRng(),
    segmentation: SegmentationHandler.new(segConfig),
    sdsHandler: SdsHandler.new(sdsConfig, senderId),
    rateLimit: RateLimitManager.new(rateConfig, channelId, brokerCtx),
    requestIds: initTable[RequestId, seq[RequestId]](),
    pendingMessagingRequests: @[],
    brokerCtx: brokerCtx,
  )

  ## Each channel owns its own egress + ingress + send-completion
  ## listeners on `chn.brokerCtx`, filtered to traffic addressed to
  ## this channel. Keeping the listeners (and the handler procs they
  ## call) inside the channel lets `onReadyToSend` /
  ## `onMessageReceived` / `onMessageSent` / `onMessageError` stay
  ## private — the manager doesn't need to know about them.
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
      chn.onMessageSent(evt.requestId),
  )

  discard MessageErrorEvent.listen(
    chn.brokerCtx,
    proc(evt: MessageErrorEvent): Future[void] {.async: (raises: []).} =
      chn.onMessageError(evt.requestId),
  )

  return chn

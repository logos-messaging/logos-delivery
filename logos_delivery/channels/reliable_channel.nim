## Reliable Channel type.
##
## A `ReliableChannel` orchestrates segmentation, SDS (end-to-end
## reliability), optional encryption, and dispatch on top of the
## Messaging API for a single channel.
##
## Outgoing pipeline: Segment -> SDS -> Encrypt -> Dispatch
## Incoming pipeline: Decrypt -> SDS -> Reassemble -> Emit event
##
## Channels are owned by a `ReliableChannelManager`. Lifecycle and send
## operations are addressed by `ChannelId`, so callers only need to keep
## an opaque handle around.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/tables
import results, chronos
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

import ./segmentation/segmentation
import ./scalable_data_sync/scalable_data_sync
import ./encryption/encryption

export types, reliable_channel_manager_api, segmentation, scalable_data_sync, encryption

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
    sdsHandler: SdsHandler

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

proc send*(
    self: ReliableChannel, payload: seq[byte], ephemeral: bool = false
): Future[Result[RequestId, string]] {.async: (raises: []).} =
  ## Single application-level send:
  ##
  ##   segmentation -> sds -> encryption -> dispatch
  ##
  ## The returned `RequestId` is the channel-level parent of one-or-more
  ## messaging-layer `RequestId`s; the mapping is held in
  ## `self.channelReqs` until every segment is final.
  if payload.len == 0:
    return err("empty payload")

  let channelReqId = RequestId.new(self.rng)
  let persistenceReqType =
    if ephemeral: MessagePersistence.Ephemeral else: MessagePersistence.Persistent

  var sdsSegments: seq[seq[byte]]
  for segmentBytes in self.segmentation.performSegmentation(payload):
    ## Segments arrive already encoded; the segmentation module owns
    ## the wire format so SDS only ever sees opaque bytes.
    let sdsBytes = (await self.sdsHandler.wrapOutgoing(segmentBytes)).valueOr:
      return err("SDS wrap failed: " & error)
    sdsSegments.add(sdsBytes)

  self.channelReqs[channelReqId] =
    ChannelReqState.init(persistenceReqType, sdsSegments.len)

  for sdsBytes in sdsSegments:
    ## TODO: revisit which fields of the SDS message must be encrypted.
    ## Encrypting the whole encoded blob forces every receiver to attempt
    ## decryption before it can route, which breaks selective dispatch.
    ## Leave routing metadata (channelId, causal-history references) in
    ## clear and encrypt only the application payload.
    let encrypted = (await Encrypt.request(sdsBytes)).valueOr:
      MessageErrorEvent.emit(
        self.brokerCtx,
        MessageErrorEvent(
          requestId: channelReqId, messageHash: "", error: "encryption failed: " & error
        ),
      )
      self.markSegmentFailed(channelReqId)
      continue

    ## The `meta` field carries the Reliable Channel wire-format spec
    ## marker so the ingress side of any peer can route this WakuMessage
    ## to its Reliable Channel layer.
    let envelope = MessageEnvelope(
      contentTopic: self.contentTopic,
      payload: seq[byte](encrypted),
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
  ## SDS-driven repair rebroadcast. Pacing is done by SDS itself.
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

  (await MessagingSend.request(self.brokerCtx, envelope)).isOkOr:
    debug "SDS repair rebroadcast dropped: dispatch failed",
      channelId = self.channelId, error = error

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

  ## SDS returns every payload deliverable now, in causal order — the
  ## message itself plus any parked segments it released. Empty = consumed
  ## by SDS (parked or duplicate). `err` is a real ingress failure here: the
  ## marker/contentTopic filter already ran, so surface it as an error event
  ## rather than dropping it silently.
  let deliverable = (await self.sdsHandler.handleIncoming(plaintextBytes)).valueOr:
    MessageErrorEvent.emit(
      self.brokerCtx,
      MessageErrorEvent(
        requestId: RequestId(""),
        messageHash: messageHash,
        error: "SDS handleIncoming failed: " & error,
      ),
    )
    return
  for content in deliverable:
    self.reportReceived(content)

proc new*(
    T: type ReliableChannel,
    channelId: ChannelId,
    contentTopic: ContentTopic,
    senderId: SdsParticipantID,
    segConfig: SegmentationConfig,
    sdsConfig: SdsConfig,
    brokerCtx: BrokerContext = globalBrokerContext(),
): T =
  ## Pipeline handlers (segmentation/SDS) are constructed inside the
  ## channel rather than handed in by the caller — they are implementation
  ## details of the channel, not knobs the API consumer should be wiring
  ## up. Encryption is delegated to the `Encrypt`/`Decrypt` request
  ## brokers, so the channel keeps no per-instance encryption state either.
  let chn = T(
    channelId: channelId,
    contentTopic: contentTopic,
    senderId: senderId,
    rng: libp2p_crypto.newRng(),
    segmentation: SegmentationHandler.new(segConfig),
    sdsHandler: SdsHandler.new(sdsConfig, channelId, senderId),
    channelReqs: initTable[RequestId, ChannelReqState](),
    brokerCtx: brokerCtx,
  )

  ## SDS-R repair rebroadcasts go straight to the dispatch tail.
  chn.sdsHandler.onRebroadcast = proc(wire: seq[byte]) {.gcsafe, raises: [].} =
    asyncSpawn chn.dispatchRepair(wire)
  chn.sdsHandler.start()

  ## Each channel owns its own ingress + send-completion listeners on
  ## `chn.brokerCtx`, filtered to traffic addressed to this channel.
  ## Keeping the listeners (and the handler procs they call) inside the
  ## channel lets `onMessageReceived` / `onMessageFinal` stay private —
  ## the manager doesn't need to know about them.
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

  discard MessageErrorEvent.listen(
    chn.brokerCtx,
    proc(evt: MessageErrorEvent): Future[void] {.async: (raises: []).} =
      chn.onMessageFinal(evt.requestId, MessagingOutcome.Failed),
  )

  return chn

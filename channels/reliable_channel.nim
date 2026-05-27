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

import waku/node/delivery_service/delivery_service
import waku/node/delivery_service/send_service
import waku/waku_core/topics

import ./events
import ./segmentation/segmentation
import ./scalable_data_sync/scalable_data_sync
import ./rate_limit_manager/rate_limit_manager
import ./encryption/encryption

export
  delivery_service, send_service, events, segmentation, scalable_data_sync,
  rate_limit_manager, encryption

const LipWireReliableChannelVersion* = "RELIABLE-CHANNEL-API/1"
  ## Wire-format spec marker for the Reliable Channel layer, as defined
  ## in the reliable-channel-api LIP (`Wire Format / Spec Marker`).
  ## A `WakuMessage` whose `meta` field does not equal these bytes is
  ## not addressed to this layer and is silently dropped on ingress.
  ## The trailing `/N` is the wire-format version and is bumped only
  ## on breaking on-the-wire changes; implementations pin one version.

type ReliableChannel* = ref object
  ## Spec-defined public type. Fields are private so callers cannot
  ## mutate internals and break invariants. Getters are added below
  ## for the few values consumers may need.
  deliveryService: DeliveryService
  channelId: ChannelId
  contentTopic: ContentTopic
  senderId: SdsParticipantID
  rng: ref HmacDrbgContext
  segmentation: SegmentationHandler
  sdsHandler: SdsHandler
  rateLimit: RateLimitManager

  requestIds: Table[RequestId, seq[RequestId]]
  pendingRequests: seq[tuple[parent: RequestId, ephemeral: bool]]
  brokerCtx: BrokerContext
    ## Captured here so the channel emits `ChannelMessageReceivedEvent`
    ## on the same broker context the owning manager registered its
    ## listeners on. Without this, an emit via `globalBrokerContext()`
    ## would land on whatever context happens to be thread-local at
    ## emit time, which is not necessarily the manager's.

func getChannelId*(self: ReliableChannel): ChannelId {.inline.} =
  self.channelId

func getContentTopic*(self: ReliableChannel): ContentTopic {.inline.} =
  self.contentTopic

func getSenderId*(self: ReliableChannel): SdsParticipantID {.inline.} =
  self.senderId

proc onReadyToSend(
    self: ReliableChannel, msgs: seq[seq[byte]]
) {.async: (raises: []).} =
  ## Tail of the outgoing pipeline. Invoked from the `ReadyToSendEvent`
  ## listener once `rate_limit_manager` releases a batch of opaque
  ## blobs (already-encoded SDS messages):
  ##
  ##   ... -> rate_limit_manager -> [encryption] -> dispatch
  for m in msgs:
    ## Each `m` was preceded by exactly one push onto `pendingRequests`
    ## in `send`, so this pop is always safe in the current skeleton.
    let pending = self.pendingRequests[0]
    self.pendingRequests.delete(0)

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
          requestId: pending.parent,
          messageHash: "",
          error: "encryption failed: " & error,
        ),
      )
      continue
    let wireBytes = seq[byte](encrypted)

    let envelope = MessageEnvelope(
      contentTopic: self.contentTopic, payload: wireBytes, ephemeral: pending.ephemeral
    )

    let deliveryReqId = RequestId.new(self.rng)
    let deliveryTask = DeliveryTask.new(deliveryReqId, envelope, globalBrokerContext()).valueOr:
      ## TODO: emit waku `MessageErrorEvent` for the parent request id.
      continue

    ## Stamp the Reliable Channel wire-format spec marker so the ingress
    ## side of any peer can route this WakuMessage to its Reliable
    ## Channel layer. Done on the constructed WakuMessage rather than
    ## via the envelope because `MessageEnvelope` does not expose a
    ## `meta` field.
    deliveryTask.msg.meta = LipWireReliableChannelVersion.toBytes()

    asyncSpawn self.deliveryService.sendService.send(deliveryTask)
    self.requestIds.mgetOrPut(pending.parent, @[]).add(deliveryReqId)

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
  ## then runs the final stage (encryption -> dispatch). The `ephemeral`
  ## flag is carried alongside each segment in `pendingRequests` and
  ## stamped onto the eventual `MessageEnvelope`.
  ##
  ## The returned `RequestId` is the parent of one-or-more
  ## delivery-service `RequestId`s; the mapping is recorded in
  ## `self.requestIds`.
  if payload.len == 0:
    return err("empty payload")

  let parentReqId = RequestId.new(self.rng)
  self.requestIds[parentReqId] = @[]

  for segmentBytes in self.segmentation.performSegmentation(payload):
    ## Segments arrive already encoded; the segmentation module owns
    ## the wire format so SDS only ever sees opaque bytes.
    let sdsBytes = self.sdsHandler.wrapOutgoing(
      self.channelId, self.senderId, segmentBytes
    ).valueOr:
      return err("SDS wrap failed: " & error)
    self.pendingRequests.add((parent: parentReqId, ephemeral: ephemeral))
    self.rateLimit.enqueueToSend(sdsBytes)

  return ok(parentReqId)

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
    deliveryService: DeliveryService,
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
  let chn = T(
    deliveryService: deliveryService,
    channelId: channelId,
    contentTopic: contentTopic,
    senderId: senderId,
    rng: libp2p_crypto.newRng(),
    segmentation: SegmentationHandler.new(segConfig),
    sdsHandler: SdsHandler.new(sdsConfig, senderId),
    rateLimit: RateLimitManager.new(rateConfig, channelId, brokerCtx),
    requestIds: initTable[RequestId, seq[RequestId]](),
    pendingRequests: @[],
    brokerCtx: brokerCtx,
  )

  ## Each channel owns its own egress + ingress listeners on
  ## `chn.brokerCtx`, filtered to traffic addressed to this channel.
  ## Keeping the listeners (and the procs they call) inside the
  ## channel lets `onReadyToSend` and `onMessageReceived` stay private
  ## — the manager doesn't need to know about them.
  discard ReadyToSendEvent.listen(
    chn.brokerCtx,
    proc(evt: ReadyToSendEvent): Future[void] {.async: (raises: []).} =
      if evt.channelId == chn.channelId:
        await chn.onReadyToSend(evt.msgs)
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

  return chn

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

import ./events
import ./segmentation/segmentation
import ./scalable_data_sync/scalable_data_sync
import ./rate_limit_manager/rate_limit_manager
import ./encryption/encryption

export
  delivery_service, send_service, events, segmentation, scalable_data_sync,
  rate_limit_manager, encryption

const Lip173Meta* = "LIP173"
  ## Wire-level marker for the Reliable Channel layer. A `WakuMessage`
  ## whose `meta` field does not equal these bytes is not addressed to
  ## this layer and is silently dropped on ingress.

type
  ReliableChannelPayload* = object
    channelId*: ChannelId
    payload*: seq[byte]

  ReliableChannel* = ref object
    ## Spec-defined public type. Fields are private so callers cannot
    ## mutate internals and break invariants (e.g. rewriting the
    ## delivery service mid-flight, or corrupting `requestIds`).
    ## Getters are added below for the few values consumers may need.
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

func getChannelId*(self: ReliableChannel): ChannelId {.inline.} =
  self.channelId

func getContentTopic*(self: ReliableChannel): ContentTopic {.inline.} =
  self.contentTopic

func getSenderId*(self: ReliableChannel): SdsParticipantID {.inline.} =
  self.senderId

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
  return T(
    deliveryService: deliveryService,
    channelId: channelId,
    contentTopic: contentTopic,
    senderId: senderId,
    rng: libp2p_crypto.newRng(),
    segmentation: SegmentationHandler.new(segConfig),
    sdsHandler: SdsHandler.new(sdsConfig),
    rateLimit: RateLimitManager.new(rateConfig, channelId, brokerCtx),
    requestIds: initTable[RequestId, seq[RequestId]](),
    pendingRequests: @[],
  )

proc onReadyToSend*(
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
    let wireBytes =
      if encRes.isOk(): seq[byte](encRes.get()) else: m
    let envelope = MessageEnvelope(
      contentTopic: self.contentTopic,
      payload: wireBytes,
      ephemeral: pending.ephemeral,
    )

    let deliveryReqId = RequestId.new(self.rng)
    let deliveryTask = DeliveryTask.new(deliveryReqId, envelope, globalBrokerContext()).valueOr:
      ## TODO: emit MessageSendErrorEvent for the parent request id.
      continue

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
  let parentReqId = RequestId.new(self.rng)
  self.requestIds[parentReqId] = @[]

  for segment in self.segmentation.performSegmentation(payload):
    ## Encode the segment to bytes here so SDS stays agnostic of the
    ## segmentation wire format.
    let sdsMsg =
      self.sdsHandler.wrapOutgoing(self.channelId, self.senderId, segment.encode())
    self.pendingRequests.add((parent: parentReqId, ephemeral: ephemeral))
    self.rateLimit.enqueueToSend(sdsMsg.encode())

  return ok(parentReqId)

proc onMessageReceived*(
    self: ReliableChannel, wakuMsg: WakuMessage
) {.async: (raises: []).} =
  ## Ingress pipeline made visible:
  ##
  ##   WakuMessage -> ReliableChannelPayload -> decrypt -> sds -> reassemble -> emit
  ##
  ## Invoked from the waku `MessageReceivedEvent` listener after the
  ## inbound `WakuMessage` has been filtered to this channel's
  ## `contentTopic`. Each stage is a minimal stub for now.
  let inWakuMsg: WakuMessage = wakuMsg

  if string.fromBytes(inWakuMsg.meta) != Lip173Meta:
    ## Not a Reliable Channel message — silently drop it.
    return

  ## TODO: decode the `ReliableChannelPayload` wrapper out of `inWakuMsg.payload`
  ## properly (currently treated as the raw SDS bytes).
  let reliablePayload: ReliableChannelPayload =
    ReliableChannelPayload(channelId: self.channelId, payload: inWakuMsg.payload)

  let decRes = await Decrypt.request(reliablePayload.payload)
  let plaintext: seq[byte] =
    if decRes.isOk(): seq[byte](decRes.get()) else: reliablePayload.payload

  let sdsMsg: SdsMessage = SdsMessage.decode(plaintext)
  let processedSds: SdsMessage = self.sdsHandler.handleIncoming(sdsMsg)

  let segment: SegmentMessageProto =
    SegmentMessageProto.decode(processedSds.content)
  let reassembled: Option[ReassemblyResult] =
    self.segmentation.handleIncomingSegment(segment)

  if reassembled.isSome():
    ## TODO: emit the channel-level `MessageReceivedEvent` carrying
    ## `reassembled.get().payload` once the event is wired into the
    ## EventBroker.
    discard reassembled

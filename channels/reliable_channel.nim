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
  ReliablePayload* = object
    channelId*: ChannelId
    payload*: seq[byte]

  ReliableChannel* = ref object
    deliveryService*: DeliveryService
    channelId*: ChannelId
    contentTopic*: ContentTopic
    senderId*: SdsParticipantID
    rng: ref HmacDrbgContext
      ## Private. Each channel owns its own RNG, created locally at
      ## construction. Used to mint `ReliableRequestId`s and
      ## delivery-service `RequestId`s.
    segmentation*: SegmentationHandler
    sdsHandler*: SdsHandler
    rateLimit*: RateLimitManager
    encryption*: EncryptionHook

    requestIds*: Table[ReliableRequestId, seq[RequestId]]
      ## Maps each reliable-channel-level (parent) `ReliableRequestId`
      ## returned to the caller of `send` to the set of delivery-service
      ## `RequestId`s it fanned out into (one per dispatched segment).
    pendingRequests*: seq[tuple[parent: ReliableRequestId, ephemeral: bool]]
      ## FIFO of pending dispatches awaiting release by the rate limiter.
      ## Each entry pairs a parent `ReliableRequestId` with the caller's
      ## `ephemeral` flag so the corresponding `MessageEnvelope` can be
      ## stamped correctly when the rate limiter releases the batch.
      ## One entry is pushed per segment enqueued and popped per segment
      ## handed to the delivery service. Relies on FIFO release from
      ## `rate_limit_manager`, which is the case in this skeleton.

proc new*(
    T: type ReliableChannel,
    deliveryService: DeliveryService,
    channelId: ChannelId,
    contentTopic: ContentTopic,
    senderId: SdsParticipantID,
    segmentation: SegmentationHandler,
    sdsHandler: SdsHandler,
    rateLimit: RateLimitManager,
    encryption: EncryptionHook,
): T =
  return T(
    deliveryService: deliveryService,
    channelId: channelId,
    contentTopic: contentTopic,
    senderId: senderId,
    rng: libp2p_crypto.newRng(),
    segmentation: segmentation,
    sdsHandler: sdsHandler,
    rateLimit: rateLimit,
    encryption: encryption,
    requestIds: initTable[ReliableRequestId, seq[RequestId]](),
    pendingRequests: @[],
  )

proc onReadyToSend*(self: ReliableChannel, msgs: seq[SdsMessage]) =
  ## Tail of the outgoing pipeline. Invoked from the `ReadyToSendEvent`
  ## listener once `rate_limit_manager` releases a batch of SDS messages:
  ##
  ##   ... -> rate_limit_manager -> [encryption] -> dispatch
  for m in msgs:
    ## Each `m` was preceded by exactly one push onto `pendingRequests`
    ## in `send`, so this pop is always safe in the current skeleton.
    let pending = self.pendingRequests[0]
    self.pendingRequests.delete(0)

    let wireBytes = self.encryption.encrypt(m.encode())
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
): Result[ReliableRequestId, string] =
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
  ## The returned `ReliableRequestId` is the parent of one-or-more
  ## delivery-service `RequestId`s; the mapping is recorded in
  ## `self.requestIds`.
  let parentReqId = ReliableRequestId.new(self.rng)
  self.requestIds[parentReqId] = @[]

  for segment in self.segmentation.performSegmentation(payload):
    let sdsMsg = self.sdsHandler.wrapOutgoing(self.channelId, self.senderId, segment)
    self.pendingRequests.add((parent: parentReqId, ephemeral: ephemeral))
    self.rateLimit.enqueueToSend(sdsMsg)

  return ok(parentReqId)

proc onMessageReceived*(self: ReliableChannel, wakuMsg: WakuMessage) =
  ## Ingress pipeline made visible:
  ##
  ##   WakuMessage -> ReliablePayload -> decrypt -> sds -> reassemble -> emit
  ##
  ## Invoked from the waku `MessageReceivedEvent` listener after the
  ## inbound `WakuMessage` has been filtered to this channel's
  ## `contentTopic`. Each stage is a minimal stub for now.
  let inWakuMsg: WakuMessage = wakuMsg

  if string.fromBytes(inWakuMsg.meta) != Lip173Meta:
    ## Not a Reliable Channel message — silently drop it.
    return

  ## TODO: decode the `ReliablePayload` wrapper out of `inWakuMsg.payload`
  ## properly (currently treated as the raw SDS bytes).
  let reliablePayload: ReliablePayload =
    ReliablePayload(channelId: self.channelId, payload: inWakuMsg.payload)

  let plaintext: seq[byte] = self.encryption.decrypt(reliablePayload.payload)

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

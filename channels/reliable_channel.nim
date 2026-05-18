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

import std/tables
import results
import chronos
import bearssl/rand
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
    sds*: SdsHandler
    rateLimit*: RateLimitManager
    encryption*: EncryptionHook

    requestIds*: Table[ReliableRequestId, seq[RequestId]]
      ## Maps each reliable-channel-level (parent) `ReliableRequestId`
      ## returned to the caller of `send` to the set of delivery-service
      ## `RequestId`s it fanned out into (one per dispatched segment).
    pendingRequests*: seq[ReliableRequestId]
      ## FIFO of parent `ReliableRequestId`s awaiting release by the rate
      ## limiter. One entry is pushed per segment enqueued and popped per
      ## segment handed to the delivery service. Relies on FIFO release
      ## from `rate_limit_manager`, which is the case in this skeleton.

proc new*(
    T: type ReliableChannel,
    deliveryService: DeliveryService,
    channelId: ChannelId,
    contentTopic: ContentTopic,
    senderId: SdsParticipantID,
    segmentation: SegmentationHandler,
    sds: SdsHandler,
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
    sds: sds,
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
    let wireBytes = self.encryption.send(m.encode())
    let envelope = MessageEnvelope(
      contentTopic: self.contentTopic, payload: wireBytes, ephemeral: false
    )

    let deliveryReqId = RequestId.new(self.rng)
    let deliveryTask = DeliveryTask.new(deliveryReqId, envelope, globalBrokerContext()).valueOr:
      ## TODO: emit MessageSendErrorEvent for the parent request id.
      if self.pendingRequests.len > 0:
        self.pendingRequests.delete(0)
      continue

    asyncSpawn self.deliveryService.sendService.send(deliveryTask)

    if self.pendingRequests.len == 0:
      ## TODO: log/track unparented dispatch — shouldn't happen in skeleton.
      continue
    let parent = self.pendingRequests[0]
    self.pendingRequests.delete(0)
    self.requestIds.mgetOrPut(parent, @[]).add(deliveryReqId)

proc send*(
    self: ReliableChannel, payload: seq[byte]
): Result[ReliableRequestId, string] =
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
  ## The returned `ReliableRequestId` is the parent of one-or-more
  ## delivery-service `RequestId`s; the mapping is recorded in
  ## `self.requestIds`.
  let parentReqId = ReliableRequestId.new(self.rng)
  self.requestIds[parentReqId] = @[]

  for segment in self.segmentation.performSegmentation(payload):
    let sdsMsg = self.sds.wrapOutgoing(self.channelId, self.senderId, segment)
    self.pendingRequests.add(parentReqId)
    self.rateLimit.enqueueToSend(sdsMsg)

  return ok(parentReqId)

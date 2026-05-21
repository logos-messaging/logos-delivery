## Reliable Channel API entry point.
##
## Owns the set of `ReliableChannel` instances and exposes lifecycle and
## send/receive operations addressed by `ChannelId`.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/[options, tables]
import results

import waku/events/message_events as waku_message_events

import ./reliable_channel
import ./encryption/encryption
import ./encryption/noop_encryption

export reliable_channel

type ReliableChannelManager* = ref object
  channels: Table[ChannelId, ReliableChannel]
  deliveryService*: DeliveryService
    ## The single send/receive surface all owned channels dispatch through.

proc new*(
    T: type ReliableChannelManager, deliveryService: DeliveryService
): T =
  return T(
    channels: initTable[ChannelId, ReliableChannel](),
    deliveryService: deliveryService,
  )

proc createReliableChannel*(
    manager: ReliableChannelManager,
    channelId: ChannelId,
    contentTopic: ContentTopic,
    senderId: SdsParticipantID,
    encryption: Option[EncryptionHook] = none(EncryptionHook),
): Result[ChannelId, string] =
  ## Spec entry point. The `DeliveryService` and `rng` the channel needs
  ## are sourced from the owning `ReliableChannelManager` rather than
  ## passed per call.
  ##
  ## Segmentation, SDS and rate-limit configs will eventually be read
  ## from the node's `NodeConfig`. Defaults for now.
  if manager.channels.hasKey(channelId):
    return err("channel already exists: " & channelId)

  let enc =
    if encryption.isSome and encryption.get.isConfigured():
      encryption.get
    else:
      newNoopEncryptionHook()
  let segConfig = SegmentationConfig(
    segmentSizeBytes: DefaultSegmentSizeBytes,
    enableReedSolomon: false,
    persistence: nil,
  )
  let sdsConfig = SdsConfig(
    acknowledgementTimeoutMs: DefaultAcknowledgementTimeoutMs,
    maxRetransmissions: DefaultMaxRetransmissions,
    causalHistorySize: DefaultCausalHistorySize,
    persistence: nil,
  )
  let rateConfig = RateLimitConfig(
    epochPeriodSec: DefaultEpochPeriodSec, messagesPerEpoch: DefaultMessagesPerEpoch
  )

  let chn = ReliableChannel.new(
    deliveryService = manager.deliveryService,
    channelId = channelId,
    contentTopic = contentTopic,
    senderId = senderId,
    segmentation = SegmentationHandler.new(segConfig),
    sdsHandler = SdsHandler.new(sdsConfig),
    rateLimit = RateLimitManager.new(rateConfig, channelId),
    encryption = enc,
  )
  ## Continue the outgoing pipeline once the rate limiter releases a
  ## batch of SDS messages: rate_limit_manager -> encryption -> dispatch.
  ## The listener filters on `channelId` since all reliable channels
  ## share the global broker context.
  discard ReadyToSendEvent.listen(
    globalBrokerContext(),
    proc(evt: ReadyToSendEvent): Future[void] {.async: (raises: []).} =
      if evt.channelId == chn.channelId:
        chn.onReadyToSend(evt.msgs)
    ,
  )

  ## Run the incoming pipeline whenever waku reports a received
  ## message on this channel's content topic:
  ##   decryption -> sds -> segmentation reassembly -> emit.
  discard waku_message_events.MessageReceivedEvent.listen(
    globalBrokerContext(),
    proc(
        evt: waku_message_events.MessageReceivedEvent
    ): Future[void] {.async: (raises: []).} =
      if evt.message.contentTopic == chn.contentTopic:
        chn.onMessageReceived(evt.message)
    ,
  )

  manager.channels[channelId] = chn
  return ok(channelId)

proc closeChannel*(
    manager: ReliableChannelManager, channelId: ChannelId
): Result[void, string] =
  ## Flush state, persist outstanding SDS buffers, release resources.
  if not manager.channels.hasKey(channelId):
    return err("unknown channel: " & channelId)
  manager.channels.del(channelId)
  return ok()

proc send*(
    manager: ReliableChannelManager,
    channelId: ChannelId,
    appPayload: seq[byte],
    ephemeral: bool = false,
): Result[RequestId, string] =
  ## Spec-level entry point. Looks the channel up by id and delegates
  ## to `ReliableChannel.send`, which exposes the visible pipeline
  ## segmentation -> sds -> rate_limit_manager -> encryption.
  let chn = manager.channels.getOrDefault(channelId)
  if chn.isNil():
    return err("unknown channel: " & channelId)
  return chn.send(appPayload, ephemeral)

proc processInboundMessage*(
    manager: ReliableChannelManager, channelId: ChannelId, inMsg: MessageEnvelope
) =
  ## Entry point for messages delivered by the Messaging API.
  ##
  ## TODO:
  ## - validate LIP173 meta on the WakuMessage
  ## - decode `ReliablePayload`
  ## - decrypt via chn.encryption
  ## - feed into chn.sdsHandler.handleIncoming
  ## - feed resulting segment into chn.segmentation.handleIncomingSegment
  ## - on reassembly completion, emit MessageReceivedEvent
  discard

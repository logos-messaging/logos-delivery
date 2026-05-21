## Reliable Channel API entry point.
##
## Owns the set of `ReliableChannel` instances and exposes lifecycle and
## send/receive operations addressed by `ChannelId`.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/tables
import results

import waku/events/message_events as waku_message_events

import ./reliable_channel
import ./encryption/noop_encryption

export reliable_channel

type ReliableChannelManager* = ref object
  channels: Table[ChannelId, ReliableChannel]
  deliveryService*: DeliveryService
    ## The single send/receive surface all owned channels dispatch through.
  brokerCtx: BrokerContext

proc new*(
    T: type ReliableChannelManager,
    deliveryService: DeliveryService,
    brokerCtx: BrokerContext = globalBrokerContext(),
): T =
  return T(
    channels: initTable[ChannelId, ReliableChannel](),
    deliveryService: deliveryService,
    brokerCtx: brokerCtx,
  )

proc createReliableChannel*(
    manager: ReliableChannelManager,
    channelId: ChannelId,
    contentTopic: ContentTopic,
    senderId: SdsParticipantID,
): Result[ChannelId, string] =
  ## Spec entry point. The `DeliveryService` and `rng` the channel needs
  ## are sourced from the owning `ReliableChannelManager` rather than
  ## passed per call. Encryption is wired up through the `Encrypt`/
  ## `Decrypt` request brokers — the application installs its own
  ## providers (or `setNoopEncryption()`) before traffic flows.
  ##
  ## Segmentation, SDS and rate-limit configs will eventually be read
  ## from the node's `NodeConfig`. Defaults for now.
  if manager.channels.hasKey(channelId):
    return err("channel already exists: " & channelId)

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
    segConfig = segConfig,
    sdsConfig = sdsConfig,
    rateConfig = rateConfig,
    brokerCtx = manager.brokerCtx,
  )
  ## Continue the outgoing pipeline once the rate limiter releases a
  ## batch of SDS messages: rate_limit_manager -> encryption -> dispatch.
  ## The listener filters on `channelId` since all reliable channels
  ## owned by the same manager share the same broker context.
  discard ReadyToSendEvent.listen(
    manager.brokerCtx,
    proc(evt: ReadyToSendEvent): Future[void] {.async: (raises: []).} =
      if evt.channelId == chn.getChannelId:
        await chn.onReadyToSend(evt.msgs)
    ,
  )

  ## Run the incoming pipeline whenever waku reports a received
  ## message on this channel's content topic:
  ##   decryption -> sds -> segmentation reassembly -> emit.
  discard waku_message_events.MessageReceivedEvent.listen(
    manager.brokerCtx,
    proc(
        evt: waku_message_events.MessageReceivedEvent
    ): Future[void] {.async: (raises: []).} =
      if evt.message.contentTopic == chn.getContentTopic:
        await chn.onMessageReceived(evt.message)
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

## Inbound messages are not handed to the manager by direct call: the
## listener registered in `createReliableChannel` for
## `waku_message_events.MessageReceivedEvent` invokes
## `chn.onMessageReceived` itself. This keeps the lower layer
## (MessagingAPI/Waku) unaware of the existence of ReliableChannel.

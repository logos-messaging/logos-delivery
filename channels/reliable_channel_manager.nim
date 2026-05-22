## Reliable Channel API entry point.
##
## Owns the set of `ReliableChannel` instances and exposes lifecycle and
## send/receive operations addressed by `ChannelId`.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/tables
import results
import chronos
import stew/byteutils

import waku/api/api
import waku/api/api_conf
import waku/events/message_events as waku_message_events
import waku/factory/waku as waku_factory
import waku/waku_core/topics

import ./reliable_channel
import ./encryption/noop_encryption

export reliable_channel

type ReliableChannelManager* = ref object
  channels: Table[ChannelId, ReliableChannel]
  deliveryService: DeliveryService
    ## Owned by the manager. The ownership chain is
    ##   ReliableChannelManager -> DeliveryService -> Waku -> WakuNode.
    ## Hidden so callers can't substitute their own and bypass the
    ## manager's pipeline.
  brokerCtx: BrokerContext

proc new*(
    T: type ReliableChannelManager,
    conf: WakuNodeConf,
    brokerCtx: BrokerContext = globalBrokerContext(),
): Future[Result[T, string]] {.async.} =
  ## TODO !! The proper ownership chain is:
  ## ReliableChannelManager -> DeliveryService (MessagingClient) -> Waku (Kernel/Protocols) -> WakuNode,
  ## and this will be implemented in the future. For now, `createNode`
  ## is called here to get a DeliveryService instance, and the WakuNode is immediately discarded.
  ## This is a temporary workaround to get the API

  let waku = ?(await createNode(conf))

  let manager = T(
    channels: initTable[ChannelId, ReliableChannel](),
    deliveryService: waku.deliveryService,
    brokerCtx: brokerCtx,
  )

  ## Single ingress listener for the whole manager. The DeliveryService
  ## recv path emits `MessageReceivedEvent` for every WakuMessage it
  ## sees; the manager:
  ##   1. drops anything whose `meta` is not LIP173 (foreign traffic);
  ##   2. decodes the `ReliableChannelPayload` wrapper once;
  ##   3. dispatches the typed payload to every channel whose
  ##      `contentTopic` matches (multiple channels may subscribe to
  ##      the same topic).
  ## Doing the wrapper decode here keeps the channels free of
  ## wire-format concerns, and keeps the DeliveryService unaware of
  ## ReliableChannel altogether.
  discard waku_message_events.MessageReceivedEvent.listen(
    manager.brokerCtx,
    proc(
        evt: waku_message_events.MessageReceivedEvent
    ): Future[void] {.async: (raises: []).} =
      if string.fromBytes(evt.message.meta) != Lip173Meta:
        return

      for chn in manager.channels.values:
        if chn.getContentTopic() == evt.message.contentTopic:
          await chn.onMessageReceived(evt.message.payload)
    ,
  )

  ## Single egress listener: rate_limit_manager emits a
  ## `ReadyToSendEvent` tagged with `channelId`, so the dispatch here
  ## is a direct table lookup.
  discard ReadyToSendEvent.listen(
    manager.brokerCtx,
    proc(evt: ReadyToSendEvent): Future[void] {.async: (raises: []).} =
      let chn = manager.channels.getOrDefault(evt.channelId)
      if not chn.isNil():
        await chn.onReadyToSend(evt.msgs)
    ,
  )

  return ok(manager)

proc start*(self: ReliableChannelManager): Result[void, string] =
  ## Bring the owned DeliveryService up. Separated from `new` so callers
  ## can register encryption providers / create channels before traffic
  ## starts flowing.
  self.deliveryService.startDeliveryService()

proc stop*(self: ReliableChannelManager) {.async.} =
  if not self.deliveryService.isNil():
    await self.deliveryService.stopDeliveryService()

proc createReliableChannel*(
    self: ReliableChannelManager,
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
  if self.channels.hasKey(channelId):
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
    deliveryService = self.deliveryService,
    channelId = channelId,
    contentTopic = contentTopic,
    senderId = senderId,
    segConfig = segConfig,
    sdsConfig = sdsConfig,
    rateConfig = rateConfig,
    brokerCtx = self.brokerCtx,
  )

  self.channels[channelId] = chn
  return ok(channelId)

proc closeChannel*(
    self: ReliableChannelManager, channelId: ChannelId
): Result[void, string] =
  ## Flush state, persist outstanding SDS buffers, release resources.
  if not self.channels.hasKey(channelId):
    return err("unknown channel: " & channelId)
  self.channels.del(channelId)
  return ok()

proc send*(
    self: ReliableChannelManager,
    channelId: ChannelId,
    appPayload: seq[byte],
    ephemeral: bool = false,
): Result[RequestId, string] =
  ## Spec-level entry point. Looks the channel up by id and delegates
  ## to `ReliableChannel.send`, which exposes the visible pipeline
  ## segmentation -> sds -> rate_limit_manager -> encryption.
  let chn = self.channels.getOrDefault(channelId)
  if chn.isNil():
    return err("unknown channel: " & channelId)
  return chn.send(appPayload, ephemeral)

## Inbound messages are not handed to the manager by direct call: the
## single `MessageReceivedEvent` listener registered in `new` looks the
## owning channel up by `contentTopic` and invokes its
## `onMessageReceived`. This keeps the lower layer (MessagingAPI/Waku)
## unaware of the existence of ReliableChannel.

## Reliable Channel API entry point.
##
## Owns the set of `ReliableChannel` instances and exposes lifecycle and
## send/receive operations addressed by `ChannelId`.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/[options, tables]
import results
import chronos
import chronicles
import stew/byteutils

import brokers/broker_context

import logos_delivery/waku/events/message_events as waku_message_events
import logos_delivery/messaging/messaging_client
import logos_delivery/api/types
import logos_delivery/waku/waku_core/topics
import logos_delivery/waku/persistency/sds_persistency

import ./reliable_channel
import ./encryption/noop_encryption

export reliable_channel

const SdsJobId = "sds"
  ## One persistency job shared by every channel's SDS state; rows are
  ## keyed by channelId.

type
  ReliableChannelManagerConf* = object
    ## Per-layer config object for the reliable
    ## channel API. Placeholder for now (segmentation / SDS / rate-limit defaults
    ## will move here in a follow-up PR); kept so each layer owns its own config.

  ReliableChannelManager* = ref object
    channels: Table[ChannelId, ReliableChannel]
    messagingClient: MessagingClient ## The channel layer chains onto messaging.
    sendHandler: SendHandler
      ## Default egress dispatch for channels created through this manager.
      ## Built in `new` as a closure over `MessagingClient.send` so the channel
      ## layer itself stays callable-only.
    brokerCtx: BrokerContext

proc new*(
    T: type ReliableChannelManager,
    conf: ReliableChannelManagerConf,
    messagingClient: MessagingClient,
    brokerCtx: BrokerContext = globalBrokerContext(),
): Result[T, string] =
  ## The reliable channel layer chains onto the messaging layer: its default
  ## egress is `MessagingClient.send`, wrapped here so callers never wire the
  ## handler themselves.
  if messagingClient.isNil():
    return err("messaging client is required")

  let defaultSendHandler: SendHandler = proc(
      envelope: MessageEnvelope
  ): Future[Result[RequestId, string]] {.async: (raises: [CatchableError]), gcsafe.} =
    return await messagingClient.send(envelope)

  return ok(
    T(
      channels: initTable[ChannelId, ReliableChannel](),
      messagingClient: messagingClient,
      sendHandler: defaultSendHandler,
      brokerCtx: brokerCtx,
    )
  )

proc start*(self: ReliableChannelManager): Result[void, string] =
  ## Placeholder: per-channel listeners are installed in `ReliableChannel.new`,
  ## so the manager has nothing to start at this layer. Kept for symmetry
  ## with the `Waku` mount/start lifecycle and as a hook for future state.
  discard
  ok()

proc stop*(self: ReliableChannelManager) {.async.} =
  ## Stops every channel's SDS background loops. Persisted state survives.
  for chn in self.channels.values:
    await chn.stop()
  self.channels.clear()

proc sdsPersistence(): Option[Persistence] =
  ## SDS backend from the Persistency singleton; memory-only fallback when
  ## it is unavailable (e.g. unit tests).
  let p = Persistency.instance().valueOr:
    info "SDS persistence disabled, running memory-only", reason = $error
    return none(Persistence)
  let job = p.openJob(SdsJobId).valueOr:
    warn "SDS persistence disabled, could not open persistency job",
      jobId = SdsJobId, reason = $error
    return none(Persistence)
  return some(newSdsPersistence(job))

proc createReliableChannel*(
    self: ReliableChannelManager,
    channelId: ChannelId,
    contentTopic: ContentTopic,
    senderId: SdsParticipantID,
    sendHandler: SendHandler = nil,
): Result[ChannelId, string] =
  ## Spec entry point. The `sendHandler` and `rng` the channel needs are
  ## sourced from the owning `ReliableChannelManager` rather than passed
  ## per call. Encryption is wired up through the `Encrypt`/`Decrypt`
  ## request brokers — the application installs its own providers
  ## (or `setNoopEncryption()`) before traffic flows.
  ##
  ## Segmentation, SDS and rate-limit configs will eventually be read
  ## from the node's `NodeConfig`. Defaults for now.
  ##
  ## `sendHandler` defaults to the manager's default (constructed at mount
  ## from `MessagingClient.send`); tests pass a fake to bypass the network.
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
    persistence: sdsPersistence(),
  )
  let rateConfig = RateLimitConfig(
    epochPeriodSec: DefaultEpochPeriodSec, messagesPerEpoch: DefaultMessagesPerEpoch
  )

  let effectiveSendHandler = if sendHandler.isNil(): self.sendHandler else: sendHandler

  let chn = ReliableChannel.new(
    sendHandler = effectiveSendHandler,
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
): Future[Result[void, string]] {.async: (raises: []).} =
  ## Stops the channel's SDS loops and releases the channel. Persisted SDS
  ## state survives, so re-creating the channel restores it.
  let chn = self.channels.getOrDefault(channelId)
  if chn.isNil():
    return err("unknown channel: " & channelId)
  self.channels.del(channelId)
  await chn.stop()
  return ok()

proc send*(
    self: ReliableChannelManager,
    channelId: ChannelId,
    appPayload: seq[byte],
    ephemeral: bool = false,
): Future[Result[RequestId, string]] {.async: (raises: []).} =
  ## Spec-level entry point. Looks the channel up by id and delegates
  ## to `ReliableChannel.send`, which exposes the visible pipeline
  ## segmentation -> sds -> rate_limit_manager -> encryption.
  let chn = self.channels.getOrDefault(channelId)
  if chn.isNil():
    return err("unknown channel: " & channelId)
  return await chn.send(appPayload, ephemeral)

## Inbound messages are not handed to the manager by direct call. Each
## `ReliableChannel` installs its own `MessageReceivedEvent` listener
## in `ReliableChannel.new`, filters by spec marker and `contentTopic`,
## and routes to its private `onMessageReceived`. This keeps the lower
## layer (MessagingClient/Waku) unaware of the existence of ReliableChannel
## and keeps the manager out of per-channel event dispatch.

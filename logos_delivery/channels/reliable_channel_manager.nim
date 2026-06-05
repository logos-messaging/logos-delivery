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

import brokers/broker_context

import waku/events/message_events as waku_message_events
import messaging/messaging_client
import waku/waku_core/topics

import ./reliable_channel
import ./encryption/noop_encryption

export reliable_channel

type ReliableChannelManager* = ref object
  channels: Table[ChannelId, ReliableChannel]
  messagingClient: MessagingClient
    ## Borrowed from the owning `Waku`.
  sendHandler: SendHandler
    ## Default egress dispatch for channels created through this manager.
    ## Constructed at mount time as a closure over `MessagingClient.send`
    ## so the channel layer itself stays callable-only.
  brokerCtx: BrokerContext

proc new*(
    T: type ReliableChannelManager,
    messagingClient: MessagingClient,
    sendHandler: SendHandler,
    brokerCtx: BrokerContext = globalBrokerContext(),
): Result[T, string] =
  if messagingClient.isNil():
    return err("messaging client is required")
  if sendHandler.isNil():
    return err("sendHandler is required")
  return ok(
    T(
      channels: initTable[ChannelId, ReliableChannel](),
      messagingClient: messagingClient,
      sendHandler: sendHandler,
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
  ## Placeholder mirror of `start`.
  discard

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
    persistence: nil,
  )
  let rateConfig = RateLimitConfig(
    epochPeriodSec: DefaultEpochPeriodSec, messagesPerEpoch: DefaultMessagesPerEpoch
  )

  let effectiveSendHandler =
    if sendHandler.isNil():
      self.sendHandler
    else:
      sendHandler

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

## Inbound messages are not handed to the manager by direct call. Each
## `ReliableChannel` installs its own `MessageReceivedEvent` listener
## in `ReliableChannel.new`, filters by spec marker and `contentTopic`,
## and routes to its private `onMessageReceived`. This keeps the lower
## layer (MessagingClient/Waku) unaware of the existence of ReliableChannel
## and keeps the manager out of per-channel event dispatch.

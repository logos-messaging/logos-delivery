## Reliable Channel layer API — channel lifecycle
## (createReliableChannel / closeChannel).
import std/tables
import results, chronos, chronicles

import logos_delivery/api/types
import logos_delivery/api/messaging_client_api
import logos_delivery/channels/reliable_channel_manager
import logos_delivery/channels/reliable_channel
import logos_delivery/waku/persistency/sds_persistency

# ReliableChannel, config and wire-version markers.
export reliable_channel

const SdsJobId = "sds"
  ## One persistency job shared by every channel's SDS state; rows are
  ## keyed by channelId.

proc sdsPersistence(brokerCtx: BrokerContext): Opt[Persistence] =
  ## SDS backend from the node's Persistency instance, resolved via the
  ## context-scoped GetPersistency broker; memory-only fallback when no
  ## provider is installed (e.g. unit tests).
  let p = GetPersistency.request(brokerCtx).valueOr:
    debug "SDS persistence disabled, running memory-only", reason = $error
    return Opt.none(Persistence)
  let job = p.openJob(SdsJobId).valueOr:
    warn "SDS persistence disabled, could not open persistency job",
      jobId = SdsJobId, reason = $error
    return Opt.none(Persistence)
  return Opt.some(newSdsPersistence(job))

proc createReliableChannel*(
    self: ReliableChannelManager,
    channelId: ChannelId,
    contentTopic: ContentTopic,
    senderId: SdsParticipantID,
): Result[ChannelId, string] =
  ## Encryption and egress providers must be installed (or `setNoopEncryption()`)
  ## before traffic flows on the channel.
  ## Subscribes to `contentTopic`; without a `MessagingSubscribe` provider the
  ## subscription is deferred to `ReliableChannelManager.start`.
  if self.channels.hasKey(channelId):
    return err("channel already exists: " & channelId)

  # Subscribe before constructing so a failure leaks no listeners.
  if MessagingSubscribe.isProvided(self.brokerCtx):
    MessagingSubscribe.request(self.brokerCtx, contentTopic).isOkOr:
      return err("failed to subscribe to content topic: " & error)
  else:
    debug "No MessagingSubscribe provider, deferring content topic subscription",
      channelId = channelId, contentTopic = contentTopic

  let cc = self.conf
  let segConfig = SegmentationConfig(
    segmentSizeBytes: cc.segmentationSegmentSizeBytes.get(DefaultSegmentSizeBytes),
    enableReedSolomon: cc.segmentationEnableReedSolomon.get(false),
    persistence: nil,
  )
  let sdsConfig = SdsConfig(
    acknowledgementTimeoutMs:
      cc.sdsAcknowledgementTimeoutMs.get(DefaultAcknowledgementTimeoutMs),
    maxRetransmissions: cc.sdsMaxRetransmissions.get(DefaultMaxRetransmissions),
    causalHistorySize: cc.sdsCausalHistorySize.get(DefaultCausalHistorySize),
    persistence: sdsPersistence(self.brokerCtx),
  )

  let chn = ReliableChannel.new(
    channelId = channelId,
    contentTopic = contentTopic,
    senderId = senderId,
    segConfig = segConfig,
    sdsConfig = sdsConfig,
    brokerCtx = self.brokerCtx,
  )

  self.channels[channelId] = chn
  return ok(channelId)

proc channelExists*(self: ReliableChannelManager, channelId: ChannelId): bool =
  ## True while the channel is held by the manager, i.e. between a successful
  ## `createReliableChannel` and `closeChannel`. Persisted SDS state for a
  ## closed channel does not count as existing.
  return self.channels.hasKey(channelId)

proc closeChannel*(
    self: ReliableChannelManager, channelId: ChannelId
): Future[Result[void, string]] {.async: (raises: []).} =
  ## Stops the channel's SDS loops and releases the channel. Persisted SDS
  ## state survives, so re-creating the channel restores it. Unsubscribes the
  ## content topic unless another open channel still uses it.
  let chn = self.channels.getOrDefault(channelId)
  if chn.isNil():
    return err("unknown channel: " & channelId)
  self.channels.del(channelId)
  await chn.stop()

  # After `stop` so in-flight sends cannot auto-resubscribe; best-effort.
  let contentTopic = chn.getContentTopic()
  var topicStillUsed = false
  for other in self.channels.values:
    if other.getContentTopic() == contentTopic:
      topicStillUsed = true
      break
  if not topicStillUsed and MessagingUnsubscribe.isProvided(self.brokerCtx):
    MessagingUnsubscribe.request(self.brokerCtx, contentTopic).isOkOr:
      debug "Failed to unsubscribe closed channel's content topic",
        channelId = channelId, contentTopic = contentTopic, error = error

  return ok()

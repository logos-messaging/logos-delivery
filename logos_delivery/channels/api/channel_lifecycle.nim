## Reliable Channel layer API — channel lifecycle
## (createReliableChannel / closeChannel).
import std/[options, tables]
import results, chronos, chronicles

import logos_delivery/api/types
import logos_delivery/channels/reliable_channel_manager
import logos_delivery/channels/reliable_channel
import logos_delivery/waku/persistency/sds_persistency

# ReliableChannel, SendHandler, config and wire-version markers.
export reliable_channel

const SdsJobId = "sds"
  ## One persistency job shared by every channel's SDS state; rows are
  ## keyed by channelId.

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
): Result[ChannelId, string] =
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

  let chn = ReliableChannel.new(
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

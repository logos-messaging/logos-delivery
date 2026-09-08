{.push raises: [].}

import chronicles, chronos, stew/byteutils
import brokers/broker_context
import segmentation

import logos_delivery/api/conf/channels_conf
import logos_delivery/api/events/reliable_channel_manager_events
import ./segmentation_metrics
import ./segmentation_persistence

export segmentation, segmentation_persistence

logScope:
  topics = "channel segmentation"

const DefaultSegmentCleanupIntervalSeconds* = 30
  ## Well below the package's 300 s default reconstruction timeout, so an
  ## expired set is reclaimed promptly without the sweep being a hot loop.

type ChannelSegmentationConfig* = object
  ## The package's `SegmentationConfig` plus the two settings it has no place
  ## for: the sweep cadence, and the not-yet-wired persistence backend.
  segmentation*: SegmentationConfig
  cleanupInterval*: Duration
  persistence*: SegmentationPersistence

func init*(T: type ChannelSegmentationConfig, conf: ReliableChannelManagerConf): T =
  ## Every unset field falls back to the package's own default, so those
  ## constants stay the single source of truth.
  let reconstructionTimeoutSeconds = conf.segmentationReconstructionTimeoutSeconds.get(
    DefaultReconstructionTimeoutSeconds
  )

  ## An unset sweep interval follows a shortened timeout down: the default
  ## must never be what makes a lower `reconstructionTimeout` invalid.
  let cleanupIntervalSeconds = conf.segmentationCleanupIntervalSeconds.get(
    min(DefaultSegmentCleanupIntervalSeconds, reconstructionTimeoutSeconds)
  )

  return T(
    segmentation: SegmentationConfig.init(
      segmentSizeBytes = conf.segmentationSegmentSizeBytes.get(DefaultSegmentSizeBytes),
      parityRate = conf.segmentationParityRate.get(DefaultParityRate),
      reconstructionTimeoutSeconds = reconstructionTimeoutSeconds,
      maxTotalSegments = conf.segmentationMaxTotalSegments.get(DefaultMaxTotalSegments),
      maxSegmentSets = conf.segmentationMaxSegmentSets.get(DefaultMaxSegmentSets),
      maxBufferedBytes = conf.segmentationMaxBufferedBytes.get(DefaultMaxBufferedBytes),
    ),
    cleanupInterval: seconds(cleanupIntervalSeconds),
    persistence: nil,
  )

proc new*(
    T: type SegmentationHandler,
    config: ChannelSegmentationConfig,
    channelId: ChannelId,
    brokerCtx: BrokerContext,
): Result[T, string] =
  let timeout = seconds(config.segmentation.reconstructionTimeoutSeconds)
  if config.cleanupInterval <= ZeroDuration:
    return err("segmentation cleanup interval not positive: " & $config.cleanupInterval)
  if config.cleanupInterval > timeout:
    return err(
      "segmentation cleanup interval above the reconstruction timeout: " &
        $config.cleanupInterval & " > " & $timeout
    )

  ## The callbacks capture `channelId` and `brokerCtx` by value; the owning
  ## `ReliableChannel` does not exist yet, and closing over a mutable global
  ## would break their `{.gcsafe.}` requirement.
  let onSetDropped = proc(
      payloadHash: seq[byte], reason: SegmentSetDropReason
  ) {.gcsafe, raises: [].} =
    recordSetDropped(reason)
    debug "Inbound payload lost, its segment set will not reassemble",
      channelId = channelId,
      reason = $reason,
      payloadHash = byteutils.toHex(payloadHash)
    ChannelMessageLostEvent.emit(
      brokerCtx,
      ChannelMessageLostEvent(
        channelId: channelId, payloadHash: payloadHash, reason: $reason
      ),
    )

  let onSegmentDiscarded = proc(reason: SegmentDiscardReason) {.gcsafe, raises: [].} =
    ## Duplicates are routine during SDS retransmission, so expect volume.
    recordSegmentDiscarded(reason)
    debug "Inbound segment discarded", channelId = channelId, reason = $reason

  let onPayloadReassembled = proc(payload: ReassembledPayload) {.gcsafe, raises: [].} =
    ## Counted only. Delivery goes through the `Opt` that
    ## `handleIncomingSegment` returns -- the callback and that return value
    ## are one event, so acting on both would deliver every payload twice.
    recordPayloadReassembled()

  let onSegmentProgress = proc(
      payloadHash: seq[byte], held, expected: int
  ) {.gcsafe, raises: [].} =
    trace "Inbound segment stored",
      channelId = channelId, held = held, expected = expected

  return SegmentationHandler.new(
    config = config.segmentation,
    onSetDropped = onSetDropped,
    onSegmentDiscarded = onSegmentDiscarded,
    onPayloadReassembled = onPayloadReassembled,
    onSegmentProgress = onSegmentProgress,
  )

{.pop.}

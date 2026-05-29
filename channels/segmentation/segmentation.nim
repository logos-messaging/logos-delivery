## Segmentation component for the Reliable Channel API.
##
## Splits large application payloads into transmittable segments and
## reassembles them on reception. Supports optional Reed-Solomon parity
## segments for loss recovery, as per the Reliable Channel API spec.
##
## For the skeleton everything fits in a single segment: real chunking
## and Reed-Solomon parity will be plugged in later.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/options
import ./segment_message_proto
import ./segmentation_persistence

export segment_message_proto, segmentation_persistence

const
  DefaultSegmentSizeBytes* = 102_400
  SegmentsParityRate* = 0.125
  SegmentsReedSolomonMaxCount* = 256

type
  SegmentationConfig* = object
    segmentSizeBytes*: int
    enableReedSolomon*: bool
    persistence*: SegmentationPersistence

  SegmentationHandler* = ref object
    config*: SegmentationConfig

  ReassemblyResult* = object
    payload*: seq[byte]
    entireMessageHash*: seq[byte]

proc new*(T: type SegmentationHandler, config: SegmentationConfig): T =
  return T(config: config)

proc performSegmentation*(
    self: SegmentationHandler, payload: seq[byte]
): seq[seq[byte]] =
  ## Skeleton behaviour: emit exactly one segment carrying the whole
  ## payload. Real chunking and Reed-Solomon parity will replace this.
  let segment = SegmentMessageProto(
    entireMessageHash: @[],
    dataSegmentIndex: 0,
    dataSegmentCount: 1,
    payload: payload,
    paritySegmentIndex: 0,
    paritySegmentCount: 0,
    isParity: false,
  )
  return @[segment.encode()]

proc handleIncomingSegment*(
    self: SegmentationHandler, segmentBytes: seq[byte]
): Option[ReassemblyResult] =
  ## Skeleton behaviour: every segment is already a complete message
  ## (since `performSegmentation` always emits one), so just hand the
  ## payload straight back.
  let segment = SegmentMessageProto.decode(segmentBytes)
  return some(
    ReassemblyResult(
      payload: segment.payload, entireMessageHash: segment.entireMessageHash
    )
  )

proc cleanupSegments*(self: SegmentationHandler) =
  ## Drop expired partial-reassembly state.
  discard

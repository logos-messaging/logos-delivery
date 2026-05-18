## Segmentation component for the Reliable Channel API.
##
## Splits large application payloads into transmittable segments and
## reassembles them on reception. Supports optional Reed-Solomon parity
## segments for loss recovery, as per the Reliable Channel API spec.
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

proc segmentMessage*(
    handler: SegmentationHandler, appPayload: seq[byte]
): seq[SegmentMessageProto] =
  ## Split `appPayload` into segments according to handler config.
  ## When `enableReedSolomon` is true, parity segments are appended.
  return @[]

proc handleIncomingSegment*(
    handler: SegmentationHandler, segment: SegmentMessageProto
): Option[ReassemblyResult] =
  ## Process an incoming segment. Returns Some(ReassemblyResult) when
  ## the full message has been reassembled (and hash-verified), else None.
  return none(ReassemblyResult)

proc cleanupSegments*(handler: SegmentationHandler) =
  ## Drop expired partial-reassembly state.
  discard

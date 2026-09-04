## Receive-side segmentation counters.
##
## Losses here are remote-caused, so they are logged at DEBUG; these counters
## are what makes them visible in aggregate.
##
## Label cardinality is bounded by construction: the recorders below take the
## package's enums rather than strings, so `reason` can only ever be one of the
## four `SegmentSetDropReason` values (Expired, Evicted, HashMismatch,
## Malformed) or the six `SegmentDiscardReason` ones (Undecodable, Invalid,
## Oversized, Duplicate, CountMismatch, CacheFull). Ten series in total, and
## nothing a peer sends can reach a label.

{.push raises: [].}

import metrics
import segmentation

declarePublicCounter logos_delivery_segmentation_sets_dropped,
  "inbound payloads that will never be reassembled", ["reason"]
declarePublicCounter logos_delivery_segmentation_segments_discarded,
  "inbound segments rejected before reaching a segment set", ["reason"]
declarePublicCounter logos_delivery_segmentation_payloads_reassembled,
  "inbound payloads reassembled from a complete segment set"

proc recordSetDropped*(reason: SegmentSetDropReason) =
  logos_delivery_segmentation_sets_dropped.inc(labelValues = [$reason])

proc recordSegmentDiscarded*(reason: SegmentDiscardReason) =
  logos_delivery_segmentation_segments_discarded.inc(labelValues = [$reason])

proc recordPayloadReassembled*() =
  logos_delivery_segmentation_payloads_reassembled.inc()

{.pop.}

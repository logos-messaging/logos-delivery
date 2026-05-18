## Scalable Data Sync (SDS) component for the Reliable Channel API.
##
## Provides end-to-end delivery guarantees via causal history tracking,
## acknowledgements, and retransmission of unacknowledged segments.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import sds/message
import ./sds_persistence
import ../segmentation/segment_message_proto

export message, sds_persistence, segment_message_proto

const
  DefaultAcknowledgementTimeoutMs* = 5_000
  DefaultMaxRetransmissions* = 5
  DefaultCausalHistorySize* = 2

type
  SdsConfig* = object
    acknowledgementTimeoutMs*: int
    maxRetransmissions*: int
    causalHistorySize*: int
    persistence*: SdsPersistence

  SdsHandler* = ref object
    config*: SdsConfig

proc new*(T: type SdsHandler, config: SdsConfig): T =
  return T(config: config)

proc wrapOutgoing*(
    self: SdsHandler,
    channelId: SdsChannelID,
    senderId: SdsParticipantID,
    segment: SegmentMessageProto,
): SdsMessage =
  ## Stage 2 of the outgoing pipeline (segmentation -> sds -> rate_limit_manager -> encryption).
  ## Wraps a single segment from the segmentation stage into an `SdsMessage`,
  ## populating causal history, lamport timestamp and bloom filter.
  ##
  ## TODO: real causal-history/lamport/bloom-filter population.
  discard

proc handleIncoming*(
    self: SdsHandler, msg: SdsMessage
): SdsMessage =
  ## Update local SDS state from an incoming message. May trigger
  ## repair requests (SDS-R) for missing causal history entries.
  discard

proc tickRetransmissions*(self: SdsHandler): seq[SdsMessage] =
  ## Returns messages whose ack timeout has elapsed and should be
  ## retransmitted.
  discard

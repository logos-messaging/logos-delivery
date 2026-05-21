## Scalable Data Sync (SDS) component for the Reliable Channel API.
##
## Provides end-to-end delivery guarantees via causal history tracking,
## acknowledgements, and retransmission of unacknowledged segments.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import sds/message
import ./sds_persistence

export message, sds_persistence

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
    payload: seq[byte],
): SdsMessage =
  ## Stage 2 of the outgoing pipeline (segmentation -> sds -> rate_limit_manager -> encryption).
  ## SDS is intentionally segmentation-agnostic: the caller encodes the
  ## segment to bytes before handing it over here.
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

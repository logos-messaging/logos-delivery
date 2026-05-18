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
    handler: SdsHandler,
    channelId: SdsChannelID,
    senderId: SdsParticipantID,
    content: seq[byte],
): SdsMessage =
  ## Wrap an outgoing segment payload into an SdsMessage with causal
  ## history, lamport timestamp and bloom filter.
  discard

proc handleIncoming*(
    handler: SdsHandler, msg: SdsMessage
): SdsMessage =
  ## Update local SDS state from an incoming message. May trigger
  ## repair requests (SDS-R) for missing causal history entries.
  discard

proc tickRetransmissions*(handler: SdsHandler): seq[SdsMessage] =
  ## Returns messages whose ack timeout has elapsed and should be
  ## retransmitted.
  discard

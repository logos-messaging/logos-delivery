## Scalable Data Sync (SDS) component for the Reliable Channel API.
##
## Provides end-to-end delivery guarantees via causal history tracking,
## acknowledgements, and retransmission of unacknowledged segments.
##
## Skeleton: `wrapOutgoing` and `handleIncoming` are pass-throughs so
## the send/receive circuit can exercise the surrounding pipeline.
## Real SDS wrapping will plug in via `nim-sds` later.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import results
import message as sds_message

import ./sds_persistence

export sds_message, sds_persistence

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
    participantId*: SdsParticipantID

proc new*(
    T: type SdsHandler,
    config: SdsConfig,
    participantId: SdsParticipantID = SdsParticipantID(""),
): T =
  return T(config: config, participantId: participantId)

proc wrapOutgoing*(
    self: SdsHandler,
    channelId: SdsChannelID,
    senderId: SdsParticipantID,
    payload: seq[byte],
): Result[seq[byte], string] =
  ## Stage 2 of the outgoing pipeline (segmentation -> sds -> rate_limit_manager -> encryption).
  ## Skeleton: pass the encoded segment through unchanged. Real causal
  ## history / lamport / bloom-filter population will replace this.
  return ok(payload)

proc handleIncoming*(
    self: SdsHandler, msg: seq[byte]
): Result[tuple[content: seq[byte], channelId: SdsChannelID], string] =
  ## Skeleton: pass the bytes through; channel id is left empty until
  ## the real wire format provides it.
  return ok((content: msg, channelId: SdsChannelID("")))

proc tickRetransmissions*(self: SdsHandler) =
  ## Drives retransmissions of unacknowledged messages.
  discard

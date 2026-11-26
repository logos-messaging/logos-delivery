{.push raises: [].}

import std/strutils, results, chronos, libp2p/peerid
import ../waku_core, ./rpc, ../waku_relay/protocol, ../rln/markers

from ../waku_core/codecs import WakuLightPushCodec
export WakuLightPushCodec
export LightPushStatusCode

const LightPushSuccessCode* = (SUCCESS: LightPushStatusCode(200))

const LightPushErrorCode* = (
  BAD_REQUEST: LightPushStatusCode(400),
  PAYLOAD_TOO_LARGE: LightPushStatusCode(413),
  INVALID_MESSAGE: LightPushStatusCode(420),
  UNSUPPORTED_PUBSUB_TOPIC: LightPushStatusCode(421),
  TOO_MANY_REQUESTS: LightPushStatusCode(429),
  INTERNAL_SERVER_ERROR: LightPushStatusCode(500),
  SERVICE_NOT_AVAILABLE: LightPushStatusCode(503),
  OUT_OF_RLN_PROOF: LightPushStatusCode(504),
  NO_PEERS_TO_RELAY: LightPushStatusCode(505),
)

func statusLabel*(code: LightPushStatusCode): string =
  for known in LightPushErrorCode.fields:
    if code == known:
      return $known
  return OtherLabel

type
  LightPushSent* {.pure.} = enum
    ## Can the message of a failed push have left this node?
    ## Only this node sets this value, and no lightpush message carries it.
    Unknown ## This node makes no claim, so a caller acts as if the message left.
    NotSent ## Nothing left this node.

  LightPushRln* {.pure.} = enum
    ## What this node knows of an RLN refusal of a failed push.
    ## Only this node sets this value, and no lightpush message carries it.
    None ## This node found no RLN refusal.
    Refused ## An RLN validator refused the proof, on this node or on the service node.
    RefreshScheduled ## As `Refused`, and this node scheduled a proof refresh.

  ErrorStatus* = object
    code*: LightpushStatusCode
    desc*: Opt[string]
    sent*: LightPushSent
    rln*: LightPushRln

type WakuLightPushResult* = Result[uint32, ErrorStatus]

type PushMessageHandler* = proc(
  pubsubTopic: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult] {.async.}

type PushRequestHandler* = proc(
  peerId: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult] {.async.}
  ## Handles the push request of `peerId`, this node's own id for a request
  ## the node makes to itself.

const TooManyRequestsMessage* = "Request rejected due to too many requests"

## requestId a service answers with when it rejects a request before reading it
const UnknownRequestId* = "N/A"

func isSuccess*(response: LightPushResponse): bool =
  return response.statusCode == LightPushSuccessCode.SUCCESS

func rlnOf*(code: LightpushStatusCode, desc: string): LightPushRln =
  ## `Refused` for an `INVALID_MESSAGE` with the text of the RLN validator.
  if code == LightPushErrorCode.INVALID_MESSAGE and desc.contains(RlnValidatorErrorMsg):
    return LightPushRln.Refused
  return LightPushRln.None

func isRlnRejection*(error: ErrorStatus): bool =
  ## True when a publish failure means "the RLN proof was not accepted", so the
  ## message is worth retrying with a freshly generated proof rather than being
  ## failed outright.
  ##
  ## OUT_OF_RLN_PROOF is always RLN.
  ## INVALID_MESSAGE also covers other refusals, so it needs an `rln` other than `None`.
  return
    error.code == LightPushErrorCode.OUT_OF_RLN_PROOF or error.rln != LightPushRln.None

func toPushResult*(response: LightPushResponse): WakuLightPushResult =
  if isSuccess(response):
    let relayPeerCount = response.relayPeerCount.get(0)
    return (
      if (relayPeerCount == 0):
        # Consider publishing to zero peers an error even if the service node
        # sent us a "successful" response with zero peers
        err(
          ErrorStatus(
            code: LightPushErrorCode.NO_PEERS_TO_RELAY, desc: response.statusDesc
          )
        )
      else:
        ok(relayPeerCount)
    )
  else:
    return err(
      ErrorStatus(
        code: response.statusCode,
        desc: response.statusDesc,
        rln: rlnOf(response.statusCode, response.statusDesc.get("")),
      )
    )

func lightpushSuccessResult*(relayPeerCount: uint32): WakuLightPushResult =
  return ok(relayPeerCount)

func lighpushErrorResult*(
    statusCode: LightpushStatusCode,
    desc: string,
    sent = LightPushSent.Unknown,
    rln = LightPushRln.None,
): WakuLightPushResult =
  return err(ErrorStatus(code: statusCode, desc: Opt.some(desc), sent: sent, rln: rln))

func lightpushResultInternalError*(msg: string): WakuLightPushResult =
  return lighpushErrorResult(LightPushErrorCode.INTERNAL_SERVER_ERROR, msg)

func lightpushResultBadRequest*(msg: string): WakuLightPushResult =
  return lighpushErrorResult(LightPushErrorCode.BAD_REQUEST, msg)

func lightpushResultServiceUnavailable*(msg: string): WakuLightPushResult =
  return lighpushErrorResult(LightPushErrorCode.SERVICE_NOT_AVAILABLE, msg)

func mapPubishingErrorToPushResult*(
    publishOutcome: PublishOutcome, maxMessageSize: int
): WakuLightPushResult =
  ## `maxMessageSize` is the max size of an encoded message, for the
  ## `MessageTooLarge` text.
  case publishOutcome
  of NoTopicSpecified:
    return lighpushErrorResult(
      LightPushErrorCode.INVALID_MESSAGE, "Empty topic, skipping publish",
      LightPushSent.NotSent,
    )
  of DuplicateMessage:
    return lighpushErrorResult(
      LightPushErrorCode.INVALID_MESSAGE, "Dropping already-seen message",
      LightPushSent.NotSent,
    )
  of NoPeersToPublish:
    # This error makes no claim about the message.
    # This node's filter service and archive can still get it.
    return lighpushErrorResult(
      LightPushErrorCode.NO_PEERS_TO_RELAY, "No peers for topic, skipping publish"
    )
  of CannotGenerateMessageId:
    return lighpushErrorResult(
      LightPushErrorCode.INTERNAL_SERVER_ERROR,
      "Error generating message id, skipping publish", LightPushSent.NotSent,
    )
  of InvalidMessage:
    return lighpushErrorResult(
      LightPushErrorCode.INVALID_MESSAGE, "Invalid message, skipping publish",
      LightPushSent.NotSent,
    )
  of MessageTooLarge:
    return lighpushErrorResult(
      LightPushErrorCode.PAYLOAD_TOO_LARGE,
      "Message size exceeded maximum of: " & $maxMessageSize & " bytes",
      LightPushSent.NotSent,
    )

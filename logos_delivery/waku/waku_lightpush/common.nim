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
  LightPushLocalErrorCode* {.pure.} = enum
    ## The local reason for a failed push. It is never sent on the wire.
    None ## No local code. The error is the reply of the service node.
    Unavailable ## Lightpush, mix or relay is not available on this node.
    NoServicePeer ## No lightpush service peer.
    RejectedLocally ## This node rejected the message.
    RlnRejectedLocally ## The RLN validator of this node rejected the proof.
    FailedBeforeSend ## This node failed before the send.
    DialFailure ## The dial to the service node failed.
    BadResponse ## The request was sent, and the response was missing or invalid.
    TimedOut ## The push timed out.
    OtherError ## Any other error of this node.
    NoRelayPeer ## Relay had no peer for the message.
    RlnRejectedByService ## The RLN validator of the service node rejected the proof.
    RlnRefreshScheduled ## As `RlnRejectedByService`, and this node scheduled a refresh.

  ErrorStatus* = object
    code*: LightpushStatusCode
    desc*: Opt[string]
    localErrorCode*: LightPushLocalErrorCode

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

func isRlnValidatorRejection*(code: LightpushStatusCode, desc: string): bool =
  return
    code == LightPushErrorCode.INVALID_MESSAGE and desc.contains(RlnValidatorErrorMsg)

func isRlnRejection*(error: ErrorStatus): bool =
  ## True when a publish failure means "the RLN proof was not accepted", so the
  ## message is worth retrying with a freshly generated proof rather than being
  ## failed outright.
  return
    error.localErrorCode in {
      LightPushLocalErrorCode.RlnRejectedLocally,
      LightPushLocalErrorCode.RlnRejectedByService,
      LightPushLocalErrorCode.RlnRefreshScheduled,
    }

func notSent*(error: ErrorStatus): bool =
  ## True when the failed push did not send the message.
  ## `None` is not in the set, because this node asked the service node.
  ## The service node got the message, and this node has no local failure to add.
  return
    error.localErrorCode in {
      LightPushLocalErrorCode.Unavailable, LightPushLocalErrorCode.NoServicePeer,
      LightPushLocalErrorCode.RejectedLocally,
      LightPushLocalErrorCode.RlnRejectedLocally,
      LightPushLocalErrorCode.FailedBeforeSend, LightPushLocalErrorCode.DialFailure,
    }

func toPushResult*(response: LightPushResponse): WakuLightPushResult =
  if isSuccess(response):
    let relayPeerCount = response.relayPeerCount.get(0)
    return (
      if (relayPeerCount == 0):
        # Consider publishing to zero peers an error even if the service node
        # sent us a "successful" response with zero peers
        err(
          ErrorStatus(
            code: LightPushErrorCode.NO_PEERS_TO_RELAY,
            desc: response.statusDesc,
            localErrorCode: LightPushLocalErrorCode.None,
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
        localErrorCode:
          if isRlnValidatorRejection(response.statusCode, response.statusDesc.get("")):
            LightPushLocalErrorCode.RlnRejectedByService
          else:
            LightPushLocalErrorCode.None,
      )
    )

func lightpushSuccessResult*(relayPeerCount: uint32): WakuLightPushResult =
  return ok(relayPeerCount)

func lighpushErrorResult*(
    statusCode: LightpushStatusCode,
    desc: string,
    localErrorCode: LightPushLocalErrorCode,
): WakuLightPushResult =
  return err(
    ErrorStatus(code: statusCode, desc: Opt.some(desc), localErrorCode: localErrorCode)
  )

func lightpushResultInternalError*(
    msg: string, localErrorCode: LightPushLocalErrorCode
): WakuLightPushResult =
  return
    lighpushErrorResult(LightPushErrorCode.INTERNAL_SERVER_ERROR, msg, localErrorCode)

func lightpushResultBadRequest*(
    msg: string, localErrorCode: LightPushLocalErrorCode
): WakuLightPushResult =
  return lighpushErrorResult(LightPushErrorCode.BAD_REQUEST, msg, localErrorCode)

func lightpushResultServiceUnavailable*(
    msg: string, localErrorCode: LightPushLocalErrorCode
): WakuLightPushResult =
  return
    lighpushErrorResult(LightPushErrorCode.SERVICE_NOT_AVAILABLE, msg, localErrorCode)

func mapPubishingErrorToPushResult*(
    publishOutcome: PublishOutcome, maxMessageSize: int
): WakuLightPushResult =
  ## `maxMessageSize` is the max size of an encoded message, for the
  ## `MessageTooLarge` text.
  case publishOutcome
  of NoTopicSpecified:
    return lighpushErrorResult(
      LightPushErrorCode.INVALID_MESSAGE, "Empty topic, skipping publish",
      LightPushLocalErrorCode.RejectedLocally,
    )
  of DuplicateMessage:
    return lighpushErrorResult(
      LightPushErrorCode.INVALID_MESSAGE, "Dropping already-seen message",
      LightPushLocalErrorCode.RejectedLocally,
    )
  of NoPeersToPublish:
    return lighpushErrorResult(
      LightPushErrorCode.NO_PEERS_TO_RELAY, "No peers for topic, skipping publish",
      LightPushLocalErrorCode.NoRelayPeer,
    )
  of CannotGenerateMessageId:
    return lighpushErrorResult(
      LightPushErrorCode.INTERNAL_SERVER_ERROR,
      "Error generating message id, skipping publish",
      LightPushLocalErrorCode.FailedBeforeSend,
    )
  of InvalidMessage:
    return lighpushErrorResult(
      LightPushErrorCode.INVALID_MESSAGE, "Invalid message, skipping publish",
      LightPushLocalErrorCode.RejectedLocally,
    )
  of MessageTooLarge:
    return lighpushErrorResult(
      LightPushErrorCode.PAYLOAD_TOO_LARGE,
      "Message size exceeded maximum of: " & $maxMessageSize & " bytes",
      LightPushLocalErrorCode.RejectedLocally,
    )

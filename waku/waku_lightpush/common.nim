{.push raises: [].}

import std/options, results, chronos, libp2p/peerid
import ../waku_core, ./rpc, ../waku_relay/protocol

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

type ErrorStatus* = tuple[code: LightpushStatusCode, desc: Option[string]]
type WakuLightPushResult* = Result[uint32, ErrorStatus]

type PushMessageHandler* = proc(
  pubsubTopic: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult] {.async.}

const TooManyRequestsMessage* = "Request rejected due to too many requests"

func isSuccess*(response: LightPushResponse): bool =
  return response.statusCode == LightPushSuccessCode.SUCCESS

func toPushResult*(response: LightPushResponse): WakuLightPushResult =
  if isSuccess(response):
    let relayPeerCount = response.relayPeerCount.get(0)
    return (
      if (relayPeerCount == 0):
        # Consider publishing to zero peers an error even if the service node
        # sent us a "successful" response with zero peers
        err((LightPushErrorCode.NO_PEERS_TO_RELAY, response.statusDesc))
      else:
        ok(relayPeerCount)
    )
  else:
    return err((response.statusCode, response.statusDesc))

func lightpushSuccessResult*(relayPeerCount: uint32): WakuLightPushResult =
  return ok(relayPeerCount)

func lightpushResultInternalError*(msg: string): WakuLightPushResult =
  return err((LightPushErrorCode.INTERNAL_SERVER_ERROR, some(msg)))

func lightpushResultBadRequest*(msg: string): WakuLightPushResult =
  return err((LightPushErrorCode.BAD_REQUEST, some(msg)))

func lightpushResultServiceUnavailable*(msg: string): WakuLightPushResult =
  return err((LightPushErrorCode.SERVICE_NOT_AVAILABLE, some(msg)))

func lighpushErrorResult*(
    statusCode: LightpushStatusCode, desc: string
): WakuLightPushResult =
  return err((statusCode, some(desc)))

func mapPubishingErrorToPushResult*(
    publishOutcome: PublishOutcome
): WakuLightPushResult =
  case publishOutcome
  of NoTopicSpecified:
    return
      err((LightPushErrorCode.INVALID_MESSAGE, some("Empty topic, skipping publish")))
  of DuplicateMessage:
    return
      err((LightPushErrorCode.INVALID_MESSAGE, some("Dropping already-seen message")))
  of NoPeersToPublish:
    return err(
      (
        LightPushErrorCode.NO_PEERS_TO_RELAY,
        some("No peers for topic, skipping publish"),
      )
    )
  of CannotGenerateMessageId:
    return err(
      (
        LightPushErrorCode.INTERNAL_SERVER_ERROR,
        some("Error generating message id, skipping publish"),
      )
    )

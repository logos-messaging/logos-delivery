{.push raises: [].}

import
  std/strformat,
  stew/byteutils,
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/route,
  presto/common

import
  waku/node/peer_manager,
  waku/waku_lightpush/common,
  ../../../waku_node,
  ../../handlers,
  ../serdes,
  ../responses,
  ../rest_serdes,
  ./types

export types

logScope:
  topics = "waku node rest lightpush api"

const FutTimeoutForPushRequestProcessing* = 5.seconds

const NoPeerNoDiscoError = "No suitable service peer & no discovery method"
const NoPeerNoneFoundError = "No suitable service peer & none discovered"

proc useSelfHostedLightPush(node: WakuNode): bool =
  return node.wakuLightPush != nil and node.wakuLightPushClient == nil

proc convertErrorKindToHttpStatus(statusCode: LightPushStatusCode): HttpCode =
  ## Lightpush status codes are matching HTTP status codes by design
  return toHttpCode(statusCode.int).get(Http500)

proc makeRestResponse(response: WakuLightPushResult): RestApiResponse =
  var httpStatus: HttpCode = Http200
  var apiResponse: PushResponse

  if response.isOk():
    apiResponse.relayPeerCount = some(response.get())
  else:
    httpStatus = convertErrorKindToHttpStatus(response.error().code)
    apiResponse.statusDesc = response.error().desc

  let restResp = RestApiResponse.jsonResponse(apiResponse, status = httpStatus).valueOr:
    error "An error ocurred while building the json respose: ", error = error
    return RestApiResponse.internalServerError(
      fmt("An error ocurred while building the json respose: {error}")
    )

  return restResp

#### Request handlers
const ROUTE_LIGHTPUSH = "/lightpush/v3/message"

proc installLightPushRequestHandler*(
    router: var RestRouter,
    node: WakuNode,
    discHandler: Option[DiscoveryHandler] = none(DiscoveryHandler),
) =
  router.api(MethodPost, ROUTE_LIGHTPUSH) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Send a request to push a waku message
    info "post received", ROUTE_LIGHTPUSH
    trace "content body", ROUTE_LIGHTPUSH, contentBody

    let req: PushRequest = decodeRequestBody[PushRequest](contentBody).valueOr:
      return
        makeRestResponse(lightpushResultBadRequest("Invalid push request! " & $error))

    let msg = req.message.toWakuMessage().valueOr:
      return makeRestResponse(lightpushResultBadRequest("Invalid message! " & $error))

    var toPeer = none(RemotePeerInfo)
    if useSelfHostedLightPush(node):
      discard
    else:
      let aPeer = node.peerManager.selectPeer(WakuLightPushCodec).valueOr:
        let handler = discHandler.valueOr:
          return makeRestResponse(lightpushResultServiceUnavailable(NoPeerNoDiscoError))

        let peerOp = (await handler()).valueOr:
          return makeRestResponse(
            lightpushResultInternalError("No value in peerOp: " & $error)
          )

        peerOp.valueOr:
          return
            makeRestResponse(lightpushResultServiceUnavailable(NoPeerNoneFoundError))
      toPeer = some(aPeer)

    let subFut = node.lightpushPublish(req.pubsubTopic, msg, toPeer)

    if not await subFut.withTimeout(FutTimeoutForPushRequestProcessing):
      error "Failed to request a message push due to timeout!"
      return
        makeRestResponse(lightpushResultServiceUnavailable("Push request timed out"))

    return makeRestResponse(subFut.value())

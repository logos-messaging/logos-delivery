{.push raises: [].}

import
  std/strformat,
  std/options,
  std/strutils,
  results,
  stew/byteutils,
  chronicles,
  json_serialization,
  json_serialization/pkg/results,
  presto/route,
  presto/common

import
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/waku_lightpush/common,
  logos_delivery/waku/waku_node,
  logos_delivery/waku/rln,
  rest/discovery_handler,
  rest/serdes,
  rest/responses,
  rest/rest_serdes,
  rest/kernel_api/lightpush/types

export types

logScope:
  topics = "waku node rest lightpush api"

const FutTimeoutForPushRequestProcessing* = 5.seconds

const NoPeerNoDiscoError = "No suitable service peer & no discovery method"
const NoPeerNoneFoundError = "No suitable service peer & none discovered"

proc useSelfHostedLightPush(node: WakuNode): bool =
  return not node.wakuLightPush.isNil()

proc convertErrorKindToHttpStatus(statusCode: LightPushStatusCode): HttpCode =
  ## Other lightpush codes reach HTTP unchanged for compatibility, although some
  ## (421, 504, 505) have unrelated HTTP meanings. Only INVALID_MESSAGE (420), which
  ## is not an HTTP status, is mapped, to 400.
  if statusCode.int == LightPushErrorCode.INVALID_MESSAGE.int:
    return Http400
  return toHttpCode(statusCode.int).get(Http500)

proc makeRestResponse(response: WakuLightPushResult): RestApiResponse =
  var httpStatus: HttpCode = Http200
  var apiResponse: PushResponse

  if response.isOk():
    apiResponse.relayPeerCount = Opt.some(response.get())
  else:
    httpStatus = convertErrorKindToHttpStatus(response.error().code)
    apiResponse.statusDesc = response.error().desc

  let restResp = RestApiResponse.jsonResponse(apiResponse, status = httpStatus).valueOr:
    error "An error occurred while building the json response: ", error = error
    return RestApiResponse.internalServerError(
      fmt("An error occurred while building the json response: {error}")
    )

  return restResp

#### Request handlers
const ROUTE_LIGHTPUSH = "/lightpush/v3/message"

proc installLightPushRequestHandler*(
    router: var RestRouter,
    node: WakuNode,
    discHandler: Opt[DiscoveryHandler] = Opt.none(DiscoveryHandler),
) =
  router.api(MethodPost, ROUTE_LIGHTPUSH) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Send a request to push a waku message
    debug "post received", ROUTE_LIGHTPUSH
    trace "content body", ROUTE_LIGHTPUSH, contentBody

    let req: PushRequest = decodeJsonBody[PushRequest](contentBody).valueOr:
      return
        makeRestResponse(lightpushResultBadRequest("Invalid push request! " & $error))

    let msg = req.message.toWakuMessage().valueOr:
      return makeRestResponse(lightpushResultBadRequest("Invalid message! " & $error))

    var toPeer = Opt.none(RemotePeerInfo)
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
      toPeer = Opt.some(aPeer)

    var pushFut = node.lightpushPublish(req.pubsubTopic, msg, toPeer)

    if not await pushFut.withTimeout(FutTimeoutForPushRequestProcessing):
      error "Failed to request a message push due to timeout!"
      return
        makeRestResponse(lightpushResultServiceUnavailable("Push request timed out"))

    var pushResult = pushFut.value()

    # An error tagged RlnProofRefreshScheduledMsg is a publish rejected on a
    # stale merkle root. On this error the kernel scheduled a cache refresh
    # before failing early. This synchronous endpoint has no retry loop of its
    # own, so retry once — the second attempt generates its proof against the
    # refreshed merkle path.
    if pushResult.isErr() and
        pushResult.error.desc.get("").contains(RlnProofRefreshScheduledMsg):
      pushFut = node.lightpushPublish(req.pubsubTopic, msg, toPeer)
      if not await pushFut.withTimeout(FutTimeoutForPushRequestProcessing):
        error "Failed to request a message push due to timeout!"
        return
          makeRestResponse(lightpushResultServiceUnavailable("Push request timed out"))
      pushResult = pushFut.value()

    return makeRestResponse(pushResult)

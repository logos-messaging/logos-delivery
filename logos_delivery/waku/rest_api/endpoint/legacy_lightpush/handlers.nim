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
  logos_delivery/waku/waku_lightpush_legacy/common,
  ../../../waku_node,
  ../../../rln,
  ../../handlers,
  ../serdes,
  ../responses,
  ../rest_serdes,
  ./types

export types

logScope:
  topics = "waku node rest legacy lightpush api"

const FutTimeoutForPushRequestProcessing* = 5.seconds

const NoPeerNoDiscoError =
  RestApiResponse.serviceUnavailable("No suitable service peer & no discovery method")

const NoPeerNoneFoundError =
  RestApiResponse.serviceUnavailable("No suitable service peer & none discovered")

proc useSelfHostedLightPush(node: WakuNode): bool =
  return node.wakuLegacyLightPush != nil and node.wakuLegacyLightPushClient == nil

#### Request handlers

const ROUTE_LIGHTPUSH = "/lightpush/v1/message"

proc installLightPushRequestHandler*(
    router: var RestRouter,
    node: WakuNode,
    discHandler: Opt[DiscoveryHandler] = Opt.none(DiscoveryHandler),
) =
  router.api(MethodPost, ROUTE_LIGHTPUSH) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Send a request to push a waku message
    debug "post", ROUTE_LIGHTPUSH, contentBody

    let req: PushRequest = decodeRequestBody[PushRequest](contentBody).valueOr:
      return error

    let msg = req.message.toWakuMessage().valueOr:
      return RestApiResponse.badRequest("Invalid message: " & $error)

    var peer = RemotePeerInfo.init($node.switch.peerInfo.peerId)
    if useSelfHostedLightPush(node):
      discard
    else:
      peer = node.peerManager.selectPeer(WakuLegacyLightPushCodec).valueOr:
        let handler = discHandler.valueOr:
          return NoPeerNoDiscoError

        let peerOp = (await handler()).valueOr:
          return RestApiResponse.internalServerError("No value in peerOp: " & $error)

        peerOp.valueOr:
          return NoPeerNoneFoundError

    var pushFut = node.legacyLightpushPublish(req.pubsubTopic, msg, peer)

    if not await pushFut.withTimeout(FutTimeoutForPushRequestProcessing):
      error "Failed to request a message push due to timeout!"
      return RestApiResponse.serviceUnavailable("Push request timed out")

    var pushResult = pushFut.value()

    # An error tagged RlnProofRefreshScheduledMsg is a publish rejected on a
    # stale merkle root. On this error the kernel scheduled a cache refresh
    # before failing early. This synchronous endpoint has no retry loop of its
    # own, so retry once — the second attempt generates its proof against the
    # refreshed merkle path.
    if pushResult.isErr() and pushResult.error.contains(RlnProofRefreshScheduledMsg):
      pushFut = node.legacyLightpushPublish(req.pubsubTopic, msg, peer)
      if not await pushFut.withTimeout(FutTimeoutForPushRequestProcessing):
        error "Failed to request a message push due to timeout!"
        return RestApiResponse.serviceUnavailable("Push request timed out")
      pushResult = pushFut.value()

    pushResult.isOkOr:
      if error == TooManyRequestsMessage:
        return RestApiResponse.tooManyRequests("Request rate limmit reached")

      return RestApiResponse.serviceUnavailable(
        fmt("Failed to request a message push: {error}")
      )

    return RestApiResponse.ok()

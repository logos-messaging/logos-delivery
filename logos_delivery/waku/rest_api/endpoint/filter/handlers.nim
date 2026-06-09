{.push raises: [].}

import
  std/strformat,
  std/sequtils,
  stew/byteutils,
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/route,
  presto/common
import
  ../../../waku_core,
  ../../../waku_node,
  ../../../node/peer_manager,
  ../../../waku_filter_v2,
  ../../../waku_filter_v2/client as filter_protocol_client,
  ../../../waku_filter_v2/common as filter_protocol_type,
  ../../message_cache,
  ../../handlers,
  ../serdes,
  ../responses,
  ../rest_serdes,
  ./types

export types

logScope:
  topics = "waku node rest filter_api_v2"

const futTimeoutForSubscriptionProcessing* = 5.seconds

#### Request handlers

const ROUTE_FILTER_SUBSCRIPTIONS* = "/filter/v2/subscriptions"

const ROUTE_FILTER_ALL_SUBSCRIPTIONS* = "/filter/v2/subscriptions/all"

func decodeRequestBody[T](
    contentBody: Option[ContentBody]
): Result[T, RestApiResponse] =
  if contentBody.isNone():
    return err(RestApiResponse.badRequest("Missing content body"))

  let reqBodyContentType = MediaType.init($contentBody.get().contentType)
  if reqBodyContentType != MIMETYPE_JSON:
    return
      err(RestApiResponse.badRequest("Wrong Content-Type, expected application/json"))

  let reqBodyData = contentBody.get().data

  let requestResult = decodeFromJsonBytes(T, reqBodyData).valueOr:
    return err(
      RestApiResponse.badRequest("Invalid content body, could not decode. " & $error)
    )

  return ok(requestResult)

proc getStatusDesc(
    protocolClientRes: filter_protocol_type.FilterSubscribeResult
): string =
  ## Retrieve proper error cause of FilterSubscribeError - due stringify make some parts of text double
  if protocolClientRes.isOk:
    return "OK"

  let err = protocolClientRes.error
  case err.kind
  of FilterSubscribeErrorKind.PEER_DIAL_FAILURE:
    err.address
  of FilterSubscribeErrorKind.BAD_RESPONSE, FilterSubscribeErrorKind.BAD_REQUEST,
      FilterSubscribeErrorKind.NOT_FOUND, FilterSubscribeErrorKind.TOO_MANY_REQUESTS,
      FilterSubscribeErrorKind.SERVICE_UNAVAILABLE:
    err.cause
  of FilterSubscribeErrorKind.UNKNOWN:
    "UNKNOWN"

proc convertResponse(
    T: type FilterSubscriptionResponse,
    requestId: string,
    protocolClientRes: filter_protocol_type.FilterSubscribeResult,
): T =
  ## Properly convert filter protocol's response to rest response
  return FilterSubscriptionResponse(
    requestId: requestId, statusDesc: getStatusDesc(protocolClientRes)
  )

proc convertResponse(
    T: type FilterSubscriptionResponse,
    requestId: string,
    protocolClientRes: filter_protocol_type.FilterSubscribeError,
): T =
  ## Properly convert filter protocol's response to rest response in case of error
  return
    FilterSubscriptionResponse(requestId: requestId, statusDesc: $protocolClientRes)

proc convertErrorKindToHttpStatus(
    kind: filter_protocol_type.FilterSubscribeErrorKind
): HttpCode =
  ## Filter protocol's error code is not directly convertible to HttpCodes hence this converter

  case kind
  of filter_protocol_type.FilterSubscribeErrorKind.UNKNOWN:
    return Http200
  of filter_protocol_type.FilterSubscribeErrorKind.PEER_DIAL_FAILURE:
    return Http504 #gateway timout
  of filter_protocol_type.FilterSubscribeErrorKind.BAD_RESPONSE:
    return Http500 # internal server error
  of filter_protocol_type.FilterSubscribeErrorKind.BAD_REQUEST:
    return Http400
  of filter_protocol_type.FilterSubscribeErrorKind.NOT_FOUND:
    return Http404
  of filter_protocol_type.FilterSubscribeErrorKind.TOO_MANY_REQUESTS:
    return Http429
  of filter_protocol_type.FilterSubscribeErrorKind.SERVICE_UNAVAILABLE:
    return Http503

proc makeRestResponse(
    requestId: string, protocolClientRes: filter_protocol_type.FilterSubscribeResult
): RestApiResponse =
  let filterSubscriptionResponse =
    FilterSubscriptionResponse.convertResponse(requestId, protocolClientRes)

  var httpStatus: HttpCode = Http200

  if protocolClientRes.isErr():
    httpStatus = convertErrorKindToHttpStatus(protocolClientRes.error().kind)
      # TODO: convert status codes!

  let resp = RestApiResponse.jsonResponse(
    filterSubscriptionResponse, status = httpStatus
  ).valueOr:
    error "An error ocurred while building the json respose: ", error = error
    return RestApiResponse.internalServerError(
      fmt("An error ocurred while building the json respose: {error}")
    )

  return resp

proc makeRestResponse(
    requestId: string, protocolClientRes: filter_protocol_type.FilterSubscribeError
): RestApiResponse =
  let filterSubscriptionResponse =
    FilterSubscriptionResponse.convertResponse(requestId, protocolClientRes)

  let httpStatus = convertErrorKindToHttpStatus(protocolClientRes.kind)
    # TODO: convert status codes!

  let resp = RestApiResponse.jsonResponse(
    filterSubscriptionResponse, status = httpStatus
  ).valueOr:
    error "An error ocurred while building the json respose: ", error = error
    return RestApiResponse.internalServerError(
      fmt("An error ocurred while building the json respose: {error}")
    )

  return resp

const NoPeerNoDiscoError = FilterSubscribeError.serviceUnavailable(
  "No suitable service peer & no discovery method"
)

const NoPeerNoneFoundError =
  FilterSubscribeError.serviceUnavailable("No suitable service peer & none discovered")

proc filterPostPutSubscriptionRequestHandler(
    node: WakuNode,
    contentBody: Option[ContentBody],
    cache: MessageCache,
    discHandler: Option[DiscoveryHandler] = none(DiscoveryHandler),
): Future[RestApiResponse] {.async.} =
  ## handles any filter subscription requests, adds or modifies.

  let req: FilterSubscribeRequest = decodeRequestBody[FilterSubscribeRequest](
    contentBody
  ).valueOr:
    return makeRestResponse(
      "unknown",
      FilterSubscribeError.badRequest(fmt("Failed to decode request: {error}")),
    )

  let peer = node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
    let handler = discHandler.valueOr:
      return makeRestResponse(req.requestId, NoPeerNoDiscoError)

    let peerOp = (await handler()).valueOr:
      return RestApiResponse.internalServerError($error)

    peerOp.valueOr:
      return makeRestResponse(req.requestId, NoPeerNoneFoundError)

  let subFut = node.filterSubscribe(req.pubsubTopic, req.contentFilters, peer)

  if not await subFut.withTimeout(futTimeoutForSubscriptionProcessing):
    error "Failed to subscribe to contentFilters do to timeout!"
    return makeRestResponse(
      req.requestId,
      FilterSubscribeError.serviceUnavailable("Subscription request timed out"),
    )

  # Successfully subscribed to all content filters
  for cTopic in req.contentFilters:
    cache.contentSubscribe(cTopic)

  return makeRestResponse(req.requestId, subFut.read())

proc installFilterPostSubscriptionsHandler(
    router: var RestRouter,
    node: WakuNode,
    cache: MessageCache,
    discHandler: Option[DiscoveryHandler] = none(DiscoveryHandler),
) =
  router.api(MethodPost, ROUTE_FILTER_SUBSCRIPTIONS) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Subscribes a node to a list of contentTopics of a pubsubTopic
    info "post", ROUTE_FILTER_SUBSCRIPTIONS, contentBody

    return await filterPostPutSubscriptionRequestHandler(
      node, contentBody, cache, discHandler
    )

proc installFilterPutSubscriptionsHandler(
    router: var RestRouter,
    node: WakuNode,
    cache: MessageCache,
    discHandler: Option[DiscoveryHandler] = none(DiscoveryHandler),
) =
  router.api(MethodPut, ROUTE_FILTER_SUBSCRIPTIONS) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Modifies a subscribtion of a node to a list of contentTopics of a pubsubTopic
    info "put", ROUTE_FILTER_SUBSCRIPTIONS, contentBody

    return await filterPostPutSubscriptionRequestHandler(
      node, contentBody, cache, discHandler
    )

proc installFilterDeleteSubscriptionsHandler(
    router: var RestRouter,
    node: WakuNode,
    cache: MessageCache,
    discHandler: Option[DiscoveryHandler] = none(DiscoveryHandler),
) =
  router.api(MethodDelete, ROUTE_FILTER_SUBSCRIPTIONS) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Subscribes a node to a list of contentTopics of a PubSub topic
    info "delete", ROUTE_FILTER_SUBSCRIPTIONS, contentBody

    let req: FilterUnsubscribeRequest = decodeRequestBody[FilterUnsubscribeRequest](
      contentBody
    ).valueOr:
      return makeRestResponse(
        "unknown",
        FilterSubscribeError.badRequest(fmt("Failed to decode request: {error}")),
      )

    let peer = node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      let handler = discHandler.valueOr:
        return makeRestResponse(req.requestId, NoPeerNoDiscoError)

      let peerOp = (await handler()).valueOr:
        return RestApiResponse.internalServerError($error)

      peerOp.valueOr:
        return makeRestResponse(req.requestId, NoPeerNoneFoundError)

    let unsubFut = node.filterUnsubscribe(req.pubsubTopic, req.contentFilters, peer)

    if not await unsubFut.withTimeout(futTimeoutForSubscriptionProcessing):
      error "Failed to unsubscribe from contentFilters due to timeout!"
      return makeRestResponse(
        req.requestId,
        FilterSubscribeError.serviceUnavailable(
          "Failed to unsubscribe from contentFilters due to timeout!"
        ),
      )

    # Successfully subscribed to all content filters
    for cTopic in req.contentFilters:
      cache.contentUnsubscribe(cTopic)

    # Successfully unsubscribed from all requested contentTopics
    return makeRestResponse(req.requestId, unsubFut.read())

proc installFilterDeleteAllSubscriptionsHandler(
    router: var RestRouter,
    node: WakuNode,
    cache: MessageCache,
    discHandler: Option[DiscoveryHandler] = none(DiscoveryHandler),
) =
  router.api(MethodDelete, ROUTE_FILTER_ALL_SUBSCRIPTIONS) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Subscribes a node to a list of contentTopics of a PubSub topic
    info "delete", ROUTE_FILTER_ALL_SUBSCRIPTIONS, contentBody

    let req: FilterUnsubscribeAllRequest = decodeRequestBody[
      FilterUnsubscribeAllRequest
    ](contentBody).valueOr:
      return makeRestResponse(
        "unknown",
        FilterSubscribeError.badRequest(fmt("Failed to decode request: {error}")),
      )

    let peer = node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      let handler = discHandler.valueOr:
        return makeRestResponse(req.requestId, NoPeerNoDiscoError)

      let peerOp = (await handler()).valueOr:
        return RestApiResponse.internalServerError($error)

      peerOp.valueOr:
        return makeRestResponse(req.requestId, NoPeerNoneFoundError)

    let unsubFut = node.filterUnsubscribeAll(peer)

    if not await unsubFut.withTimeout(futTimeoutForSubscriptionProcessing):
      error "Failed to unsubscribe from contentFilters due to timeout!"
      return makeRestResponse(
        req.requestId,
        FilterSubscribeError.serviceUnavailable(
          "Failed to unsubscribe from all contentFilters due to timeout!"
        ),
      )

    cache.reset()

    # Successfully unsubscribed from all requested contentTopics
    return makeRestResponse(req.requestId, unsubFut.read())

const ROUTE_FILTER_SUBSCRIBER_PING* = "/filter/v2/subscriptions/{requestId}"

proc installFilterPingSubscriberHandler(
    router: var RestRouter,
    node: WakuNode,
    discHandler: Option[DiscoveryHandler] = none(DiscoveryHandler),
) =
  router.api(MethodGet, ROUTE_FILTER_SUBSCRIBER_PING) do(
    requestId: string
  ) -> RestApiResponse:
    ## Checks if a node has valid subscription or not.
    info "get", ROUTE_FILTER_SUBSCRIBER_PING, requestId

    let peer = node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      let handler = discHandler.valueOr:
        return makeRestResponse(requestId.get(), NoPeerNoDiscoError)

      let peerOp = (await handler()).valueOr:
        return RestApiResponse.internalServerError($error)

      peerOp.valueOr:
        return makeRestResponse(requestId.get(), NoPeerNoneFoundError)

    let pingFutRes = node.wakuFilterClient.ping(peer)

    if not await pingFutRes.withTimeout(futTimeoutForSubscriptionProcessing):
      error "Failed to ping filter service peer due to timeout!"
      return makeRestResponse(
        requestId.get(), FilterSubscribeError.serviceUnavailable("Ping timed out")
      )

    return makeRestResponse(requestId.get(), pingFutRes.read())

const ROUTE_FILTER_MESSAGES* = "/filter/v2/messages/{contentTopic}"

proc installFilterGetMessagesHandler(
    router: var RestRouter, node: WakuNode, cache: MessageCache
) =
  let pushHandler: FilterPushHandler = proc(
      pubsubTopic: PubsubTopic, msg: WakuMessage
  ) {.async, gcsafe, closure.} =
    cache.addMessage(pubsubTopic, msg)

  node.wakuFilterClient.registerPushHandler(pushHandler)

  router.api(MethodGet, ROUTE_FILTER_MESSAGES) do(
    contentTopic: string
  ) -> RestApiResponse:
    ## Returns all WakuMessages received on a specified content topic since the
    ## last time this method was called
    ## TODO: ability to specify a return message limit, maybe use cursor to control paging response.
    info "get", ROUTE_FILTER_MESSAGES, contentTopic = contentTopic

    let contentTopic = contentTopic.valueOr:
      return RestApiResponse.badRequest("Missing contentTopic")

    let msg = cache.getAutoMessages(contentTopic, clear = true).valueOr:
      return RestApiResponse.badRequest("Not subscribed to topic: " & contentTopic)

    let data = FilterGetMessagesResponse(msg.map(toFilterWakuMessage))
    let resp = RestApiResponse.jsonResponse(data, status = Http200).valueOr:
      error "An error ocurred while building the json respose: ", error = error
      return RestApiResponse.internalServerError(
        "An error ocurred while building the json respose"
      )

    return resp

proc installFilterRestApiHandlers*(
    router: var RestRouter,
    node: WakuNode,
    cache: MessageCache,
    discHandler: Option[DiscoveryHandler] = none(DiscoveryHandler),
) =
  installFilterPingSubscriberHandler(router, node, discHandler)
  installFilterPostSubscriptionsHandler(router, node, cache, discHandler)
  installFilterPutSubscriptionsHandler(router, node, cache, discHandler)
  installFilterDeleteSubscriptionsHandler(router, node, cache, discHandler)
  installFilterDeleteAllSubscriptionsHandler(router, node, cache, discHandler)
  installFilterGetMessagesHandler(router, node, cache)

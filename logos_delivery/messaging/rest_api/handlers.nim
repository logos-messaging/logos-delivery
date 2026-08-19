{.push raises: [].}

import chronos, chronicles, results, json_serialization, json_serialization/std/options
import presto/[route, common]
import
  logos_delivery/waku/waku,
  logos_delivery/waku/rest_api/endpoint/serdes,
  logos_delivery/waku/rest_api/endpoint/responses,
  logos_delivery/waku/rest_api/endpoint/rest_serdes,
  logos_delivery/messaging/messaging_client,
  logos_delivery/messaging/api/subscription,
  logos_delivery/messaging/api/send,
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  ./types,
  ./event_cache

export types

logScope:
  topics = "messaging rest api"

#### Routes

const ROUTE_MESSAGING_SUBSCRIPTIONSV1* = "/messaging/v1/subscriptions"
const ROUTE_MESSAGING_MESSAGESV1* = "/messaging/v1/messages"
const ROUTE_MESSAGING_EVENTS_SENDV1* = "/messaging/v1/events/send"
const ROUTE_MESSAGING_EVENTS_SEND_BY_IDV1* = "/messaging/v1/events/send/{requestId}"
const ROUTE_MESSAGING_EVENTS_RECEIVEDV1* = "/messaging/v1/events/received"

proc installEventListeners(brokerCtx: BrokerContext, cache: MessagingEventCache) =
  ## Buffers the MessagingClient events into `cache` so the poll-based REST
  ## endpoints can observe them. Listeners live for the node's lifetime (the
  ## captured `cache` keeps them and their data alive); no teardown is wired.
  discard MessageSentEvent.listen(
    brokerCtx,
    proc(evt: MessageSentEvent): Future[void] {.async: (raises: []).} =
      cache.recordSend($evt.requestId, evt.messageHash, SendEventKind.Sent),
  )

  discard MessagePropagatedEvent.listen(
    brokerCtx,
    proc(evt: MessagePropagatedEvent): Future[void] {.async: (raises: []).} =
      cache.recordSend($evt.requestId, evt.messageHash, SendEventKind.Propagated),
  )

  discard MessageErrorEvent.listen(
    brokerCtx,
    proc(evt: MessageErrorEvent): Future[void] {.async: (raises: []).} =
      cache.recordSend($evt.requestId, evt.messageHash, SendEventKind.Error, evt.error),
  )

  discard MessageReceivedEvent.listen(
    brokerCtx,
    proc(evt: MessageReceivedEvent): Future[void] {.async: (raises: []).} =
      cache.recordReceived(evt.messageHash, toRelayWakuMessage(evt.message)),
  )

proc installMessagingApiHandlers*(router: var RestRouter, client: MessagingClient) =
  ## Mounts the MessagingClient subscribe / unsubscribe / send operations as
  ## REST endpoints onto the given (kernel-owned) router. Subscriptions are
  ## keyed by content topic, matching the messaging layer's content-topic API.

  # Event observability: buffer send/received events for the poll-based GETs.
  let eventCache = MessagingEventCache.new()
  installEventListeners(client.waku.brokerCtx, eventCache)

  router.api(MethodOptions, ROUTE_MESSAGING_SUBSCRIPTIONSV1) do() -> RestApiResponse:
    return RestApiResponse.ok()

  router.api(MethodPost, ROUTE_MESSAGING_SUBSCRIPTIONSV1) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Subscribes the messaging client to a list of content topics.
    let req: seq[ContentTopic] = decodeRequestBody[seq[ContentTopic]](contentBody).valueOr:
      return error

    for contentTopic in req:
      (await client.subscribe(contentTopic)).isOkOr:
        let errorMsg = "Subscribe failed: " & error
        error "Messaging SUBSCRIBE failed", error = errorMsg
        return RestApiResponse.internalServerError(errorMsg)

    return RestApiResponse.ok()

  router.api(MethodDelete, ROUTE_MESSAGING_SUBSCRIPTIONSV1) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Unsubscribes the messaging client from a list of content topics.
    let req: seq[ContentTopic] = decodeRequestBody[seq[ContentTopic]](contentBody).valueOr:
      return error

    for contentTopic in req:
      client.unsubscribe(contentTopic).isOkOr:
        let errorMsg = "Unsubscribe failed: " & error
        error "Messaging UNSUBSCRIBE failed", error = errorMsg
        return RestApiResponse.internalServerError(errorMsg)

    return RestApiResponse.ok()

  router.api(MethodOptions, ROUTE_MESSAGING_MESSAGESV1) do() -> RestApiResponse:
    return RestApiResponse.ok()

  router.api(MethodPost, ROUTE_MESSAGING_MESSAGESV1) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Sends a message through the messaging client, returning the request id.
    let req: MessagingJsonEnvelope = decodeRequestBody[MessagingJsonEnvelope](
      contentBody
    ).valueOr:
      return error

    let envelope = req.toMessageEnvelope().valueOr:
      return RestApiResponse.badRequest("Invalid message: " & error)

    let requestId = (await client.send(envelope)).valueOr:
      error "Messaging SEND failed", error = error
      return RestApiResponse.internalServerError("Send failed: " & error)

    let data = MessagingSendResponse(requestId: $requestId)
    return RestApiResponse.jsonResponse(data, status = Http200).valueOr:
      error "An error occurred while building the json response", error = error
      return RestApiResponse.internalServerError($error)

  #### Event observability endpoints (poll-based, evict-after-poll)

  router.api(MethodOptions, ROUTE_MESSAGING_EVENTS_SENDV1) do() -> RestApiResponse:
    return RestApiResponse.ok()

  router.api(MethodGet, ROUTE_MESSAGING_EVENTS_SENDV1) do() -> RestApiResponse:
    ## Returns all buffered send events grouped by request id, then clears them.
    let data = eventCache.pollAllSend()
    return RestApiResponse.jsonResponse(data, status = Http200).valueOr:
      error "An error occurred while building the json response", error = error
      return RestApiResponse.internalServerError($error)

  router.api(MethodOptions, ROUTE_MESSAGING_EVENTS_SEND_BY_IDV1) do(
    requestId: string
  ) -> RestApiResponse:
    return RestApiResponse.ok()

  router.api(MethodGet, ROUTE_MESSAGING_EVENTS_SEND_BY_IDV1) do(
    requestId: string
  ) -> RestApiResponse:
    ## Returns the buffered send events for one request id, then removes them.
    let reqId = requestId.valueOr:
      return RestApiResponse.badRequest("Invalid requestId")

    let status = eventCache.pollSend(reqId).valueOr:
      return RestApiResponse.notFound("No send events for requestId: " & reqId)

    return RestApiResponse.jsonResponse(status, status = Http200).valueOr:
      error "An error occurred while building the json response", error = error
      return RestApiResponse.internalServerError($error)

  router.api(MethodOptions, ROUTE_MESSAGING_EVENTS_RECEIVEDV1) do() -> RestApiResponse:
    return RestApiResponse.ok()

  router.api(MethodGet, ROUTE_MESSAGING_EVENTS_RECEIVEDV1) do() -> RestApiResponse:
    ## Returns buffered received messages (up to the cache capacity, oldest
    ## first), then clears them — optimized for polling.
    let data = eventCache.pollReceived()
    return RestApiResponse.jsonResponse(data, status = Http200).valueOr:
      error "An error occurred while building the json response", error = error
      return RestApiResponse.internalServerError($error)

proc mountRestApi*(client: MessagingClient) =
  ## Mounts the messaging REST endpoints onto the kernel-owned REST router, if
  ## the REST server is enabled. Called by the `LogosDelivery` concentrator
  ## after the messaging layer has started. Lives here (not in the core
  ## `messaging_client` module) so the core need not depend on the REST layer
  ## above it — that would form an import cycle.
  if not client.waku.restServer.isNil():
    # The BTree route table is ref-backed, so mutating the copied router persists
    # (same pattern as the waku REST builder).
    var router = client.waku.restServer.router
    installMessagingApiHandlers(router, client)
    info "Mounted messaging REST API endpoints"

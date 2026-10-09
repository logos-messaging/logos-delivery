{.push raises: [].}

import
  std/[algorithm, sets],
  chronos,
  chronicles,
  results,
  json_serialization,
  json_serialization/std/options
import presto/[route, common]
import
  logos_delivery/waku/waku,
  logos_delivery/waku/api/subscriptions,
  rest/serdes,
  rest/responses,
  rest/rest_serdes,
  logos_delivery/messaging/messaging_client,
  logos_delivery/messaging/api/subscription,
  logos_delivery/messaging/api/send,
  logos_delivery/messaging/delivery_service/send_service,
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  rest/messaging_api/types,
  rest/messaging_api/event_cache

export types

logScope:
  topics = "messaging rest api"

#### Routes

const ROUTE_MESSAGING_SUBSCRIPTIONSV1* = "/messaging/v1/subscriptions"
const ROUTE_MESSAGING_MESSAGESV1* = "/messaging/v1/messages"
const ROUTE_MESSAGING_EVENTS_SENDV1* = "/messaging/v1/events/send"
const ROUTE_MESSAGING_EVENTS_SEND_BY_IDV1* = "/messaging/v1/events/send/{requestId}"
const ROUTE_MESSAGING_EVENTS_RECEIVEDV1* = "/messaging/v1/events/received"

const AutoshardingRequiredMsg =
  "autosharding is not configured: content-topic subscriptions and sends need --preset or --num-shards-in-network"

const SendQueueFullMsg = "Send queue full, retry later"

const SendQueueFullRetryAfterSec = "1"
  ## The send service removes finished tasks from its queue once per second.

proc validateContentTopics(topics: openArray[ContentTopic]): Result[void, string] =
  ## Rejects a content topic that autosharding cannot resolve.
  for topic in topics:
    let parsed = NsContentTopic.parse(topic)
    if parsed.isErr():
      return err("invalid content topic: '" & topic & "': " & $parsed.error)
    # Autosharding resolves generation 0 only (sharding.getShard).
    if parsed.get().generation.get(0) != 0:
      return err(
        "unsupported content topic generation in: '" & topic &
          "': only generation 0 is supported"
      )
  return ok()

proc installMessagingApiHandlers*(
    router: var RestRouter, client: MessagingClient, eventCache: MessagingEventCache
) =
  ## Mounts the MessagingClient subscribe / unsubscribe / send operations as
  ## REST endpoints onto the given (kernel-owned) router. Subscriptions are
  ## keyed by content topic, matching the messaging layer's content-topic API.
  ## `eventCache` backs the event endpoints.

  # Event observability: buffer send/received events for the poll-based GETs.
  # The routes and the cache are installed once; the listeners feeding the
  # cache are the `MessagingRestService`, started and stopped with it.

  # Without autosharding, content topics resolve to no shard: answer 503.
  let autoshardingConfigured = client.waku.isAutoshardingConfigured()
  if not autoshardingConfigured:
    warn "Messaging REST API mounted without autosharding; subscribe and send will be refused",
      hint = "set --preset or --num-shards-in-network"

  router.api(MethodOptions, ROUTE_MESSAGING_SUBSCRIPTIONSV1) do() -> RestApiResponse:
    return RestApiResponse.ok()

  router.api(MethodGet, ROUTE_MESSAGING_SUBSCRIPTIONSV1) do() -> RestApiResponse:
    ## Returns the content topics that the messaging client subscribes to, sorted.
    var topics: seq[ContentTopic]
    for (_, contentTopics) in client.waku.subscribedContentTopics():
      for contentTopic in contentTopics:
        topics.add(contentTopic)
    topics.sort()
    return RestApiResponse.jsonResponse(topics, status = Http200).valueOr:
      error "An error occurred while building the json response", error = error
      return RestApiResponse.internalServerError($error)

  router.api(MethodPost, ROUTE_MESSAGING_SUBSCRIPTIONSV1) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Subscribes the messaging client to a list of content topics.
    let req: seq[ContentTopic] = decodeRequestBody[seq[ContentTopic]](contentBody).valueOr:
      return error

    validateContentTopics(req).isOkOr:
      return RestApiResponse.badRequest(error)

    if not autoshardingConfigured:
      return RestApiResponse.serviceUnavailable(AutoshardingRequiredMsg)

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

    validateContentTopics(req).isOkOr:
      return RestApiResponse.badRequest(error)

    if not autoshardingConfigured:
      return RestApiResponse.serviceUnavailable(AutoshardingRequiredMsg)

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

    validateContentTopics([envelope.contentTopic]).isOkOr:
      return RestApiResponse.badRequest("Invalid message: " & error)

    if not autoshardingConfigured:
      return RestApiResponse.serviceUnavailable(AutoshardingRequiredMsg)

    if client.sendService.isFull():
      debug "Messaging SEND rejected, the send queue is full"
      return RestApiResponse.error(
        Http429,
        SendQueueFullMsg,
        $MIMETYPE_TEXT,
        [("Retry-After", SendQueueFullRetryAfterSec)],
      )

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

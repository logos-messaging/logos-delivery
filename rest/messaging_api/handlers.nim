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
const ROUTE_MESSAGING_EVENTS_SEND_BY_HASHV1* = "/messaging/v1/events/send/{messageHash}"
const ROUTE_MESSAGING_EVENTS_RECEIVEDV1* = "/messaging/v1/events/received"

const AutoshardingRequiredMsg =
  "autosharding is not configured: content-topic subscriptions and sends need --preset or --num-shards-in-network"

const SendQueueFullRetryAfterSec = "1"
  ## A send leaves the send queue at its last event. A send that waits for a
  ## retry tries again at the next tick of `retryLoop`, at most
  ## `RetryInterval` (1 s) later.

proc refusedSendResponse(error: SendError): RestApiResponse =
  ## The HTTP answer to a send that `send` refused.
  let text = "Send refused: " & $error
  case error.kind
  of SendErrorKind.NotStarted, SendErrorKind.NotConnected:
    return RestApiResponse.serviceUnavailable(text)
  of SendErrorKind.NoShard:
    return RestApiResponse.badRequest(text)
  of SendErrorKind.TooLarge:
    return RestApiResponse.error(Http413, text, $MIMETYPE_TEXT)
  of SendErrorKind.QueueFull:
    return RestApiResponse.error(
      Http429, text, $MIMETYPE_TEXT, [("Retry-After", SendQueueFullRetryAfterSec)]
    )
  of SendErrorKind.RateLimited:
    let retryAfterSec = max(1'i64, error.retryAfter.seconds())
    return RestApiResponse.error(
      Http429, text, $MIMETYPE_TEXT, [("Retry-After", $retryAfterSec)]
    )

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
  # cache are the `MessagingRestEvents`, started and stopped with it.

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
    ## Sends a message through the messaging client, returning its message hash.
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

    let msgHash = (await client.send(envelope)).valueOr:
      debug "Messaging SEND refused", error = $error
      return refusedSendResponse(error)

    let data = MessagingSendResponse(messageHash: msgHash.to0xHex())
    return RestApiResponse.jsonResponse(data, status = Http200).valueOr:
      error "An error occurred while building the json response", error = error
      return RestApiResponse.internalServerError($error)

  #### Event observability endpoints (poll-based, evict-after-poll)

  router.api(MethodOptions, ROUTE_MESSAGING_EVENTS_SENDV1) do() -> RestApiResponse:
    return RestApiResponse.ok()

  router.api(MethodGet, ROUTE_MESSAGING_EVENTS_SENDV1) do() -> RestApiResponse:
    ## Returns all buffered send events grouped by message hash, then clears them.
    let data = eventCache.pollAllSend()
    return RestApiResponse.jsonResponse(data, status = Http200).valueOr:
      error "An error occurred while building the json response", error = error
      return RestApiResponse.internalServerError($error)

  router.api(MethodOptions, ROUTE_MESSAGING_EVENTS_SEND_BY_HASHV1) do(
    messageHash: string
  ) -> RestApiResponse:
    return RestApiResponse.ok()

  router.api(MethodGet, ROUTE_MESSAGING_EVENTS_SEND_BY_HASHV1) do(
    messageHash: string
  ) -> RestApiResponse:
    ## Returns the buffered send events for one message hash, then removes them.
    let hash = messageHash.valueOr:
      return RestApiResponse.badRequest("Invalid messageHash")
    let digest = hexToHash(hash).valueOr:
      return
        RestApiResponse.badRequest("messageHash is not a hex hash of 32 bytes: " & hash)

    let status = eventCache.pollSend(digest.to0xHex()).valueOr:
      return RestApiResponse.notFound("No send events for messageHash: " & hash)

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

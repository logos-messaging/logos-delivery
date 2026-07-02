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
  ./types

export types

logScope:
  topics = "messaging rest api"

#### Routes

const ROUTE_MESSAGING_SUBSCRIPTIONSV1* = "/messaging/v1/subscriptions"
const ROUTE_MESSAGING_MESSAGESV1* = "/messaging/v1/messages"

proc installMessagingApiHandlers*(router: var RestRouter, client: MessagingClient) =
  ## Mounts the MessagingClient subscribe / unsubscribe / send operations as
  ## REST endpoints onto the given (kernel-owned) router. Subscriptions are
  ## keyed by content topic, matching the messaging layer's content-topic API.

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
        error "messaging SUBSCRIBE failed", error = errorMsg
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
        error "messaging UNSUBSCRIBE failed", error = errorMsg
        return RestApiResponse.internalServerError(errorMsg)

    return RestApiResponse.ok()

  router.api(MethodOptions, ROUTE_MESSAGING_MESSAGESV1) do() -> RestApiResponse:
    return RestApiResponse.ok()

  router.api(MethodPost, ROUTE_MESSAGING_MESSAGESV1) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Sends a message through the messaging client, returning the request id.
    let req: MessagingMessage = decodeRequestBody[MessagingMessage](contentBody).valueOr:
      return error

    let envelope = req.toMessageEnvelope().valueOr:
      return RestApiResponse.badRequest("Invalid message: " & error)

    let requestId = (await client.send(envelope)).valueOr:
      error "messaging SEND failed", error = error
      return RestApiResponse.internalServerError("Send failed: " & error)

    let data = MessagingSendResponse(requestId: $requestId)
    return RestApiResponse.jsonResponse(data, status = Http200).valueOr:
      error "An error occurred while building the json response", error = error
      return RestApiResponse.internalServerError($error)

proc mountRestApi*(client: MessagingClient) =
  ## Mounts the messaging REST endpoints onto the kernel-owned REST router, if
  ## the REST server is enabled. Called by the `LogosDelivery` concentrator
  ## after the messaging layer has started. Lives here (not in the core
  ## `messaging_client` module) so the core need not depend on the REST layer
  ## above it — that would form an import cycle.
  if client.waku.restServer.isNil():
    return
  # The BTree route table is ref-backed, so mutating the copied router persists
  # (same pattern as the waku REST builder).
  var router = client.waku.restServer.router
  installMessagingApiHandlers(router, client)
  info "Mounted messaging REST API endpoints"

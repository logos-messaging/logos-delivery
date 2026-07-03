{.push raises: [].}

import chronicles, json_serialization, presto/[route, client, common]
import
  logos_delivery/waku/rest_api/endpoint/serdes,
  logos_delivery/waku/rest_api/endpoint/rest_serdes,
  logos_delivery/api/types,
  ./types

export types

logScope:
  topics = "messaging rest client"

proc encodeBytes*(
    value: seq[ContentTopic], contentType: string
): RestResult[seq[byte]] =
  return encodeBytesOf(value, contentType)

proc encodeBytes*(
    value: MessagingPostMessageRequest, contentType: string
): RestResult[seq[byte]] =
  return encodeBytesOf(value, contentType)

proc messagingPostSubscriptionsV1*(
  body: seq[ContentTopic]
): RestResponse[string] {.
  rest, endpoint: "/messaging/v1/subscriptions", meth: HttpMethod.MethodPost
.}

proc messagingDeleteSubscriptionsV1*(
  body: seq[ContentTopic]
): RestResponse[string] {.
  rest, endpoint: "/messaging/v1/subscriptions", meth: HttpMethod.MethodDelete
.}

proc messagingPostMessagesV1*(
  body: MessagingPostMessageRequest
): RestResponse[MessagingSendResponse] {.
  rest, endpoint: "/messaging/v1/messages", meth: HttpMethod.MethodPost
.}

proc messagingGetSendEventsV1*(): RestResponse[seq[SendStatus]] {.
  rest, endpoint: "/messaging/v1/events/send", meth: HttpMethod.MethodGet
.}

proc messagingGetSendEventsByIdV1*(
  requestId: string
): RestResponse[SendStatus] {.
  rest, endpoint: "/messaging/v1/events/send/{requestId}", meth: HttpMethod.MethodGet
.}

# Raw variant: the typed client above cannot decode a non-2xx text error body,
# so status-code assertions (e.g. 404) use this string form.
proc messagingGetSendEventsByIdRawV1*(
  requestId: string
): RestResponse[string] {.
  rest, endpoint: "/messaging/v1/events/send/{requestId}", meth: HttpMethod.MethodGet
.}

proc messagingGetReceivedMessagesV1*(): RestResponse[seq[ReceivedMessageRecord]] {.
  rest, endpoint: "/messaging/v1/events/received", meth: HttpMethod.MethodGet
.}

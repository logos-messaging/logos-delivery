{.push raises: [].}

import
  json,
  stew/byteutils,
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client, common]
import ../../../common/base64, ../serdes, ../rest_serdes, ./types

export types

logScope:
  topics = "waku node rest client v2"

proc encodeBytes*(
    value: FilterSubscribeRequest, contentType: string
): RestResult[seq[byte]] =
  return encodeBytesOf(value, contentType)

proc encodeBytes*(
    value: FilterSubscriberPing, contentType: string
): RestResult[seq[byte]] =
  return encodeBytesOf(value, contentType)

proc encodeBytes*(
    value: FilterUnsubscribeRequest, contentType: string
): RestResult[seq[byte]] =
  return encodeBytesOf(value, contentType)

proc encodeBytes*(
    value: FilterUnsubscribeAllRequest, contentType: string
): RestResult[seq[byte]] =
  return encodeBytesOf(value, contentType)

proc filterSubscriberPing*(
  requestId: string
): RestResponse[FilterSubscriptionResponse] {.
  rest, endpoint: "/filter/v2/subscriptions/{requestId}", meth: HttpMethod.MethodGet
.}

proc filterPostSubscriptions*(
  body: FilterSubscribeRequest
): RestResponse[FilterSubscriptionResponse] {.
  rest, endpoint: "/filter/v2/subscriptions", meth: HttpMethod.MethodPost
.}

proc filterPutSubscriptions*(
  body: FilterSubscribeRequest
): RestResponse[FilterSubscriptionResponse] {.
  rest, endpoint: "/filter/v2/subscriptions", meth: HttpMethod.MethodPut
.}

proc filterDeleteSubscriptions*(
  body: FilterUnsubscribeRequest
): RestResponse[FilterSubscriptionResponse] {.
  rest, endpoint: "/filter/v2/subscriptions", meth: HttpMethod.MethodDelete
.}

proc filterDeleteAllSubscriptions*(
  body: FilterUnsubscribeAllRequest
): RestResponse[FilterSubscriptionResponse] {.
  rest, endpoint: "/filter/v2/subscriptions/all", meth: HttpMethod.MethodDelete
.}

proc filterGetMessagesV1*(
  contentTopic: string
): RestResponse[FilterGetMessagesResponse] {.
  rest, endpoint: "/filter/v2/messages/{contentTopic}", meth: HttpMethod.MethodGet
.}

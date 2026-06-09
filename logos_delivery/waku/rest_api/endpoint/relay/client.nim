{.push raises: [].}

import stew/byteutils, chronicles, json_serialization, presto/[route, client, common]
import ../../../waku_core, ../serdes, ../rest_serdes, ./types

export types

logScope:
  topics = "waku node rest client"

proc encodeBytes*(value: seq[PubSubTopic], contentType: string): RestResult[seq[byte]] =
  return encodeBytesOf(value, contentType)

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc relayPostSubscriptionsV1*(
  body: seq[PubsubTopic]
): RestResponse[string] {.
  rest, endpoint: "/relay/v1/subscriptions", meth: HttpMethod.MethodPost
.}

proc relayPostAutoSubscriptionsV1*(
  body: seq[ContentTopic]
): RestResponse[string] {.
  rest, endpoint: "/relay/v1/auto/subscriptions", meth: HttpMethod.MethodPost
.}

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc relayDeleteSubscriptionsV1*(
  body: seq[PubsubTopic]
): RestResponse[string] {.
  rest, endpoint: "/relay/v1/subscriptions", meth: HttpMethod.MethodDelete
.}

proc relayDeleteAutoSubscriptionsV1*(
  body: seq[ContentTopic]
): RestResponse[string] {.
  rest, endpoint: "/relay/v1/auto/subscriptions", meth: HttpMethod.MethodDelete
.}

proc encodeBytes*(
    value: RelayPostMessagesRequest, contentType: string
): RestResult[seq[byte]] =
  return encodeBytesOf(value, contentType)

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc relayGetMessagesV1*(
  pubsubTopic: string
): RestResponse[RelayGetMessagesResponse] {.
  rest, endpoint: "/relay/v1/messages/{pubsubTopic}", meth: HttpMethod.MethodGet
.}

proc relayGetAutoMessagesV1*(
  contentTopic: string
): RestResponse[RelayGetMessagesResponse] {.
  rest, endpoint: "/relay/v1/auto/messages/{contentTopic}", meth: HttpMethod.MethodGet
.}

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc relayPostMessagesV1*(
  pubsubTopic: string, body: RelayPostMessagesRequest
): RestResponse[string] {.
  rest, endpoint: "/relay/v1/messages/{pubsubTopic}", meth: HttpMethod.MethodPost
.}

proc relayPostAutoMessagesV1*(
  body: RelayPostMessagesRequest
): RestResponse[string] {.
  rest, endpoint: "/relay/v1/auto/messages", meth: HttpMethod.MethodPost
.}

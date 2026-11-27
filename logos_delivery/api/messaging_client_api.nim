import chronos, results
import brokers/[request_broker, broker_context]
import logos_delivery/api/types as api_types
from logos_delivery/waku/waku_core/time import Timestamp

export api_types, request_broker, broker_context, Timestamp

# Structural API contract for a messaging client (ops in `messaging/api/*`).
type MessagingApi* = concept c
  subscribe(c, contentTopic = ContentTopic, startTime = Opt[Timestamp]) is
    Future[Result[void, string]]
  unsubscribe(c, contentTopic = ContentTopic) is Result[void, string]
  send(c, envelope = MessageEnvelope) is Future[Result[WakuMessageHash, SendError]]

# Semi detached MessagingClient send interface.
# Can be used without MessagingClient, under the same context of MessagingClient instance.
# A broker error is a string, so a refusal arrives as the text of its `SendError`.
RequestBroker:
  proc MessagingSend(
    envelope: MessageEnvelope
  ): Future[Result[WakuMessageHash, string]] {.async.}

# Semi detached MessagingClient subscription interface, same pattern as MessagingSend.
RequestBroker(sync):
  proc MessagingSubscribe(contentTopic: ContentTopic): Result[void, string]

RequestBroker(sync):
  proc MessagingUnsubscribe(contentTopic: ContentTopic): Result[void, string]

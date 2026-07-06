import chronos, results
import brokers/[request_broker, broker_context]
import logos_delivery/api/types as api_types

export api_types, request_broker, broker_context

# Structural API contract for a messaging client (ops in `messaging/api/*`).
type MessagingApi* = concept c
  subscribe(c, contentTopic = ContentTopic) is Future[Result[void, string]]
  unsubscribe(c, contentTopic = ContentTopic) is Result[void, string]
  send(c, envelope = MessageEnvelope) is Future[Result[RequestId, string]]

# Semi detached MessagingClient send interface.
# Can be used without MessagingClient, under the same context of MessagingClient instance.
RequestBroker:
  proc MessagingSend(
    envelope: MessageEnvelope
  ): Future[Result[RequestId, string]] {.async.}

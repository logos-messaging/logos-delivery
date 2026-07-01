import brokers/[request_broker, broker_context]
import logos_delivery/api/types as api_types

export api_types, request_broker, broker_context

# Semi detached MessagingClient send interface.
# Can be used without MessagingClient, under the same context of MessagingClient instance.
RequestBroker:
  proc MessagingSend(
    envelope: MessageEnvelope
  ): Future[Result[RequestId, string]] {.async.}

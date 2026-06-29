import chronos, results

import logos_delivery/api/types as api_types

export api_types

# Structural API contract for a messaging client (ops in `messaging/api/*`).
type MessagingApi* = concept c
  subscribe(c, contentTopic = ContentTopic) is Future[Result[void, string]]
  unsubscribe(c, contentTopic = ContentTopic) is Result[void, string]
  send(c, envelope = MessageEnvelope) is Future[Result[RequestId, string]]

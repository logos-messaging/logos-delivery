import chronos, results

import logos_delivery/api/types as api_types

export api_types

type MessagingSender* = concept c
  ## The narrow egress capability the reliable-channel layer depends on: just
  ## `send`. A layer above messaging depends on this capability, not on the
  ## concrete `MessagingClient`. Dot-call form (`c.send(...)`) so it is
  ## satisfied by both a real `send` proc (the production `MessagingClient`)
  ## and a `send` proc-typed field (a test double).
  c.send(MessageEnvelope) is Future[Result[RequestId, string]]

# Structural API contract for a messaging client (ops in `messaging/api/*`).
# Refines `MessagingSender`, so the send capability is stated once.
type MessagingApi* = concept c
  c is MessagingSender
  subscribe(c, contentTopic = ContentTopic) is Future[Result[void, string]]
  unsubscribe(c, contentTopic = ContentTopic) is Result[void, string]

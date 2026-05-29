## Optional encryption hooks for the Reliable Channel API.
##
## Modelled as `RequestBroker`s: the broker pattern lets the channel
## delegate work to a provider that may live in any module without
## introducing a direct dependency. If no provider is registered the
## broker returns an error, so installing the noop providers from
## `noop_encryption` is required when the application does not want
## actual encryption.
##
## Applied per-segment after SDS processing on outgoing, and before
## SDS processing on incoming. No specific scheme is mandated.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import brokers/request_broker

export request_broker

RequestBroker:
  type Encrypt* = seq[byte]
  proc signature*(payload: seq[byte]): Future[Result[Encrypt, string]] {.async.}

RequestBroker:
  type Decrypt* = seq[byte]
  proc signature*(payload: seq[byte]): Future[Result[Decrypt, string]] {.async.}

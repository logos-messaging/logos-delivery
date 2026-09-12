## Messaging layer counters.
##
## A send that no store node validates in time is logged at DEBUG, and a
## received message is logged at INFO; these counters are what makes both
## visible in aggregate, with receipts split by where the message came from.
##
## Label cardinality is bounded by construction: the recorder below takes the
## package's enum rather than a string, so `source` can only ever be one of the
## two `MessageSource` values (Live, History). Four series in total, and
## nothing a peer sends can reach a label.

{.push raises: [].}

import metrics
import logos_delivery/api/types

declarePublicCounter logos_delivery_send_store_validation_timeout_total,
  "messages propagated but dropped without store-node validation within the retry window"
declarePublicCounter logos_delivery_recv_messages_total,
  "messages delivered to the application, live from the network or history from Store",
  ["source"]
declarePublicCounter logos_delivery_recv_message_bytes_total,
  "payload bytes of the messages delivered to the application, by source", ["source"]

proc recordStoreValidationTimeout*() =
  logos_delivery_send_store_validation_timeout_total.inc()

proc recordReceived*(source: MessageSource, payloadBytes: int) =
  logos_delivery_recv_messages_total.inc(labelValues = [$source])
  logos_delivery_recv_message_bytes_total.inc(
    payloadBytes.int64, labelValues = [$source]
  )

{.pop.}

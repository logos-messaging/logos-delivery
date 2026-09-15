## Messaging layer counters.
##
## Label cardinality is bounded by construction: `recordReceived` takes the
## `MessageSource` enum rather than a string, so `source` can only ever be
## `live` or `history`. Four receive series in total, plus the send counter.

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

# A labelled series exists from its first increment. Start every source at zero,
# so the series are scraped before the first message and can be read at any time.
for source in MessageSource:
  logos_delivery_recv_messages_total.inc(0, labelValues = [$source])
  logos_delivery_recv_message_bytes_total.inc(0, labelValues = [$source])

proc recordStoreValidationTimeout*() =
  logos_delivery_send_store_validation_timeout_total.inc()

proc recordReceived*(source: MessageSource, payloadBytes: int) =
  logos_delivery_recv_messages_total.inc(labelValues = [$source])
  logos_delivery_recv_message_bytes_total.inc(
    payloadBytes.int64, labelValues = [$source]
  )

{.pop.}

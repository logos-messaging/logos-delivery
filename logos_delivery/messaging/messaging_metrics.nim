## Messaging layer counters.
##
## Label cardinality is bounded by construction: `recordReceived` takes the
## `MessageSource` enum rather than a string, so `source` can only ever be
## `live` or `history`. Four receive series in total, plus the send counter.
## The mix counters take `MixUnusable`, `LightPushStatusCode` or one of the
## constants below, so their label sets are fixed too.
##
## nim-metrics appends `_total` to each counter name on export.

{.push raises: [].}

import metrics
import logos_delivery/api/types, logos_delivery/waku/waku_core/metric_labels
import logos_delivery/waku/node/health_monitor/mix_readiness
import logos_delivery/waku/waku_lightpush/common

declarePublicCounter logos_delivery_send_store_validation_timeouts,
  "messages propagated but failed without store-node validation within the retry window"
declarePublicCounter logos_delivery_recv_messages,
  "messages delivered to the application, live from the network or history from Store",
  ["source"]
declarePublicCounter logos_delivery_recv_message_bytes,
  "payload bytes of the messages delivered to the application, by source", ["source"]
declarePublicCounter logos_delivery_mix_fallbacks,
  "Preferred send tasks handed from mix to the plain path, by reason", ["reason"]
declarePublicCounter logos_delivery_mix_send_attempts,
  "mix send attempts, by result", ["result"]

const
  MixFallbackMsgSize* = "MsgSizeExceeded"
  MixFallbackWindowElapsed* = "WindowElapsed"
  MixAttemptPropagated* = "Propagated"
  MixAttemptExitNoRelayPeers* = "ExitNoRelayPeers"

# A labelled series exists from its first increment. Start every source at zero,
# so the series are scraped before the first message and can be read at any time.
for source in MessageSource:
  logos_delivery_recv_messages.inc(0, labelValues = [enumLabel(source)])
  logos_delivery_recv_message_bytes.inc(0, labelValues = [enumLabel(source)])
for unusable in MixUnusable:
  if unusable != MixUnusable.None:
    logos_delivery_mix_fallbacks.inc(0, labelValues = [enumLabel(unusable)])
for reason in [MixFallbackMsgSize, MixFallbackWindowElapsed]:
  logos_delivery_mix_fallbacks.inc(0, labelValues = [reason])
for outcome in [MixAttemptPropagated, MixAttemptExitNoRelayPeers]:
  logos_delivery_mix_send_attempts.inc(0, labelValues = [outcome])
for code in LightPushErrorCode.fields:
  logos_delivery_mix_send_attempts.inc(0, labelValues = [statusLabel(code)])

proc recordStoreValidationTimeout*() =
  logos_delivery_send_store_validation_timeouts.inc()

proc recordReceived*(source: MessageSource, payloadBytes: int) =
  logos_delivery_recv_messages.inc(labelValues = [enumLabel(source)])
  logos_delivery_recv_message_bytes.inc(
    payloadBytes.int64, labelValues = [enumLabel(source)]
  )

proc recordMixFallback*(unusable: MixUnusable) =
  logos_delivery_mix_fallbacks.inc(labelValues = [enumLabel(unusable)])

proc recordMixFallback*(reason: string) =
  logos_delivery_mix_fallbacks.inc(labelValues = [reason])

proc recordMixAttempt*(outcome: string) =
  logos_delivery_mix_send_attempts.inc(labelValues = [outcome])

proc recordMixAttempt*(code: LightPushStatusCode) =
  logos_delivery_mix_send_attempts.inc(labelValues = [statusLabel(code)])

{.pop.}

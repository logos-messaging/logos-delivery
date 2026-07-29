## Example showing how a resource restricted client may
## subscribe to messages without relay

import metrics

export metrics

declarePublicGauge logos_delivery_lpt_receiver_sender_peer_count,
  "count of sender peers"

declarePublicCounter logos_delivery_lpt_receiver_received_messages_count,
  "number of messages received per peer", ["peer"]

declarePublicCounter logos_delivery_lpt_receiver_received_bytes,
  "number of received bytes per peer", ["peer"]

declarePublicGauge logos_delivery_lpt_receiver_missing_messages_count,
  "number of missing messages per peer", ["peer"]

declarePublicCounter logos_delivery_lpt_receiver_duplicate_messages_count,
  "number of duplicate messages per peer", ["peer"]

declarePublicGauge logos_delivery_lpt_receiver_distinct_duplicate_messages_count,
  "number of distinct duplicate messages per peer", ["peer"]

declarePublicGauge logos_delivery_lpt_receiver_latencies,
  "Message delivery latency per peer (min-avg-max)", ["peer", "latency"]

declarePublicCounter logos_delivery_lpt_receiver_lost_subscription_count,
  "number of filter service peer failed PING requests - lost subscription"

declarePublicCounter logos_delivery_lpt_publisher_sent_messages_count,
  "number of messages published"

declarePublicCounter logos_delivery_lpt_publisher_failed_messages_count,
  "number of messages failed to publish per failure cause", ["cause"]

declarePublicCounter logos_delivery_lpt_publisher_sent_bytes,
  "number of total bytes sent"

declarePublicCounter logos_delivery_lpt_service_peer_failure_count,
  "number of failure during using service peer [publisher/receiever]", ["role", "agent"]

declarePublicCounter logos_delivery_lpt_change_service_peer_count,
  "number of times [publisher/receiver] had to change service peer", ["role"]

declarePublicGauge logos_delivery_lpt_px_peers,
  "Number of peers PeerExchange discovered and can be dialed"

declarePublicGauge logos_delivery_lpt_dialed_peers,
  "Number of peers successfully dialed", ["agent"]

declarePublicGauge logos_delivery_lpt_dial_failures,
  "Number of dial failures by cause", ["agent"]

declarePublicHistogram logos_delivery_lpt_publish_duration_seconds,
  "duration to lightpush messages",
  buckets = [
    0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0,
    15.0, 20.0, 30.0, Inf,
  ]

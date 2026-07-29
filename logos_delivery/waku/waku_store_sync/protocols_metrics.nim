import metrics

const
  Reconciliation* = "reconciliation"
  Transfer* = "transfer"
  Receiving* = "receive"
  Sending* = "sent"

declarePublicHistogram logos_delivery_reconciliation_roundtrips,
  "the nubmer of roundtrips for each reconciliation",
  buckets = [1.0, 2.0, 3.0, 5.0, 8.0, 13.0, Inf]

declarePublicHistogram logos_delivery_reconciliation_differences,
  "the nubmer of differences for each reconciliation",
  buckets = [0.0, 10.0, 50.0, 100.0, 500.0, 1000.0, 5000.0, Inf]

declarePublicCounter logos_delivery_total_bytes_exchanged,
  "the number of bytes sent and received by the protocols", ["protocol", "direction"]

declarePublicCounter logos_delivery_total_transfer_messages_exchanged,
  "the number of messages sent and received by the transfer protocol", ["direction"]

declarePublicGauge logos_delivery_total_messages_cached,
  "the number of messages cached by the node after prunning"

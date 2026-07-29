{.push raises: [].}

import metrics

declarePublicGauge logos_delivery_version,
  "Waku version info (in git describe format)", ["version"]

declarePublicCounter logos_delivery_node_errors, "number of wakunode errors", ["type"]

declarePublicGauge logos_delivery_lightpush_peers, "number of lightpush peers"

declarePublicGauge logos_delivery_filter_peers, "number of filter peers"

declarePublicGauge logos_delivery_store_peers, "number of store peers"

declarePublicGauge logos_delivery_px_peers,
  "number of peers (in the node's peerManager) supporting the peer exchange protocol"

declarePublicCounter logos_delivery_node_messages,
  "number of messages received", ["type"]

declarePublicHistogram logos_delivery_histogram_message_size,
  "message size histogram in kB",
  buckets = [
    0.0, 1.0, 3.0, 5.0, 15.0, 50.0, 75.0, 100.0, 125.0, 150.0, 500.0, 700.0, 1000.0, Inf
  ]

{.pop.}

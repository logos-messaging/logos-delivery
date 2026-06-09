{.push raises: [].}

import metrics

declarePublicGauge waku_version,
  "Waku version info (in git describe format)", ["version"]

declarePublicCounter waku_node_errors, "number of wakunode errors", ["type"]

declarePublicGauge waku_lightpush_peers, "number of lightpush peers"

declarePublicGauge waku_filter_peers, "number of filter peers"

declarePublicGauge waku_store_peers, "number of store peers"

declarePublicGauge waku_px_peers,
  "number of peers (in the node's peerManager) supporting the peer exchange protocol"

declarePublicCounter waku_node_messages, "number of messages received", ["type"]

declarePublicHistogram waku_histogram_message_size,
  "message size histogram in kB",
  buckets = [
    0.0, 1.0, 3.0, 5.0, 15.0, 50.0, 75.0, 100.0, 125.0, 150.0, 500.0, 700.0, 1000.0, Inf
  ]

{.pop.}

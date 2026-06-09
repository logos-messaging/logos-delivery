{.push raises: [].}

import metrics

declarePublicCounter waku_store_errors, "number of store protocol errors", ["type"]
declarePublicCounter waku_store_queries, "number of store queries received"

## "query-db-time" phase considers the time when node performs the query to the database.
## "send-store-resp-time" phase is the time when node writes the store response to the store-client.
declarePublicGauge waku_store_time_seconds,
  "Time in seconds spent by each store phase", labels = ["phase"]

declarePublicGauge(
  waku_relay_fleet_store_msg_size_bytes,
  "Total size of messages stored by fleet store nodes per shard",
  labels = ["shard"],
)

declarePublicGauge(
  waku_relay_fleet_store_msg_count,
  "Number of messages stored by fleet store nodes per shard",
  labels = ["shard"],
)

# Error types (metric label values)
const
  DialFailure* = "dial_failure"
  DecodeRpcFailure* = "decode_rpc_failure"
  PeerNotFoundFailure* = "peer_not_found_failure"
  EmptyRpcQueryFailure* = "empty_rpc_query_failure"
  EmptyRpcResponseFailure* = "empty_rpc_response_failure"
  NoSuccessStatusCode* = "status_code_no_success"

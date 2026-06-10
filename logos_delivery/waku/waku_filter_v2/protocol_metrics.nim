{.push raises: [].}

import metrics

export metrics

declarePublicCounter waku_filter_errors, "number of filter protocol errors", ["type"]
declarePublicCounter waku_filter_requests,
  "number of filter subscribe requests received", ["type"]
declarePublicGauge waku_filter_subscriptions, "number of subscribed filter clients"
declarePublicHistogram waku_filter_request_duration_seconds,
  "duration of filter subscribe requests", ["type"]
declarePublicHistogram waku_filter_handle_message_duration_seconds,
  "duration to push message to filter subscribers",
  buckets = [
    0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0,
    15.0, 20.0, 30.0, Inf,
  ]

# Error types (metric label values)
const
  dialFailure* = "dial_failure"
  decodeRpcFailure* = "decode_rpc_failure"
  requestIdMismatch* = "request_id_mismatch"
  errorResponse* = "error_response"
  pushTimeoutFailure* = "push_timeout_failure"

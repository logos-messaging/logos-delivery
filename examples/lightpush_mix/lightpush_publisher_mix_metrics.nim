{.push raises: [].}

import metrics

declarePublicCounter lp_mix_success, "number of lightpush messages sent via mix"

declarePublicCounter lp_mix_failed,
  "number of lightpush messages failed via mix", labels = ["error"]

declarePublicHistogram lp_mix_latency,
  "lightpush publish latency via mix in milliseconds"

{.push raises: [].}

import metrics

proc parseCollectorIntoF64(collector: SimpleCollector): float64 {.gcsafe, raises: [].} =
  {.gcsafe.}:
    var total = 0.float64
    for metrics in collector.metrics:
      for metric in metrics:
        try:
          total = total + metric.value
        except KeyError:
          discard
    return total

template parseAndAccumulate*(collector: Collector, cumulativeValue: float64): float64 =
  ## This template is used to get metrics in a window 
  ## according to a cumulative value passed in
  {.gcsafe.}:
    let total = parseCollectorIntoF64(collector)
    let freshCount = total - cumulativeValue
    cumulativeValue = total
    freshCount

template parseAndAccumulate*(
    collector: typedesc[IgnoredCollector], cumulativeValue: float64
): float64 =
  ## Used when metrics are disabled (undefined `metrics` compilation flag)
  0.0

template collectorAsF64*(collector: Collector): float64 =
  ## This template is used to get metrics from 0
  ## Serves as a wrapper for parseCollectorIntoF64 which is gcsafe
  {.gcsafe.}:
    let total = parseCollectorIntoF64(collector)
    total

template collectorAsF64*(collector: typedesc[IgnoredCollector]): float64 =
  ## Used when metrics are disabled (undefined `metrics` compilation flag)
  0.0

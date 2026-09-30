{.used.}

import testutils/unittests, metrics
import logos_delivery/waku/utils/collector

declarePublicCounter test_collector_plain, "plain counter for collector tests"
declarePublicCounter test_collector_labelled,
  "labelled counter for collector tests", ["kind"]
declarePublicCounter test_collector_delta, "delta counter for collector tests"

suite "Utils - collector":
  test "fresh counter reads zero and ignores _created sample":
    check collectorAsF64(test_collector_plain) == 0.0

    test_collector_plain.inc(3)

    check collectorAsF64(test_collector_plain) == 3.0

  test "labelled counter sums all label values":
    test_collector_labelled.inc(2, labelValues = ["a"])
    test_collector_labelled.inc(5, labelValues = ["b"])

    check collectorAsF64(test_collector_labelled) == 7.0

  test "parseAndAccumulate returns the delta":
    var cumulative = 0.0

    test_collector_delta.inc(4)
    check parseAndAccumulate(test_collector_delta, cumulative) == 4.0

    test_collector_delta.inc(1)
    check:
      parseAndAccumulate(test_collector_delta, cumulative) == 1.0
      cumulative == 5.0

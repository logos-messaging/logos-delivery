{.used.}

import testutils/unittests
import logos_delivery/waku/waku_core/time

suite "Waku Core - Time":
  test "Test timestamp conversion":
    ## Given
    let
      nanoseconds = 1676562429123456789.int64
      secondsPart = nanoseconds div 1_000_000_000
      nanosecondsPart = nanoseconds mod 1_000_000_000
      secondsFloat =
        secondsPart.float64 + (nanosecondsPart.float64 / 1_000_000_000.float64)
      lowResTimestamp = Timestamp(secondsPart.int64 * 1_000_000_000.int64)
        # 1676562429000000000
      highResTimestamp = Timestamp(secondsFloat * 1_000_000_000.float64)
        # 1676562429123456789

    require highResTimestamp > lowResTimestamp # Sanity check

    ## When
    let
      timeInSecondsInt64 = secondsPart.int64
      timeInSecondsFloat64 = float64(secondsFloat)

    ## Then
    check:
      getNanosecondTime(timeInSecondsInt64) == lowResTimestamp
      getNanosecondTime(timeInSecondsFloat64) == highResTimestamp

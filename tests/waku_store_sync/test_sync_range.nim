{.used.}

import testutils/unittests, chronos, results
import ../../logos_delivery/waku/waku_store_sync/storage/range_processing

suite "Waku Sync: sync range clamping":
  const
    syncRange = 3600.seconds
    relayJitter = 20.seconds

  test "no time retention leaves the sync range unchanged":
    check clampSyncRange(syncRange, relayJitter, Opt.none(Duration)) == syncRange

  test "retention covering range plus jitter leaves the sync range unchanged":
    check clampSyncRange(syncRange, relayJitter, Opt.some(3620.seconds)) == syncRange

  test "retention one second short reduces the range to retention minus jitter":
    check clampSyncRange(syncRange, relayJitter, Opt.some(3619.seconds)) == 3599.seconds

  test "retention shorter than the range reduces the range to retention minus jitter":
    check clampSyncRange(syncRange, relayJitter, Opt.some(1800.seconds)) == 1780.seconds

  test "retention not larger than the jitter reduces the range to zero":
    check:
      clampSyncRange(syncRange, relayJitter, Opt.some(20.seconds)) == ZeroDuration
      clampSyncRange(syncRange, relayJitter, Opt.some(5.seconds)) == ZeroDuration

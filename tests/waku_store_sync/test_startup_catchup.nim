{.used.}

import testutils/unittests, chronos
import
  ../../logos_delivery/waku/node/waku_node, ../../logos_delivery/waku/waku_core/time

suite "Startup catch-up decision (store as a startup-only dependency)":
  const SyncRange = 1800.seconds # 30 min window
  let now = getNowInNanosecondTime()

  test "gap within the sync window uses reconciliation":
    let lastOnline = now - 300 * 1_000_000_000'i64 # 5 min ago

    check useSyncCatchUp(true, lastOnline, now, SyncRange)

  test "gap at the window boundary uses reconciliation":
    let lastOnline = now - 1800 * 1_000_000_000'i64

    check useSyncCatchUp(true, lastOnline, now, SyncRange)

  test "gap beyond the sync window falls back to store resume":
    let lastOnline = now - 2700 * 1_000_000_000'i64 # 45 min ago

    check not useSyncCatchUp(true, lastOnline, now, SyncRange)

  test "fresh start (no last-online record) falls back to store resume":
    check not useSyncCatchUp(true, Timestamp(0), now, SyncRange)

  test "without reconciliation mounted always falls back to store resume":
    let lastOnline = now - 300 * 1_000_000_000'i64

    check not useSyncCatchUp(false, lastOnline, now, SyncRange)

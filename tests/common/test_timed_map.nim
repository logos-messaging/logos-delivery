{.used.}

import unittest2
import chronos/timer
import ../../logos_delivery/waku/common/rate_limit/timed_map

suite "TimedMap":
  test "put/get":
    var cache = TimedMap[int, string].init(5.seconds)

    let now = Moment.now()
    check:
      cache.mgetOrPut(1, "1", now) == "1"
      cache.mgetOrPut(1, "1", now + 1.seconds) == "1"
      cache.mgetOrPut(2, "2", now + 4.seconds) == "2"

    check:
      1 in cache
      2 in cache

    check:
      cache.mgetOrPut(3, "3", now + 6.seconds) == "3"
      # expires 1

    check:
      1 notin cache
      2 in cache
      3 in cache

      cache.addedAt(2) == now + 4.seconds

    check:
      cache.mgetOrPut(2, "modified2", now + 8.seconds) == "2" # refreshes 2
      cache.mgetOrPut(4, "4", now + 12.seconds) == "4" # expires 3

    check:
      2 in cache
      3 notin cache
      4 in cache

    check:
      cache.remove(4).isSome()
      4 notin cache

    check:
      cache.mgetOrPut(100, "100", now + 100.seconds) == "100" # expires everything
      100 in cache
      2 notin cache

  test "enough items to force cache heap storage growth":
    var cache = TimedMap[int, string].init(5.seconds)

    let now = Moment.now()
    for i in 101 .. 100000:
      check:
        cache.mgetOrPut(i, $i, now) == $i

    for i in 101 .. 100000:
      check:
        i in cache

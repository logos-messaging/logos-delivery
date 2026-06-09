{.used.}

import std/options, results, testutils/unittests
import
  logos_delivery/waku/[
    waku_archive,
    waku_archive/driver/queue_driver/queue_driver {.all.},
    waku_archive/driver/queue_driver/index,
    waku_core,
  ]

# Helper functions

proc genIndexedWakuMessage(i: int8): (Index, WakuMessage) =
  ## Use i to generate an Index WakuMessage
  var data {.noinit.}: array[32, byte]
  for x in data.mitems:
    x = i.byte

  let
    message = WakuMessage(payload: @[byte i], timestamp: Timestamp(i))
    pubsubTopic = "test-pubsub-topic"
    cursor = Index(
      time: Timestamp(i),
      hash: computeMessageHash(pubsubTopic, message),
      pubsubTopic: pubsubTopic,
    )

  (cursor, message)

proc getPrepopulatedTestQueue(unsortedSet: auto, capacity: int): QueueDriver =
  let driver = QueueDriver.new(capacity)

  for i in unsortedSet:
    let (index, message) = genIndexedWakuMessage(i.int8)
    discard driver.add(index, message)

  driver

procSuite "Sorted driver queue":
  test "queue capacity - add a message over the limit":
    ## Given
    let capacity = 5
    let driver = QueueDriver.new(capacity)

    ## When
    # Fill up the queue
    for i in 1 .. capacity:
      let (index, message) = genIndexedWakuMessage(i.int8)
      require(driver.add(index, message).isOk())

    # Add one more. Capacity should not be exceeded
    let (index, message) = genIndexedWakuMessage(capacity.int8 + 1)
    require(driver.add(index, message).isOk())

    ## Then
    check:
      driver.len == capacity

  test "queue capacity - add message older than oldest in the queue":
    ## Given
    let capacity = 5
    let driver = QueueDriver.new(capacity)

    ## When
    # Fill up the queue
    for i in 1 .. capacity:
      let (index, message) = genIndexedWakuMessage(i.int8)
      require(driver.add(index, message).isOk())

    # Attempt to add message with older value than oldest in queue should fail
    let
      oldestTimestamp = driver.first().get().time
      (index, message) = genIndexedWakuMessage(oldestTimestamp.int8 - 1)
      addRes = driver.add(index, message)

    ## Then
    check:
      addRes.isErr()
      addRes.error() == "too_old"

    check:
      driver.len == capacity

  test "queue sort-on-insert":
    ## Given
    let
      capacity = 5
      unsortedSet = [5, 1, 3, 2, 4]
    let driver = getPrepopulatedTestQueue(unsortedSet, capacity)

    # Walk forward through the set and verify ascending order
    var (prevSmaller, _) = genIndexedWakuMessage(min(unsortedSet).int8 - 1)
    for i in driver.fwdIterator:
      let (index, _) = i
      check cmp(index, prevSmaller) > 0
      prevSmaller = index

    # Walk backward through the set and verify descending order
    var (prevLarger, _) = genIndexedWakuMessage(max(unsortedSet).int8 + 1)
    for i in driver.bwdIterator:
      let (index, _) = i
      check cmp(index, prevLarger) < 0
      prevLarger = index

  test "access first item from queue":
    ## Given
    let
      capacity = 5
      unsortedSet = [5, 1, 3, 2, 4]
    let driver = getPrepopulatedTestQueue(unsortedSet, capacity)

    ## When
    let firstRes = driver.first()

    ## Then
    check:
      firstRes.isOk()

    let first = firstRes.tryGet()
    check:
      first.time == Timestamp(1)

  test "get first item from empty queue should fail":
    ## Given
    let capacity = 5
    let driver = QueueDriver.new(capacity)

    ## When
    let firstRes = driver.first()

    ## Then
    check:
      firstRes.isErr()
      firstRes.error() == "Not found"

  test "access last item from queue":
    ## Given
    let
      capacity = 5
      unsortedSet = [5, 1, 3, 2, 4]
    let driver = getPrepopulatedTestQueue(unsortedSet, capacity)

    ## When
    let lastRes = driver.last()

    ## Then
    check:
      lastRes.isOk()

    let last = lastRes.tryGet()
    check:
      last.time == Timestamp(5)

  test "get last item from empty queue should fail":
    ## Given
    let capacity = 5
    let driver = QueueDriver.new(capacity)

    ## When
    let lastRes = driver.last()

    ## Then
    check:
      lastRes.isErr()
      lastRes.error() == "Not found"

  test "verify if queue contains an index":
    ## Given
    let
      capacity = 5
      unsortedSet = [5, 1, 3, 2, 4]
    let driver = getPrepopulatedTestQueue(unsortedSet, capacity)

    let
      (existingIndex, _) = genIndexedWakuMessage(4)
      (nonExistingIndex, _) = genIndexedWakuMessage(99)

    ## Then
    check:
      driver.contains(existingIndex) == true
      driver.contains(nonExistingIndex) == false

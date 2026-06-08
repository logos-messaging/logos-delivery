{.used.}

import
  std/[options, sequtils, algorithm], testutils/unittests, libp2p/protobuf/minprotobuf
import
  logos_delivery/waku/[
    waku_archive,
    waku_archive/driver/queue_driver/queue_driver {.all.},
    waku_archive/driver/queue_driver/index,
    waku_core,
  ],
  ../testlib/wakucore

proc getTestQueueDriver(numMessages: int): QueueDriver =
  let testQueueDriver = QueueDriver.new(numMessages)

  var data {.noinit.}: array[32, byte]
  for x in data.mitems:
    x = 1

  for i in 0 ..< numMessages:
    let msg = WakuMessage(payload: @[byte i], timestamp: Timestamp(i))

    let index = Index(
      time: Timestamp(i),
      hash: computeMessageHash(DefaultPubsubTopic, msg),
      pubsubTopic: DefaultPubsubTopic,
    )

    discard testQueueDriver.add(index, msg)

  return testQueueDriver

procSuite "Queue driver - pagination":
  let driver = getTestQueueDriver(10)
  let
    indexList: seq[Index] = toSeq(driver.fwdIterator()).mapIt(it[0])
    msgList: seq[WakuMessage] = toSeq(driver.fwdIterator()).mapIt(it[1])

  test "Forward pagination - normal pagination":
    ## Given
    let
      pageSize: uint = 2
      cursor: Option[Index] = some(indexList[3])
      forward: bool = true

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.len == 2
      data == msgList[4 .. 5]

  test "Forward pagination - initial pagination request with an empty cursor":
    ## Given
    let
      pageSize: uint = 2
      cursor: Option[Index] = none(Index)
      forward: bool = true

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.len == 2
      data == msgList[0 .. 1]

  test "Forward pagination - initial pagination request with an empty cursor to fetch the entire history":
    ## Given
    let
      pageSize: uint = 13
      cursor: Option[Index] = none(Index)
      forward: bool = true

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.len == 10
      data == msgList[0 .. 9]

  test "Forward pagination - empty msgList":
    ## Given
    let driver = getTestQueueDriver(0)
    let
      pageSize: uint = 2
      cursor: Option[Index] = none(Index)
      forward: bool = true

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.len == 0

  test "Forward pagination - page size larger than the remaining messages":
    ## Given
    let
      pageSize: uint = 10
      cursor: Option[Index] = some(indexList[3])
      forward: bool = true

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.len == 6
      data == msgList[4 .. 9]

  test "Forward pagination - page size larger than the maximum allowed page size":
    ## Given
    let
      pageSize: uint = MaxPageSize + 1
      cursor: Option[Index] = some(indexList[3])
      forward: bool = true

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      uint(data.len) <= MaxPageSize

  test "Forward pagination - cursor pointing to the end of the message list":
    ## Given
    let
      pageSize: uint = 10
      cursor: Option[Index] = some(indexList[9])
      forward: bool = true

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.len == 0

  test "Forward pagination - invalid cursor":
    ## Given
    let msg = fakeWakuMessage(payload = @[byte 10])
    let index = Index(hash: computeMessageHash(DefaultPubsubTopic, msg))

    let
      pageSize: uint = 10
      cursor: Option[Index] = some(index)
      forward: bool = true

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let error = page.tryError()
    check:
      error == QueueDriverErrorKind.INVALID_CURSOR

  test "Forward pagination - initial paging query over a message list with one message":
    ## Given
    let driver = getTestQueueDriver(1)
    let
      pageSize: uint = 10
      cursor: Option[Index] = none(Index)
      forward: bool = true

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.len == 1

  test "Forward pagination - pagination over a message list with one message":
    ## Given
    let driver = getTestQueueDriver(1)
    let
      pageSize: uint = 10
      cursor: Option[Index] = some(indexList[0])
      forward: bool = true

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.len == 0

  test "Forward pagination - with pradicate":
    ## Given
    let
      pageSize: uint = 3
      cursor: Option[Index] = none(Index)
      forward = true

    proc onlyEvenTimes(index: Index, msg: WakuMessage): bool =
      msg.timestamp.int64 mod 2 == 0

    ## When
    let page = driver.getPage(
      pageSize = pageSize, forward = forward, cursor = cursor, predicate = onlyEvenTimes
    )

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.mapIt(it.timestamp.int) == @[0, 2, 4]

  test "Backward pagination - normal pagination":
    ## Given
    let
      pageSize: uint = 2
      cursor: Option[Index] = some(indexList[3])
      forward: bool = false

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data == msgList[1 .. 2].reversed

  test "Backward pagination - empty msgList":
    ## Given
    let driver = getTestQueueDriver(0)
    let
      pageSize: uint = 2
      cursor: Option[Index] = none(Index)
      forward: bool = false

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.len == 0

  test "Backward pagination - initial pagination request with an empty cursor":
    ## Given
    let
      pageSize: uint = 2
      cursor: Option[Index] = none(Index)
      forward: bool = false

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.len == 2
      data == msgList[8 .. 9].reversed

  test "Backward pagination - initial pagination request with an empty cursor to fetch the entire history":
    ## Given
    let
      pageSize: uint = 13
      cursor: Option[Index] = none(Index)
      forward: bool = false

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.len == 10
      data == msgList[0 .. 9].reversed

  test "Backward pagination - page size larger than the remaining messages":
    ## Given
    let
      pageSize: uint = 5
      cursor: Option[Index] = some(indexList[3])
      forward: bool = false

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data == msgList[0 .. 2].reversed

  test "Backward pagination - page size larger than the Maximum allowed page size":
    ## Given
    let
      pageSize: uint = MaxPageSize + 1
      cursor: Option[Index] = some(indexList[3])
      forward: bool = false

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      uint(data.len) <= MaxPageSize

  test "Backward pagination - cursor pointing to the begining of the message list":
    ## Given
    let
      pageSize: uint = 5
      cursor: Option[Index] = some(indexList[0])
      forward: bool = false

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.len == 0

  test "Backward pagination - invalid cursor":
    ## Given
    let msg = fakeWakuMessage(payload = @[byte 10])
    let index = Index(hash: computeMessageHash(DefaultPubsubTopic, msg))

    let
      pageSize: uint = 2
      cursor: Option[Index] = some(index)
      forward: bool = false

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let error = page.tryError()
    check:
      error == QueueDriverErrorKind.INVALID_CURSOR

  test "Backward pagination - initial paging query over a message list with one message":
    ## Given
    let driver = getTestQueueDriver(1)
    let
      pageSize: uint = 10
      cursor: Option[Index] = none(Index)
      forward: bool = false

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.len == 1

  test "Backward pagination - paging query over a message list with one message":
    ## Given
    let driver = getTestQueueDriver(1)
    let
      pageSize: uint = 10
      cursor: Option[Index] = some(indexList[0])
      forward: bool = false

    ## When
    let page = driver.getPage(pageSize = pageSize, forward = forward, cursor = cursor)

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.len == 0

  test "Backward pagination - with predicate":
    ## Given
    let
      pageSize: uint = 3
      cursor: Option[Index] = none(Index)
      forward = false

    proc onlyOddTimes(index: Index, msg: WakuMessage): bool =
      msg.timestamp.int64 mod 2 != 0

    ## When
    let page = driver.getPage(
      pageSize = pageSize, forward = forward, cursor = cursor, predicate = onlyOddTimes
    )

    ## Then
    let data = page.tryGet().mapIt(it[2])
    check:
      data.mapIt(it.timestamp.int) == @[5, 7, 9].reversed

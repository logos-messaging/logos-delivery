{.push raises: [].}

import std/options, results, stew/sorted_set, chronicles, chronos
import ../../../waku_core, ../../common, ../../driver, ./index

logScope:
  topics = "waku archive queue_store"

const QueueDriverDefaultMaxCapacity* = 25_000

type
  QueryFilterMatcher =
    proc(index: Index, msg: WakuMessage): bool {.gcsafe, raises: [], closure.}

  QueueDriver* = ref object of ArchiveDriver
    ## Bounded repository for indexed messages
    ##
    ## The store queue will keep messages up to its
    ## configured capacity. As soon as this capacity
    ## is reached and a new message is added, the oldest
    ## item will be removed to make space for the new one.
    ## This implies both a `delete` and `add` operation
    ## for new items.

    # TODO: a circular/ring buffer may be a more efficient implementation
    items: SortedSet[Index, WakuMessage] # sorted set of stored messages
    capacity: int # Maximum amount of messages to keep

  QueueDriverErrorKind {.pure.} = enum
    INVALID_CURSOR

  QueueDriverGetPageResult = Result[seq[ArchiveRow], QueueDriverErrorKind]

proc `$`(error: QueueDriverErrorKind): string =
  case error
  of INVALID_CURSOR: "invalid_cursor"

### Helpers

proc walkToCursor(
    w: SortedSetWalkRef[Index, WakuMessage], startCursor: Index, forward: bool
): SortedSetResult[Index, WakuMessage] =
  ## Walk to util we find the cursor
  ## TODO: Improve performance here with a binary/tree search

  var nextItem =
    if forward:
      w.first()
    else:
      w.last()

  ## Fast forward until we reach the startCursor
  while nextItem.isOk():
    if nextItem.value.key == startCursor:
      break

    # Not yet at cursor. Continue advancing
    nextItem =
      if forward:
        w.next()
      else:
        w.prev()

  return nextItem

#### API

proc new*(T: type QueueDriver, capacity: int = QueueDriverDefaultMaxCapacity): T =
  var items = SortedSet[Index, WakuMessage].init()
  return QueueDriver(items: items, capacity: capacity)

proc contains*(driver: QueueDriver, index: Index): bool =
  ## Return `true` if the store queue already contains the `index`, `false` otherwise.
  return driver.items.eq(index).isOk()

proc len*(driver: QueueDriver): int {.noSideEffect.} =
  return driver.items.len

proc getPage(
    driver: QueueDriver,
    pageSize: uint = 0,
    forward: bool = true,
    cursor: Option[Index] = none(Index),
    predicate: QueryFilterMatcher = nil,
): QueueDriverGetPageResult {.raises: [].} =
  ## Populate a single page in forward direction
  ## Start at the `startCursor` (exclusive), or first entry (inclusive) if not defined.
  ## Page size must not exceed `maxPageSize`
  ## Each entry must match the `pred`
  var outSeq: seq[ArchiveRow]

  var w = SortedSetWalkRef[Index, WakuMessage].init(driver.items)
  defer:
    w.destroy()

  var currentEntry: SortedSetResult[Index, WakuMessage]

  # Find starting entry
  if cursor.isSome():
    w.walkToCursor(cursor.get(), forward).isOkOr:
      return err(QueueDriverErrorKind.INVALID_CURSOR)

    # Advance walker once more
    currentEntry =
      if forward:
        w.next()
      else:
        w.prev()
  else:
    # Start from the beginning of the queue
    currentEntry =
      if forward:
        w.first()
      else:
        w.last()

  trace "Starting page query", currentEntry = currentEntry

  ## This loop walks forward over the queue:
  ## 1. from the given cursor (or first/last entry, if not provided)
  ## 2. adds entries matching the predicate function to output page
  ## 3. until either the end of the queue or maxPageSize is reached
  var numberOfItems: uint = 0
  while currentEntry.isOk() and numberOfItems < pageSize:
    trace "Continuing page query",
      currentEntry = currentEntry, numberOfItems = numberOfItems

    let
      key = currentEntry.value.key
      data = currentEntry.value.data

    if predicate.isNil() or predicate(key, data):
      numberOfItems += 1

      outSeq.add((key.hash, key.pubsubTopic, data))

    currentEntry =
      if forward:
        w.next()
      else:
        w.prev()

  trace "Successfully retrieved page", len = outSeq.len

  return ok(outSeq)

## --- SortedSet accessors ---

iterator fwdIterator*(driver: QueueDriver): (Index, WakuMessage) =
  ## Forward iterator over the entire store queue
  var
    w = SortedSetWalkRef[Index, WakuMessage].init(driver.items)
    res = w.first()

  while res.isOk():
    yield (res.value.key, res.value.data)
    res = w.next()

  w.destroy()

iterator bwdIterator*(driver: QueueDriver): (Index, WakuMessage) =
  ## Backwards iterator over the entire store queue
  var
    w = SortedSetWalkRef[Index, WakuMessage].init(driver.items)
    res = w.last()

  while res.isOk():
    yield (res.value.key, res.value.data)
    res = w.prev()

  w.destroy()

proc first*(driver: QueueDriver): ArchiveDriverResult[Index] =
  var
    w = SortedSetWalkRef[Index, WakuMessage].init(driver.items)
    res = w.first()
  w.destroy()

  res.isOkOr:
    return err("Not found")

  return ok(res.value.key)

proc last*(driver: QueueDriver): ArchiveDriverResult[Index] =
  var
    w = SortedSetWalkRef[Index, WakuMessage].init(driver.items)
    res = w.last()
  w.destroy()

  res.isOkOr:
    return err("Not found")

  return ok(res.value.key)

## --- Queue API ---

proc add*(
    driver: QueueDriver, index: Index, msg: WakuMessage
): ArchiveDriverResult[void] =
  ## Add a message to the queue
  ##
  ## If we're at capacity, we will be removing, the oldest (first) item
  if driver.contains(index):
    trace "could not add item to store queue. Index already exists", index = index
    return err("duplicate")

  # TODO: the below delete block can be removed if we convert to circular buffer
  if driver.items.len >= driver.capacity:
    var
      w = SortedSetWalkRef[Index, WakuMessage].init(driver.items)
      firstItem = w.first

    if cmp(index, firstItem.value.key) < 0:
      # When at capacity, we won't add if message index is smaller (older) than our oldest item
      w.destroy # Clean up walker
      return err("too_old")

    discard driver.items.delete(firstItem.value.key)
    w.destroy # better to destroy walker after a delete operation

  driver.items.insert(index).value.data = msg

  return ok()

method put*(
    driver: QueueDriver,
    messageHash: WakuMessageHash,
    pubsubTopic: PubsubTopic,
    message: WakuMessage,
): Future[ArchiveDriverResult[void]] {.async.} =
  let index =
    Index(time: message.timestamp, hash: messageHash, pubsubTopic: pubsubTopic)

  return driver.add(index, message)

method getAllMessages*(
    driver: QueueDriver
): Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =
  # TODO: Implement this message_store method
  return err("interface method not implemented")

method existsTable*(
    driver: QueueDriver, tableName: string
): Future[ArchiveDriverResult[bool]] {.async.} =
  return err("interface method not implemented")

method getMessages*(
    driver: QueueDriver,
    includeData = true,
    contentTopics: seq[ContentTopic] = @[],
    pubsubTopic = none(PubsubTopic),
    cursor = none(ArchiveCursor),
    startTime = none(Timestamp),
    endTime = none(Timestamp),
    hashes: seq[WakuMessageHash] = @[],
    maxPageSize = DefaultPageSize,
    ascendingOrder = true,
    requestId = "",
): Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =
  var index = none(Index)

  if cursor.isSome():
    index = some(Index(hash: cursor.get()))

  let matchesQuery: QueryFilterMatcher =
    func (index: Index, msg: WakuMessage): bool =
      if pubsubTopic.isSome() and index.pubsubTopic != pubsubTopic.get():
        return false

      if contentTopics.len > 0 and msg.contentTopic notin contentTopics:
        return false

      if startTime.isSome() and msg.timestamp < startTime.get():
        return false

      if endTime.isSome() and msg.timestamp > endTime.get():
        return false

      if hashes.len > 0 and index.hash notin hashes:
        return false

      return true

  let catchable = catch:
    driver.getPage(maxPageSize, ascendingOrder, index, matchesQuery)

  let pageRes: QueueDriverGetPageResult = catchable.valueOr:
    return err(catchable.error.msg)

  pageRes.isOkOr:
    return err($error)

  return ok(pageRes.value)

method getMessagesCount*(
    driver: QueueDriver
): Future[ArchiveDriverResult[int64]] {.async.} =
  return ok(int64(driver.len()))

method getPagesCount*(
    driver: QueueDriver
): Future[ArchiveDriverResult[int64]] {.async.} =
  return ok(int64(driver.len()))

method getPagesSize*(
    driver: QueueDriver
): Future[ArchiveDriverResult[int64]] {.async.} =
  return ok(int64(driver.len()))

method getDatabaseSize*(
    driver: QueueDriver
): Future[ArchiveDriverResult[int64]] {.async.} =
  return ok(int64(driver.len()))

method performVacuum*(
    driver: QueueDriver
): Future[ArchiveDriverResult[void]] {.async.} =
  return err("interface method not implemented")

method getOldestMessageTimestamp*(
    driver: QueueDriver
): Future[ArchiveDriverResult[Timestamp]] {.async.} =
  return driver.first().map(
      proc(index: Index): Timestamp =
        index.time
    )

method getNewestMessageTimestamp*(
    driver: QueueDriver
): Future[ArchiveDriverResult[Timestamp]] {.async.} =
  return driver.last().map(
      proc(index: Index): Timestamp =
        index.time
    )

method deleteMessagesOlderThanTimestamp*(
    driver: QueueDriver, ts: Timestamp
): Future[ArchiveDriverResult[void]] {.async.} =
  # TODO: Implement this message_store method
  return err("interface method not implemented")

method deleteOldestMessagesNotWithinLimit*(
    driver: QueueDriver, limit: int
): Future[ArchiveDriverResult[void]] {.async.} =
  # TODO: Implement this message_store method
  return err("interface method not implemented")

method decreaseDatabaseSize*(
    driver: QueueDriver, targetSizeInBytes: int64, forceRemoval: bool = false
): Future[ArchiveDriverResult[void]] {.async.} =
  return err("interface method not implemented")

method close*(driver: QueueDriver): Future[ArchiveDriverResult[void]] {.async.} =
  return ok()

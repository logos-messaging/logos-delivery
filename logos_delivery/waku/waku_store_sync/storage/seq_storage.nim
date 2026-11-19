import
  std/[algorithm, sequtils, tables, packedsets, sugar],
  results,
  chronos,
  stew/[arrayops, leb128]

import
  ../../waku_core/time,
  ../../waku_core/message/digest,
  ../../waku_core/topics/pubsub_topic,
  ../common,
  ../codec,
  ./range_processing,
  ./storage

type SeqStorage* = ref object of SyncStorage
  elements: seq[SyncID]

  pubsubTopicIndexes: seq[int]

  pubsubTopics: seq[PubSubTopic]

  unusedPubsubTopicSet: PackedSet[int]

  # Numer of parts a range will be splitted into.
  partitionCount: int

  # Number of element in a range for which item sets are used instead of fingerprints.
  lengthThreshold: int

  # Only the first range of a reply that is not Skip may take the reply over
  # this limit.
  frameSizeLimitBytes: int

type RangeAnswer* = object
  ## The answer to one received range: the ranges of the reply, the IDs that
  ## each side transfers, and the bytes still free in the reply.
  reply*: RangesData
  idsToSend*: seq[SyncID]
  idsToRecv*: seq[SyncID]
  frameBytesLeft*: int

method length*(self: SeqStorage): int {.raises: [].} =
  return self.elements.len

method contains*(self: SeqStorage, element: SyncID): bool {.raises: [].} =
  let idx = self.elements.lowerBound(element, common.cmp)
  return idx < self.elements.len and self.elements[idx] == element

proc pubsubTopicsLen*(self: SeqStorage): int {.raises: [].} =
  return self.pubsubTopics.len

proc unusedPubsubTopicsLen*(self: SeqStorage): int {.raises: [].} =
  return self.unusedPubsubTopicSet.len

proc getPubsubTopicIndex(self: SeqStorage, pubsubTopic: PubSubTopic): int =
  for i, selfTopic in self.pubsubTopics:
    if pubsubTopic == selfTopic:
      return i

  if self.unusedPubsubTopicSet.len > 0:
    let unusedIdx = self.unusedPubsubTopicSet.toSeq()[0]
    self.unusedPubsubTopicSet.excl(unusedIdx)
    self.pubsubTopics[unusedIdx] = pubsubTopic
    return unusedIdx

  let newIdx = self.pubsubTopics.len
  self.pubsubTopics.add(pubsubTopic)
  return newidx

proc insertAt(self: SeqStorage, idx: int, element: SyncID, pubsubTopic: PubSubTopic) =
  if idx < self.elements.len and self.elements[idx] == element:
    # duplicate element ignore
    return

  self.elements.insert(element, idx)

  let pubsubIndex = self.getPubsubTopicIndex(pubsubTopic)

  self.pubsubTopicIndexes.insert(pubsubIndex, idx)

method insert*(
    self: SeqStorage, element: SyncID, pubsubTopic: PubSubTopic
): Result[void, string] {.raises: [].} =
  let idx = self.elements.lowerBound(element, common.cmp)
  self.insertAt(idx, element, pubsubTopic)

  return ok()

method batchInsert*(
    self: SeqStorage, elements: seq[SyncID], pubsubTopics: seq[PubSubTopic]
): Result[void, string] {.raises: [].} =
  ## Insert the sorted seq of new elements.

  if elements.len == 1:
    return self.insert(elements[0], pubsubTopics[0])

  if not elements.isSorted(common.cmp):
    return err("seq not sorted")

  var idx = 0
  for i in 0 ..< elements.len:
    let element = elements[i]
    let pubsubTopic = pubsubTopics[i]

    idx = self.elements[idx ..< self.elements.len].lowerBound(element, common.cmp)

    self.insertAt(idx, element, pubsubTopic)

  return ok()

method remove*(self: SeqStorage, element: SyncID): Result[void, string] {.raises: [].} =
  ## Removes `element` from the store-sync index. An absent element is a no-op.

  let idx = self.elements.lowerBound(element, common.cmp)
  if idx >= self.elements.len or self.elements[idx] != element:
    # Removing an absent element is a no-op.
    return ok()

  # Topics that lose their last element stay allocated and are not marked
  # unused until the next `prune`.
  self.elements.delete(idx)
  self.pubsubTopicIndexes.delete(idx)

  return ok()

method prune*(self: SeqStorage, timestamp: Timestamp): int {.raises: [].} =
  ## Remove all elements before the timestamp.
  ## Returns # of elements pruned.

  if self.elements.len == 0:
    return 0

  let bound = SyncID(time: timestamp, hash: EmptyWakuMessageHash)

  let idx = self.elements.lowerBound(bound, common.cmp)

  self.elements.delete(0 ..< idx)
  self.pubsubTopicIndexes.delete(0 ..< idx)

  # Free unused pubsub topics
  let pubsubIdxSet = self.pubsubTopicIndexes.toPackedSet()
  var pubsubTopicSet: PackedSet[int]
  for i in 0 ..< self.pubsubTopics.len:
    pubsubTopicSet.incl(i)

  self.unusedPubsubTopicSet = pubsubTopicSet - pubsubIdxSet

  return idx

proc computefingerprintFromSlice(
    self: SeqStorage, sliceOpt: Opt[Slice[int]], pubsubTopicSet: PackedSet[int]
): Fingerprint =
  ## XOR all hashes of a slice of the storage.

  var fingerprint = EmptyFingerprint

  if sliceOpt.isNone():
    return fingerprint

  let idxSlice = sliceOpt.get()

  let elementSlice = self.elements[idxSlice]
  let pubsubSlice = self.pubsubTopicIndexes[idxSlice]

  for i in 0 ..< elementSlice.len:
    let id = elementSlice[i]
    let pubsub = pubsubSlice[i]

    if pubsubTopicSet.len > 0 and pubsub notin pubsubTopicSet:
      continue

    fingerprint = fingerprint xor id.hash

  return fingerprint

proc findIdxBounds(self: SeqStorage, slice: Slice[SyncID]): Opt[Slice[int]] =
  ## Given bounds find the corresponding indices in this storage

  let lower = self.elements.lowerBound(slice.a, common.cmp)
  var upper = self.elements.upperBound(slice.b, common.cmp)

  if upper < 1:
    # entire range is before any of our elements
    return Opt.none(Slice[int])

  if lower >= self.elements.len:
    # entire range is after any of our elements
    return Opt.none(Slice[int])

  return Opt.some(lower ..< upper)

proc pubsubScope(self: SeqStorage, pubsubTopics: seq[PubsubTopic]): PackedSet[int] =
  ## The local indexes of `pubsubTopics`. An empty set means every topic, so a
  ## request whose topics are all unknown here gets an index no element has.
  ## Pending elements have no shard yet, so they are in every scope.
  var scope = initPackedSet[int]()
  for inputTopic in pubsubTopics:
    for i, localTopic in self.pubsubTopics:
      if inputTopic == localTopic:
        scope.incl(i)

  if pubsubTopics.len > 0 and scope.len == 0:
    # -1 is never an element's topic index, so nothing matches
    scope.incl(-1)

  # Pending (promised, not yet arrived) elements have no shard; include them in every
  # scope so overlapping rounds don't ask for them again.
  if pubsubTopics.len > 0:
    for i, localTopic in self.pubsubTopics:
      if localTopic == PendingPubsubTopic:
        scope.incl(i)

  return scope

method computeFingerprint*(
    self: SeqStorage, bounds: Slice[SyncID], pubsubTopics: seq[PubsubTopic]
): Fingerprint {.raises: [].} =
  let idxSliceOpt = self.findIdxBounds(bounds)

  let pubsubTopicSet = self.pubsubScope(pubsubTopics)

  return self.computefingerprintFromSlice(idxSliceOpt, pubsubTopicSet)

proc getFilteredElements(
    self: SeqStorage, slice: Slice[int], pubsubTopicSet: PackedSet[int]
): seq[SyncID] =
  let elements = collect(newSeq):
    for i in slice:
      if pubsubTopicSet.len > 0 and self.pubsubTopicIndexes[i] notin pubsubTopicSet:
        continue

      self.elements[i]

  elements

proc processFingerprintRange*(
    self: SeqStorage,
    inputBounds: Slice[SyncID],
    pubsubTopicSet: PackedSet[int],
    inputFingerprint: Fingerprint,
    output: var RangesData,
    frameBytesLeft: var int,
) {.raises: [].} =
  ## Compares fingerprints and partition new ranges. Subtracts the encoded size
  ## of each range that it adds from `frameBytesLeft`, the bytes still free in
  ## the reply.

  let idxSlice = self.findIdxBounds(inputBounds)
  let ourFingerprint = self.computeFingerprintFromSlice(idxSlice, pubsubTopicSet)

  if ourFingerprint == inputFingerprint:
    output.ranges.add((inputBounds, RangeType.Skip))
    frameBytesLeft -= maxEncodedRangeSize(RangeType.Skip)
    return

  # An empty range is not marked reconciled: the peer then replies with its
  # items, which tells this node what to accept over transfer.
  if idxSlice.isNone():
    output.ranges.add((inputBounds, RangeType.ItemSet))
    let state = ItemSet(elements: @[], reconciled: false)
    output.itemSets.add(state)
    frameBytesLeft -= maxEncodedRangeSize(RangeType.ItemSet, state)
    return

  let slice = idxSlice.get()
  let partitions = equalPartitioning(inputBounds, self.partitionCount)

  if slice.len <= self.lengthThreshold:
    let elements = self.getFilteredElements(slice, pubsubTopicSet)
    let state = ItemSet(elements: elements, reconciled: false)
    let size = maxEncodedRangeSize(RangeType.ItemSet, state)
    # An item set that does not fit makes the range too large, so it is
    # divided. A range too short to divide is listed anyway, so that the
    # session progresses.
    if size <= frameBytesLeft or partitions.len == 0:
      frameBytesLeft -= size
      output.ranges.add((inputBounds, RangeType.ItemSet))
      output.itemSets.add(state)
      return

  for partitionBounds in partitions:
    let sliceOpt = self.findIdxBounds(partitionBounds)

    if sliceOpt.isNone():
      output.ranges.add((partitionBounds, RangeType.ItemSet))
      let state = ItemSet(elements: @[], reconciled: false)
      output.itemSets.add(state)
      frameBytesLeft -= maxEncodedRangeSize(RangeType.ItemSet, state)
      continue

    let slice = sliceOpt.get()

    if slice.len <= self.lengthThreshold:
      let elements = self.getFilteredElements(slice, pubsubTopicSet)
      let state = ItemSet(elements: elements, reconciled: false)
      let size = maxEncodedRangeSize(RangeType.ItemSet, state)
      # A partition whose item set does not fit is sent as a fingerprint.
      if size <= frameBytesLeft:
        frameBytesLeft -= size
        output.ranges.add((partitionBounds, RangeType.ItemSet))
        output.itemSets.add(state)
        continue

    let fingerprint = self.computeFingerprintFromSlice(Opt.some(slice), pubsubTopicSet)
    output.ranges.add((partitionBounds, RangeType.Fingerprint))
    output.fingerprints.add(fingerprint)
    frameBytesLeft -= maxEncodedRangeSize(RangeType.Fingerprint)
    continue

func differences(
    ourSyncIDs, theirSyncIDs: seq[SyncID]
): tuple[ourOnly, theirOnly: seq[SyncID]] =
  ## The IDs that only one side holds. Both inputs are sorted.
  var
    ourOnly: seq[SyncID]
    theirOnly: seq[SyncID]
    i = 0
    j = 0

  while i < theirSyncIDs.len and j < ourSyncIDs.len:
    if theirSyncIDs[i] < ourSyncIDs[j]:
      theirOnly.add(theirSyncIDs[i])
      i.inc()
    elif theirSyncIDs[i] > ourSyncIDs[j]:
      ourOnly.add(ourSyncIDs[j])
      j.inc()
    else:
      i.inc()
      j.inc()

  theirOnly.add(theirSyncIDs[i ..^ 1])
  ourOnly.add(ourSyncIDs[j ..^ 1])
  (ourOnly, theirOnly)

func fittingCount(ourSyncIDs: seq[SyncID], available: int): int =
  ## The number of leading IDs whose listing fits in `available` bytes, or 0.
  ## The cutoff has a zero hash, so it falls before every element of its
  ## timestamp: the listing can end only where the timestamp changes.
  let emptyListing = maxEncodedRangeSize(RangeType.ItemSet, ItemSet())
  var
    fitting = 0
    elementsSize = 0
    previousTime = Timestamp(0)

  for k in 0 ..< ourSyncIDs.len:
    elementsSize += encodedElementSize(ourSyncIDs[k], previousTime)
    previousTime = ourSyncIDs[k].time
    # emptyListing counts one byte for an element count of zero.
    let listing = emptyListing - 1 + int(Leb128.len(uint64(k + 1))) + elementsSize
    if listing > available:
      break
    if k + 1 == ourSyncIDs.len or ourSyncIDs[k + 1].time != ourSyncIDs[k].time:
      fitting = k + 1

  fitting

func firstTimestampCount(ourSyncIDs: seq[SyncID]): int =
  ## The number of IDs that share the first timestamp.
  var count = 0
  while count < ourSyncIDs.len and ourSyncIDs[count].time == ourSyncIDs[0].time:
    count.inc()
  count

func addDifferences(
    answer: var RangeAnswer, ourOnly, theirOnly: seq[SyncID], cutoff: Opt[SyncID]
) =
  ## Appends the differences below `cutoff`, or all of them without one. The
  ## cutoff is none when the answer covers the whole range: a Skip for a
  ## reconciled item set, or a listing that fits. With a split, the peer learns
  ## only the IDs below the cutoff in this round.
  for id in ourOnly:
    if cutoff.isNone() or id < cutoff.get():
      answer.idsToSend.add(id)

  for id in theirOnly:
    if cutoff.isNone() or id < cutoff.get():
      answer.idsToRecv.add(id)

proc processItemSetRange*(
    self: SeqStorage,
    inputBounds: Slice[SyncID],
    pubsubTopicSet: PackedSet[int],
    inputItemSet: ItemSet,
    answer: var RangeAnswer,
    mustAnswer: bool,
): bool {.raises: [].} =
  ## Compares item sets and adds the differences to `answer`. Subtracts the
  ## encoded size of the ranges that it adds from `answer.frameBytesLeft`. A
  ## listing that does not fit is split at a cutoff. Returns false, and adds
  ## nothing, when not even the first timestamp fits and `mustAnswer` is false.

  let idxSlice = self.findIdxBounds(inputBounds)
  let ourSyncIDs =
    if idxSlice.isSome():
      self.getFilteredElements(idxSlice.get(), pubsubTopicSet)
    else:
      @[]
  let (ourOnly, theirOnly) = differences(ourSyncIDs, inputItemSet.elements)

  if inputItemSet.reconciled:
    answer.addDifferences(ourOnly, theirOnly, Opt.none(SyncID))
    answer.reply.ranges.add((inputBounds, RangeType.Skip))
    answer.frameBytesLeft -= maxEncodedRangeSize(RangeType.Skip)
    return true

  let full = ItemSet(elements: ourSyncIDs, reconciled: true)
  let fullSize = maxEncodedRangeSize(RangeType.ItemSet, full)

  # Number of elements that the reply lists.
  var fitting = ourSyncIDs.len

  if fullSize > answer.frameBytesLeft:
    # Keeps back the size of the fingerprint of the rest.
    fitting = fittingCount(
      ourSyncIDs, answer.frameBytesLeft - maxEncodedRangeSize(RangeType.Fingerprint)
    )

    if fitting == 0:
      if not mustAnswer:
        return false

      # The first timestamp of the range is listed even when it does not fit,
      # so that every round makes progress.
      fitting = firstTimestampCount(ourSyncIDs)

  if fitting == ourSyncIDs.len:
    answer.addDifferences(ourOnly, theirOnly, Opt.none(SyncID))
    answer.reply.ranges.add((inputBounds, RangeType.ItemSet))
    answer.reply.itemSets.add(full)
    answer.frameBytesLeft -= fullSize
    return true

  let cutoff = SyncID(time: ourSyncIDs[fitting].time, hash: EmptyFingerprint)
  let listed = ItemSet(elements: ourSyncIDs[0 ..< fitting], reconciled: true)
  let rest = self.computeFingerprintFromSlice(
    self.findIdxBounds(cutoff .. inputBounds.b), pubsubTopicSet
  )

  answer.reply.ranges.add((inputBounds.a .. cutoff, RangeType.ItemSet))
  answer.reply.itemSets.add(listed)
  answer.reply.ranges.add((cutoff .. inputBounds.b, RangeType.Fingerprint))
  answer.reply.fingerprints.add(rest)
  answer.frameBytesLeft -=
    maxEncodedRangeSize(RangeType.ItemSet, listed) +
    maxEncodedRangeSize(RangeType.Fingerprint)

  # The peer learns the rest of the range in a later round, and accepts over
  # transfer only what it has learned.
  answer.addDifferences(ourOnly, theirOnly, Opt.some(cutoff))
  return true

method processPayload*(
    self: SeqStorage,
    input: RangesData,
    idsToSend: var seq[SyncID],
    idsToRecv: var seq[SyncID],
): RangesData {.raises: [].} =
  ## Compares the peer's ranges with the local index and returns the ranges to
  ## send back. Appends to `idsToSend` the local elements the peer
  ## lacks, and to `idsToRecv` the peer's elements missing here, with their
  ## timestamps, so the caller can index them before they arrive.
  ##
  ## The reply stays within the frame size limit, except for its first range
  ## that is not Skip. From the first range whose answer does not fit, it
  ## answers the remaining ranges with one fingerprint range.
  var output = RangesData()

  var
    i = 0
    j = 0
    # Keeps back the size of the fingerprint range that ends a stopped reply.
    frameBytesLeft =
      self.frameSizeLimitBytes - maxEncodedHeaderSize(input.shards.len) -
      maxEncodedRangeSize(RangeType.Fingerprint)
    # Only the first answered range that is not Skip may go over the limit, so
    # that every round makes progress.
    answeredOne = false
    # The first received range that the reply does not answer, if any.
    stopAt = -1

  let pubsubTopicSet = self.pubsubScope(
    input.shards.mapIt($RelayShard(clusterId: input.cluster, shardId: it))
  )

  for idx in 0 ..< input.ranges.len:
    let (bounds, rangeType) = input.ranges[idx]

    # Each answer is built separately, so that one that does not fit is dropped.
    var
      answer = RangeAnswer(frameBytesLeft: frameBytesLeft)
      answered = true

    case rangeType
    of RangeType.Skip:
      answer.reply.ranges.add((bounds, RangeType.Skip))
      answer.frameBytesLeft -= maxEncodedRangeSize(RangeType.Skip)
    of RangeType.Fingerprint:
      let fingerprint = input.fingerprints[i]
      i.inc()

      self.processFingerprintRange(
        bounds, pubsubTopicSet, fingerprint, answer.reply, answer.frameBytesLeft
      )
    of RangeType.ItemSet:
      let itemSet = input.itemsets[j]
      j.inc()

      answered = self.processItemSetRange(
        bounds, pubsubTopicSet, itemSet, answer, mustAnswer = not answeredOne
      )

    let mustKeep = rangeType != RangeType.Skip and not answeredOne
    if not mustKeep and (not answered or answer.frameBytesLeft < 0):
      stopAt = idx
      break

    output.ranges.add(answer.reply.ranges)
    output.fingerprints.add(answer.reply.fingerprints)
    output.itemSets.add(answer.reply.itemSets)
    idsToSend.add(answer.idsToSend)
    idsToRecv.add(answer.idsToRecv)
    frameBytesLeft = answer.frameBytesLeft
    if rangeType != RangeType.Skip:
      answeredOne = true

  if stopAt >= 0:
    let rest = input.ranges[stopAt][0].a .. input.ranges[^1][0].b
    output.ranges.add((rest, RangeType.Fingerprint))
    output.fingerprints.add(
      self.computeFingerprintFromSlice(self.findIdxBounds(rest), pubsubTopicSet)
    )

  # merge consecutive skip ranges
  var allSkip = true
  i = output.ranges.len - 1
  while i >= 0:
    let currRange = output.ranges[i]

    if allSkip and currRange[1] != RangeType.Skip:
      allSkip = false

    if i <= 0:
      break

    let prevRange = output.ranges[i - 1]

    if currRange[1] != RangeType.Skip or prevRange[1] != RangeType.Skip:
      i.dec()
      continue

    let lb = prevRange[0].a
    let ub = currRange[0].b
    let newRange = (lb .. ub, RangeType.Skip)

    output.ranges.delete(i)
    output.ranges[i - 1] = newRange

    i.dec()

  if allSkip:
    output = RangesData()

  return output

proc processPayload*(
    self: SyncStorage,
    input: RangesData,
    hashToSend: var seq[Fingerprint],
    hashToRecv: var seq[Fingerprint],
): RangesData {.gcsafe, raises: [].} =
  ## Same as the method, for callers that do not index the elements to receive
  ## before they arrive: reports them by hash only, in `hashToRecv`.
  var
    idsToSend: seq[SyncID]
    idsToRecv: seq[SyncID]
  let output = self.processPayload(input, idsToSend, idsToRecv)
  for id in idsToSend:
    hashToSend.add(id.hash)
  for id in idsToRecv:
    hashToRecv.add(id.hash)

  return output

func minFrameSizeLimit(): int =
  ## The size of the smallest reply: no shards and one fingerprint range.
  maxEncodedHeaderSize(0) + maxEncodedRangeSize(RangeType.Fingerprint)

proc new*(
    T: type SeqStorage,
    capacity: int,
    threshold = 100,
    partitions = 8,
    frameSizeLimit = DefaultMaxPayloadSize,
): T =
  doAssert frameSizeLimit >= minFrameSizeLimit(),
    "frameSizeLimit cannot hold a fingerprint range"
  doAssert frameSizeLimit <= DefaultMaxPayloadSize,
    "frameSizeLimit exceeds what a peer reads: " & $frameSizeLimit
  return SeqStorage(
    elements: newSeqOfCap[SyncID](capacity),
    lengthThreshold: threshold,
    partitionCount: partitions,
    frameSizeLimitBytes: frameSizeLimit,
  )

proc new*(
    T: type SeqStorage,
    elements: seq[SyncID],
    pubsubTopics: seq[PubsubTopic],
    threshold = 100,
    partitions = 8,
    frameSizeLimit = DefaultMaxPayloadSize,
): T =
  doAssert frameSizeLimit >= minFrameSizeLimit(),
    "frameSizeLimit cannot hold a fingerprint range"
  doAssert frameSizeLimit <= DefaultMaxPayloadSize,
    "frameSizeLimit exceeds what a peer reads: " & $frameSizeLimit
  var idx = 0
  var uniquePubsubTopics = initOrderedTable[PubsubTopic, int]()
  for pubsub in pubsubTopics:
    if pubsub notin uniquePubsubTopics:
      uniquePubsubTopics[pubsub] = idx
      idx.inc()

  let pubsubTopicIndexes = collect(newSeq):
    for pubsub in pubsubTopics:
      uniquePubsubTopics[pubsub]

  return SeqStorage(
    elements: elements,
    pubsubTopics: uniquePubsubTopics.keys.toSeq(),
    pubsubTopicIndexes: pubsubTopicIndexes,
    lengthThreshold: threshold,
    partitionCount: partitions,
    frameSizeLimitBytes: frameSizeLimit,
  )

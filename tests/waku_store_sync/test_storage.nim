{.used.}

import
  results, std/[algorithm, random, sequtils, packedsets], testutils/unittests, chronos

import
  ../../logos_delivery/waku/waku_core,
  ../../logos_delivery/waku/waku_store_sync/common,
  ../../logos_delivery/waku/waku_store_sync/codec,
  ../../logos_delivery/waku/waku_store_sync/storage/seq_storage,
  ./sync_utils

proc frameLeaving(frameBytesLeft: int): int =
  ## A frame size limit that leaves `frameBytesLeft` bytes for the ranges of a
  ## reply to a payload with no shards.
  maxEncodedHeaderSize(0) + maxEncodedRangeSize(RangeType.Fingerprint) + frameBytesLeft

proc listingSize(elements: openArray[SyncID]): int =
  maxEncodedRangeSize(RangeType.ItemSet, ItemSet(elements: @elements))

const ExampleBounds =
  SyncID(time: Timestamp(1000), hash: EmptyFingerprint) ..
  SyncID(time: Timestamp(2000), hash: EmptyFingerprint)

proc exampleIds(rng: var Rand): seq[SyncID] =
  ## The SyncIDs of the WAKU-SYNC split example, in order (two share timestamp
  ## 1002), plus IDs at 1600 to 1800 so that the rest of a split is larger than
  ## the fingerprint range that replaces it.
  @[1000'i64, 1002, 1002, 1003, 1500, 1600, 1700, 1800]
    .mapIt(SyncID(time: Timestamp(it), hash: randomHash(rng)))
    .sorted(
      proc(x, y: SyncID): int =
        cmp(x, y)
    )

proc idsAt(times: openArray[int], rng: var Rand): seq[SyncID] =
  ## SyncIDs at `times`, which must be in increasing order.
  times.mapIt(SyncID(time: Timestamp(it), hash: randomHash(rng)))

func span(a, b: int64): Slice[SyncID] =
  SyncID(time: Timestamp(a), hash: EmptyFingerprint) ..
    SyncID(time: Timestamp(b), hash: EmptyFingerprint)

proc exampleStorage(
    ids: seq[SyncID], frameSizeLimit = DefaultMaxPayloadSize
): SeqStorage =
  SeqStorage.new(
    ids, newSeqWith(ids.len, DefaultPubsubTopic), frameSizeLimit = frameSizeLimit
  )

proc answer(storage: SeqStorage, payload: RangesData): (RangesData, seq[Fingerprint]) =
  ## The reply of `storage` to `payload`, and the hashes that it sends.
  var
    hashToSend: seq[Fingerprint]
    idsToRecv: seq[SyncID]
  let reply = storage.processPayload(payload, hashToSend, idsToRecv)
  (reply, hashToSend)

proc bytesLeftFor(ids: seq[SyncID], fitting: int): int =
  ## Bytes for the item set of the first `fitting` SyncIDs and the fingerprint
  ## after it, plus fewer bytes than one more SyncID takes.
  listingSize(ids[0 ..< fitting]) + maxEncodedRangeSize(RangeType.Fingerprint) + 10

proc splitReply(
    storage: SeqStorage, theirs: seq[SyncID], frameBytesLeft: int, mustAnswer: bool
): (bool, RangesData, seq[Fingerprint], seq[SyncID]) =
  ## The reply to an unreconciled item set of `theirs` over ExampleBounds.
  var
    hashToSend: seq[Fingerprint]
    idsToRecv: seq[SyncID]
    output: RangesData
    frameBytesLeft = frameBytesLeft
  let answered = storage.processItemSetRange(
    ExampleBounds,
    initPackedSet[int](),
    ItemSet(elements: theirs, reconciled: false),
    hashToSend,
    idsToRecv,
    output,
    frameBytesLeft,
    mustAnswer,
  )
  (answered, output, hashToSend, idsToRecv)

suite "Waku Sync Storage":
  test "process hash range":
    var rng = initRand()
    let count = 10_000
    var elements = newSeqOfCap[SyncID](count)
    var pubsub = newSeqOfCap[PubsubTopic](count)

    var emptySet = @[0].toPackedSet()
    emptySet.excl(0)

    for i in 0 ..< count:
      let id = SyncID(time: Timestamp(i), hash: randomHash(rng))

      elements.add(id)
      pubsub.add(DefaultPubsubTopic)

    var storage1 = SeqStorage.new(elements, pubsub)
    var storage2 = SeqStorage.new(elements, pubsub)

    let lb = elements[0]
    let ub = elements[count - 1]
    let bounds = lb .. ub
    let fingerprint1 = storage1.computeFingerprint(bounds, @[])

    var
      outputPayload: RangesData
      frameBytesLeft = DefaultMaxPayloadSize

    storage2.processFingerprintRange(
      bounds, emptySet, fingerprint1, outputPayload, frameBytesLeft
    )

    let expected =
      RangesData(ranges: @[(bounds, RangeType.Skip)], fingerprints: @[], itemSets: @[])

    check:
      outputPayload == expected

  test "process item set range":
    var rng = initRand()
    let count = 1000
    var elements1 = newSeqOfCap[SyncID](count)
    var elements2 = newSeqOfCap[SyncID](count)
    var pubsub = newSeqOfCap[PubsubTopic](count)

    var emptySet = @[0].toPackedSet()
    emptySet.excl(0)

    var diffs: seq[Fingerprint]

    for i in 0 ..< count:
      let id = SyncID(time: Timestamp(i), hash: randomHash(rng))

      elements1.add(id)
      if rng.rand(0 .. 9) == 0:
        elements2.add(id)
      else:
        diffs.add(id.hash)

      pubsub.add(DefaultPubsubTopic)

    var storage1 = SeqStorage.new(elements1, pubsub)

    let lb = elements1[0]
    let ub = elements1[count - 1]
    let bounds = lb .. ub

    let itemSet2 = ItemSet(elements: elements2, reconciled: true)

    var
      toSend: seq[Fingerprint]
      toRecv: seq[Fingerprint]
      outputPayload: RangesData

    storage1.processItemSetRange(
      bounds, emptySet, itemSet2, toSend, toRecv, outputPayload
    )

    check:
      toSend == diffs

  test "processPayload returns the ids to receive":
    var rng = initRand()
    let
      held = SyncID(time: Timestamp(1000), hash: randomHash(rng))
      promised = SyncID(time: Timestamp(2000), hash: randomHash(rng))
      storage = SeqStorage.new(@[held], @[DefaultPubsubTopic])
      bounds =
        SyncID(time: Timestamp(0), hash: EmptyFingerprint) ..
        SyncID(time: Timestamp(3000), hash: EmptyFingerprint)
      payload = RangesData(
        cluster: 0,
        shards: @[],
        ranges: @[(bounds, RangeType.ItemSet)],
        fingerprints: @[],
        itemSets: @[ItemSet(elements: @[held, promised], reconciled: true)],
      )

    var
      idsToSend: seq[SyncID]
      idsToRecv: seq[SyncID]

    discard storage.processPayload(payload, idsToSend, idsToRecv)

    check:
      idsToSend.len == 0
      idsToRecv == @[promised]

  test "processPayload returns every id the peer holds in a range we hold nothing in":
    var rng = initRand()
    let
      first = SyncID(time: Timestamp(1000), hash: randomHash(rng))
      second = SyncID(time: Timestamp(2000), hash: randomHash(rng))
      storage = SeqStorage.new(10)
      bounds =
        SyncID(time: Timestamp(0), hash: EmptyFingerprint) ..
        SyncID(time: Timestamp(3000), hash: EmptyFingerprint)
      payload = RangesData(
        cluster: 0,
        shards: @[],
        ranges: @[(bounds, RangeType.ItemSet)],
        fingerprints: @[],
        itemSets: @[ItemSet(elements: @[first, second], reconciled: true)],
      )

    var
      idsToSend: seq[SyncID]
      idsToRecv: seq[SyncID]

    discard storage.processPayload(payload, idsToSend, idsToRecv)

    check:
      idsToSend.len == 0
      idsToRecv == @[first, second]

  test "a range under the threshold whose item set does not fit is divided":
    var rng = initRand()
    let
      # 7 elements in the first 100 ns partition and 6 in the second, none on a bound.
      elements = idsAt(toSeq(0 ..< 50).mapIt(1001 + 16 * it), rng)
      # Room for the first partition's item set, not for the second one's.
      storage = exampleStorage(
        elements,
        frameLeaving(
          listingSize(elements[0 ..< 7]) + listingSize(elements[7 ..< 13]) div 2
        ),
      )
      payload = RangesData(
        ranges: @[(span(1000, 1800), RangeType.Fingerprint)],
        fingerprints: @[randomHash(rng)],
      )
      (reply, _) = storage.answer(payload)

    check:
      reply.ranges.len == 8
      reply.ranges[0][1] == RangeType.ItemSet
      reply.ranges[1 ..^ 1].allIt(it[1] == RangeType.Fingerprint)
      reply.itemSets.mapIt(it.elements.len) == @[7]

  test "an unreconciled item set whose reply does not fit is split at a timestamp change":
    var rng = initRand()
    let
      ids = exampleIds(rng)
      storage = exampleStorage(ids)
      c = SyncID(time: Timestamp(1003), hash: EmptyFingerprint)
      (answered, output, hashToSend, idsToRecv) =
        storage.splitReply(@[], bytesLeftFor(ids, 3), mustAnswer = false)

    check:
      answered
      output.ranges ==
        @[
          (ExampleBounds.a .. c, RangeType.ItemSet),
          (c .. ExampleBounds.b, RangeType.Fingerprint),
        ]
      output.itemSets == @[ItemSet(elements: ids[0 ..< 3], reconciled: true)]
      output.fingerprints == @[storage.computeFingerprint(c .. ExampleBounds.b, @[])]
      hashToSend == ids[0 ..< 3].mapIt(it.hash)
      idsToRecv.len == 0

  test "a cutoff inside one timestamp moves back to the start of that timestamp":
    var rng = initRand()
    let
      ids = exampleIds(rng)
      storage = exampleStorage(ids)
      c = SyncID(time: Timestamp(1002), hash: EmptyFingerprint)
      # Two fit, but both SyncIDs at 1002 must be on the same side of the cutoff.
      (answered, output, hashToSend, _) =
        storage.splitReply(@[], bytesLeftFor(ids, 2), mustAnswer = false)

    check:
      answered
      output.ranges ==
        @[
          (ExampleBounds.a .. c, RangeType.ItemSet),
          (c .. ExampleBounds.b, RangeType.Fingerprint),
        ]
      output.itemSets == @[ItemSet(elements: ids[0 ..< 1], reconciled: true)]
      hashToSend == @[ids[0].hash]

  test "a first timestamp that does not fit is listed only when the range must be answered":
    var rng = initRand()
    let
      ids = exampleIds(rng)
      storage = exampleStorage(ids)
      c = SyncID(time: Timestamp(1002), hash: EmptyFingerprint)
      tooFewBytes = maxEncodedRangeSize(RangeType.Fingerprint) + 10
      (skipped, skippedOutput, skippedSend, _) =
        storage.splitReply(@[], tooFewBytes, mustAnswer = false)
      (answered, output, _, _) = storage.splitReply(@[], tooFewBytes, mustAnswer = true)

    check:
      not skipped
      skippedOutput.ranges.len == 0
      skippedSend.len == 0
      answered
      output.ranges[0] == (ExampleBounds.a .. c, RangeType.ItemSet)
      output.itemSets == @[ItemSet(elements: ids[0 ..< 1], reconciled: true)]

  test "differences at or above the cutoff are left for a later round":
    var rng = initRand()
    let
      ids = exampleIds(rng)
      storage = exampleStorage(ids)
      # The peer holds one SyncID below the cutoff (1003) and one above it.
      below = SyncID(time: Timestamp(1001), hash: randomHash(rng))
      above = SyncID(time: Timestamp(1600), hash: randomHash(rng))
      (answered, _, hashToSend, idsToRecv) =
        storage.splitReply(@[below, above], bytesLeftFor(ids, 3), mustAnswer = false)

    check:
      answered
      hashToSend == ids[0 ..< 3].mapIt(it.hash)
      idsToRecv == @[below]

  test "a reply stops at the first range whose answer does not fit":
    var rng = initRand()
    let
      inFirst = idsAt(toSeq(0 ..< 5).mapIt(1001 + 200 * it), rng)
      inSecond = idsAt(toSeq(0 ..< 50).mapIt(2001 + 16 * it), rng)
      inThird = idsAt(toSeq(0 ..< 10).mapIt(3001 + 50 * it), rng)
      # Room for the first two answers, and too little for the third one's.
      frame =
        frameLeaving(maxEncodedRangeSize(RangeType.Skip) + listingSize(inFirst) + 100)
      storage = exampleStorage(inFirst & inSecond & inThird, frame)
      # The WAKU-SYNC stop example: Skip, three mismatching fingerprints, Skip.
      payload = RangesData(
        ranges: @[
          (span(0, 1000), RangeType.Skip),
          (span(1000, 2000), RangeType.Fingerprint),
          (span(2000, 3000), RangeType.Fingerprint),
          (span(3000, 4000), RangeType.Fingerprint),
          (span(4000, 5000), RangeType.Skip),
        ],
        fingerprints: @[randomHash(rng), randomHash(rng), randomHash(rng)],
      )
      (reply, _) = storage.answer(payload)

    check:
      reply.ranges ==
        @[
          (span(0, 1000), RangeType.Skip),
          (span(1000, 2000), RangeType.ItemSet),
          (span(2000, 5000), RangeType.Fingerprint),
        ]
      reply.itemSets == @[ItemSet(elements: inFirst, reconciled: false)]
      reply.fingerprints == @[storage.computeFingerprint(span(2000, 5000), @[])]
      reply.deltaEncode().len <= frame

  test "a later unreconciled item set is split with the frameBytesLeft that is left":
    var rng = initRand()
    let
      inFirst = idsAt(toSeq(0 ..< 5).mapIt(1001 + 200 * it), rng)
      inSecond = idsAt(toSeq(0 ..< 50).mapIt(2001 + 16 * it), rng)
      inThird = idsAt(toSeq(0 ..< 10).mapIt(3001 + 50 * it), rng)
      # Room for the first answer and about half of the second one's.
      frame = frameLeaving(listingSize(inFirst) + listingSize(inSecond) div 2)
      storage = exampleStorage(inFirst & inSecond & inThird, frame)
      payload = RangesData(
        ranges: @[
          (span(1000, 2000), RangeType.Fingerprint),
          (span(2000, 3000), RangeType.ItemSet),
          (span(3000, 4000), RangeType.Fingerprint),
        ],
        fingerprints: @[randomHash(rng), randomHash(rng)],
        itemSets: @[ItemSet(elements: @[], reconciled: false)],
      )
      (reply, hashToSend) = storage.answer(payload)
      listed = reply.itemSets[1].elements

    check:
      reply.ranges.mapIt(it[1]) ==
        @[
          RangeType.ItemSet, RangeType.ItemSet, RangeType.Fingerprint,
          RangeType.Fingerprint,
        ]
      reply.ranges[1][0].a == span(2000, 3000).a
      reply.ranges[2][0].b == span(2000, 3000).b
      reply.ranges[3][0] == span(3000, 4000)
      reply.itemSets[1].reconciled
      listed.len > 0
      listed == inSecond[0 ..< listed.len]
      hashToSend == listed.mapIt(it.hash)
      reply.deltaEncode().len <= frame

  test "only the first range that is not Skip may go over the frame size limit":
    var rng = initRand()
    let
      inShort = idsAt(@[1000, 1001, 1002, 1003], rng)
      inLong = idsAt(toSeq(0 ..< 10).mapIt(1101 + 50 * it), rng)
      storage = exampleStorage(inShort & inLong, frameLeaving(10))
      # The first range is too short to divide, so it is listed anyway.
      payload = RangesData(
        ranges: @[
          (span(1000, 1004), RangeType.Fingerprint),
          (span(1004, 2000), RangeType.Fingerprint),
        ],
        fingerprints: @[randomHash(rng), randomHash(rng)],
      )
      (reply, _) = storage.answer(payload)

    check:
      reply.ranges ==
        @[
          (span(1000, 1004), RangeType.ItemSet),
          (span(1004, 2000), RangeType.Fingerprint),
        ]
      reply.itemSets == @[ItemSet(elements: inShort, reconciled: false)]
      reply.fingerprints == @[storage.computeFingerprint(span(1004, 2000), @[])]

  test "a fingerprint over a pubsub topic with no local message is empty":
    var rng = initRand()
    let
      element = SyncID(time: Timestamp(1000), hash: randomHash(rng))
      storage = SeqStorage.new(@[element], @["/waku/2/rs/0/1"])
      bounds =
        SyncID(time: Timestamp(0), hash: EmptyFingerprint) ..
        SyncID(time: Timestamp(2000), hash: EmptyFingerprint)

    check storage.computeFingerprint(bounds, @["/waku/2/rs/0/2"]) == EmptyFingerprint

  test "a pending element is in the fingerprint of every pubsub scope":
    var rng = initRand()
    let
      onShard1 = SyncID(time: Timestamp(1000), hash: randomHash(rng))
      pending = SyncID(time: Timestamp(2000), hash: randomHash(rng))
      storage =
        SeqStorage.new(@[onShard1, pending], @["/waku/2/rs/0/1", PendingPubsubTopic])
      bounds =
        SyncID(time: Timestamp(0), hash: EmptyFingerprint) ..
        SyncID(time: Timestamp(3000), hash: EmptyFingerprint)
      allTopics = storage.computeFingerprint(bounds, @[])

    check:
      allTopics != pending.hash
      storage.computeFingerprint(bounds, @["/waku/2/rs/0/1"]) == allTopics
      storage.computeFingerprint(bounds, @["/waku/2/rs/0/2"]) == pending.hash

  test "insert new element":
    var rng = initRand()

    let storage = SeqStorage.new(10)

    let element1 = SyncID(time: Timestamp(1000), hash: randomHash(rng))
    let element2 = SyncID(time: Timestamp(2000), hash: randomHash(rng))

    let res1 = storage.insert(element1, DefaultPubsubTopic)
    assert res1.isOk(), $res1.error
    let count1 = storage.length()

    let res2 = storage.insert(element2, DefaultPubsubTopic)
    assert res2.isOk(), $res2.error
    let count2 = storage.length()

    check:
      count1 == 1
      count2 == 2

  test "insert duplicate":
    var rng = initRand()

    let element = SyncID(time: Timestamp(1000), hash: randomHash(rng))

    let storage = SeqStorage.new(@[element], @[DefaultPubsubTopic])

    let res = storage.insert(element, DefaultPubsubTopic)

    check:
      res.isErr() == false
      storage.length() == 1

  test "remove an element":
    var rng = initRand()
    let
      element1 = SyncID(time: Timestamp(1000), hash: randomHash(rng))
      element2 = SyncID(time: Timestamp(2000), hash: randomHash(rng))
      storage =
        SeqStorage.new(@[element1, element2], @[DefaultPubsubTopic, DefaultPubsubTopic])
      bounds =
        SyncID(time: Timestamp(0), hash: EmptyFingerprint) ..
        SyncID(time: Timestamp(3000), hash: EmptyFingerprint)

    let res = storage.remove(element1)
    assert res.isOk(), $res.error

    check:
      storage.length() == 1
      storage.computeFingerprint(bounds, @[]) == element2.hash

  test "removing an absent element changes nothing":
    var rng = initRand()
    let
      element = SyncID(time: Timestamp(1000), hash: randomHash(rng))
      absent = SyncID(time: Timestamp(2000), hash: randomHash(rng))
      storage = SeqStorage.new(@[element], @[DefaultPubsubTopic])
      bounds =
        SyncID(time: Timestamp(0), hash: EmptyFingerprint) ..
        SyncID(time: Timestamp(3000), hash: EmptyFingerprint)

    let res = storage.remove(absent)
    assert res.isOk(), $res.error

    check:
      storage.length() == 1
      storage.computeFingerprint(bounds, @[]) == element.hash

  test "contains finds only an element with the same time and hash":
    var rng = initRand()
    let
      element = SyncID(time: Timestamp(1000), hash: randomHash(rng))
      storage = SeqStorage.new(@[element], @[DefaultPubsubTopic])

    check:
      storage.contains(element)
      not storage.contains(SyncID(time: Timestamp(1000), hash: randomHash(rng)))
      not storage.contains(SyncID(time: Timestamp(2000), hash: element.hash))
      not storage.contains(SyncID(time: Timestamp(500), hash: element.hash))

  test "prune elements":
    var rng = initRand()
    let count = 1000
    var elements = newSeqOfCap[SyncID](count)
    var pubsub = newSeqOfCap[PubsubTopic](count)

    var emptySet = @[0].toPackedSet()
    emptySet.excl(0)

    for i in 0 ..< count:
      let id = SyncID(time: Timestamp(i), hash: randomHash(rng))

      elements.add(id)
      pubsub.add(DefaultPubsubTopic)

    let storage = SeqStorage.new(elements, pubsub)

    let beforeCount = storage.length()

    let pruned = storage.prune(Timestamp(500))

    let afterCount = storage.length()

    check:
      beforeCount == 1000
      pruned == 500
      afterCount == 500

  test "topics recycling":
    var rng = initRand()
    let count = 1000
    var elements = newSeqOfCap[SyncID](count)
    var pubsub = newSeqOfCap[PubsubTopic](count)

    for i in 0 ..< (count div 2):
      let id = SyncID(time: Timestamp(i), hash: randomHash(rng))

      elements.add(id)
      pubsub.add("/waku/2/rs/0/1")

    for i in (count div 2) ..< count:
      let id = SyncID(time: Timestamp(i), hash: randomHash(rng))

      elements.add(id)
      pubsub.add(DefaultPubsubTopic)

    let storage = SeqStorage.new(elements, pubsub)

    let beforeCount = storage.unusedPubsubTopicsLen()

    let pruned = storage.prune(Timestamp(500))

    let afterCount = storage.unusedPubsubTopicsLen()

    check:
      beforeCount == 0
      pruned == 500
      afterCount == 1

    let id = SyncID(time: Timestamp(1001), hash: randomHash(rng))
    let res = storage.insert(id, "/waku/2/rs/0/2")
    assert res.isOk(), $res.error

    check:
      storage.unusedPubsubTopicsLen() == 0
      storage.pubsubTopicsLen() == 2

  ## disabled tests are rough benchmark 
  #[ test "10M fingerprint":
    var rng = initRand()

    let count = 10_000_000

    var elements = newSeqOfCap[SyncID](count)

    for i in 0 .. count:
      let id = SyncID(time: Timestamp(i), hash: randomHash(rng))

      elements.add(id)

    let storage = SeqStorage.new(elements)

    let before = getMonoTime()

    discard storage.fingerprinting(Opt.some(0 .. count))

    let after = getMonoTime()

    echo "Fingerprint Time: " & $(after - before) ]#

  #[ test "random inserts":
    var rng = initRand()

    let count = 10_000_000

    var elements = newSeqOfCap[SyncID](count)

    for i in 0 .. count:
      let id = SyncID(time: Timestamp(i), hash: randomHash(rng))

      elements.add(id)

    var storage = SeqStorage.new(elements)

    var avg: times.Duration
    for i in 0 ..< 1000:
      let newId =
        SyncID(time: Timestamp(rng.rand(0 .. count)), hash: randomHash(rng))

      let before = getMonoTime()

      discard storage.insert(newId)

      let after = getMonoTime()

      avg += after - before

    avg = avg div 1000

    echo "Avg Time 1K Inserts: " & $avg ]#

  #[ test "trim":
    var rng = initRand()

    let count = 10_000_000

    var elements = newSeqOfCap[SyncID](count)

    for i in 0 .. count:
      let id = SyncID(time: Timestamp(i), hash: randomHash(rng))

      elements.add(id)

    var storage = SeqStorage.new(elements)

    let before = getMonoTime()

    discard storage.trim(Timestamp(count div 4))

    let after = getMonoTime()

    echo "Trim Time: " & $(after - before) ]#

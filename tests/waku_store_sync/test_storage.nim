{.used.}

import results, std/[random, sequtils, packedsets], testutils/unittests, chronos

import
  ../../logos_delivery/waku/waku_core,
  ../../logos_delivery/waku/waku_store_sync/common,
  ../../logos_delivery/waku/waku_store_sync/storage/seq_storage,
  ./sync_utils

suite "Waku Sync Storage":
  test "process hash range":
    var rng = initRand()
    let count = 10_000
    var elements = newSeqOfCap[SyncID](count)
    var pubsub = newSeqOfCap[PubsubTopic](count)
    var content = newSeqOfCap[ContentTopic](count)

    var emptySet = @[0].toPackedSet()
    emptySet.excl(0)

    for i in 0 ..< count:
      let id = SyncID(time: Timestamp(i), hash: randomHash(rng))

      elements.add(id)
      pubsub.add(DefaultPubsubTopic)
      content.add(DefaultContentTopic)

    var storage1 = SeqStorage.new(elements, pubsub, content)
    var storage2 = SeqStorage.new(elements, pubsub, content)

    let lb = elements[0]
    let ub = elements[count - 1]
    let bounds = lb .. ub
    let fingerprint1 = storage1.computeFingerprint(bounds, @[], @[])

    var outputPayload: RangesData

    storage2.processFingerprintRange(
      bounds, emptySet, emptySet, fingerprint1, outputPayload
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
    var content = newSeqOfCap[ContentTopic](count)

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
      content.add(DefaultContentTopic)

    var storage1 = SeqStorage.new(elements1, pubsub, content)

    let lb = elements1[0]
    let ub = elements1[count - 1]
    let bounds = lb .. ub

    let itemSet2 = ItemSet(elements: elements2, reconciled: true)

    var
      toSend: seq[Fingerprint]
      toRecv: seq[Fingerprint]
      outputPayload: RangesData

    storage1.processItemSetRange(
      bounds, emptySet, emptySet, itemSet2, toSend, toRecv, outputPayload
    )

    check:
      toSend == diffs

  test "processPayload returns the ids to receive":
    var rng = initRand()
    let
      held = SyncID(time: Timestamp(1000), hash: randomHash(rng))
      promised = SyncID(time: Timestamp(2000), hash: randomHash(rng))
      storage = SeqStorage.new(@[held], @[DefaultPubsubTopic], @[DefaultContentTopic])
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
      hashToSend: seq[Fingerprint]
      idsToRecv: seq[SyncID]

    discard storage.processPayload(payload, hashToSend, idsToRecv)

    check:
      hashToSend.len == 0
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
      hashToSend: seq[Fingerprint]
      idsToRecv: seq[SyncID]

    discard storage.processPayload(payload, hashToSend, idsToRecv)

    check:
      hashToSend.len == 0
      idsToRecv == @[first, second]

  test "a fingerprint over a pubsub topic with no local message is empty":
    var rng = initRand()
    let
      element = SyncID(time: Timestamp(1000), hash: randomHash(rng))
      storage = SeqStorage.new(@[element], @["/waku/2/rs/0/1"], @[DefaultContentTopic])
      bounds =
        SyncID(time: Timestamp(0), hash: EmptyFingerprint) ..
        SyncID(time: Timestamp(2000), hash: EmptyFingerprint)

    check storage.computeFingerprint(bounds, @["/waku/2/rs/0/2"], @[]) ==
      EmptyFingerprint

  test "a pending element is in the fingerprint of every pubsub scope":
    var rng = initRand()
    let
      onShard1 = SyncID(time: Timestamp(1000), hash: randomHash(rng))
      pending = SyncID(time: Timestamp(2000), hash: randomHash(rng))
      storage = SeqStorage.new(
        @[onShard1, pending],
        @["/waku/2/rs/0/1", PendingPubsubTopic],
        @[DefaultContentTopic, ""],
      )
      bounds =
        SyncID(time: Timestamp(0), hash: EmptyFingerprint) ..
        SyncID(time: Timestamp(3000), hash: EmptyFingerprint)
      allTopics = storage.computeFingerprint(bounds, @[], @[])

    check:
      allTopics != pending.hash
      storage.computeFingerprint(bounds, @["/waku/2/rs/0/1"], @[]) == allTopics
      storage.computeFingerprint(bounds, @["/waku/2/rs/0/2"], @[]) == pending.hash

  test "insert new element":
    var rng = initRand()

    let storage = SeqStorage.new(10)

    let element1 = SyncID(time: Timestamp(1000), hash: randomHash(rng))
    let element2 = SyncID(time: Timestamp(2000), hash: randomHash(rng))

    let res1 = storage.insert(element1, DefaultPubsubTopic, DefaultContentTopic)
    assert res1.isOk(), $res1.error
    let count1 = storage.length()

    let res2 = storage.insert(element2, DefaultPubsubTopic, DefaultContentTopic)
    assert res2.isOk(), $res2.error
    let count2 = storage.length()

    check:
      count1 == 1
      count2 == 2

  test "insert duplicate":
    var rng = initRand()

    let element = SyncID(time: Timestamp(1000), hash: randomHash(rng))

    let storage =
      SeqStorage.new(@[element], @[DefaultPubsubTopic], @[DefaultContentTopic])

    let res = storage.insert(element, DefaultPubsubTopic, DefaultContentTopic)

    check:
      res.isErr() == false
      storage.length() == 1

  test "remove an element":
    var rng = initRand()
    let
      element1 = SyncID(time: Timestamp(1000), hash: randomHash(rng))
      element2 = SyncID(time: Timestamp(2000), hash: randomHash(rng))
      storage = SeqStorage.new(
        @[element1, element2],
        @[DefaultPubsubTopic, DefaultPubsubTopic],
        @[DefaultContentTopic, DefaultContentTopic],
      )
      bounds =
        SyncID(time: Timestamp(0), hash: EmptyFingerprint) ..
        SyncID(time: Timestamp(3000), hash: EmptyFingerprint)

    let res = storage.remove(element1)
    assert res.isOk(), $res.error

    check:
      storage.length() == 1
      storage.computeFingerprint(bounds, @[], @[]) == element2.hash

  test "removing an absent element changes nothing":
    var rng = initRand()
    let
      element = SyncID(time: Timestamp(1000), hash: randomHash(rng))
      absent = SyncID(time: Timestamp(2000), hash: randomHash(rng))
      storage =
        SeqStorage.new(@[element], @[DefaultPubsubTopic], @[DefaultContentTopic])
      bounds =
        SyncID(time: Timestamp(0), hash: EmptyFingerprint) ..
        SyncID(time: Timestamp(3000), hash: EmptyFingerprint)

    let res = storage.remove(absent)
    assert res.isOk(), $res.error

    check:
      storage.length() == 1
      storage.computeFingerprint(bounds, @[], @[]) == element.hash

  test "prune elements":
    var rng = initRand()
    let count = 1000
    var elements = newSeqOfCap[SyncID](count)
    var pubsub = newSeqOfCap[PubsubTopic](count)
    var content = newSeqOfCap[ContentTopic](count)

    var emptySet = @[0].toPackedSet()
    emptySet.excl(0)

    for i in 0 ..< count:
      let id = SyncID(time: Timestamp(i), hash: randomHash(rng))

      elements.add(id)
      pubsub.add(DefaultPubsubTopic)
      content.add(DefaultContentTopic)

    let storage = SeqStorage.new(elements, pubsub, content)

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
    var content = newSeqOfCap[ContentTopic](count)

    var emptySet = @[0].toPackedSet()
    emptySet.excl(0)

    for i in 0 ..< (count div 2):
      let id = SyncID(time: Timestamp(i), hash: randomHash(rng))

      elements.add(id)
      pubsub.add(DefaultPubsubTopic)
      content.add("my/custom/topic")

    for i in (count div 2) ..< count:
      let id = SyncID(time: Timestamp(i), hash: randomHash(rng))

      elements.add(id)
      pubsub.add(DefaultPubsubTopic)
      content.add(DefaultContentTopic)

    let storage = SeqStorage.new(elements, pubsub, content)

    let beforeCount = storage.unusedContentTopicsLen()

    let pruned = storage.prune(Timestamp(500))

    let afterCount = storage.unusedContentTopicsLen()

    check:
      beforeCount == 0
      pruned == 500
      afterCount == 1

    let id = SyncID(time: Timestamp(1001), hash: randomHash(rng))
    let res = storage.insert(id, DefaultPubsubTopic, "my/other/topic")
    assert res.isOk(), $res.error

    let reuseCount = storage.unusedContentTopicsLen()

    check:
      reuseCount == 0

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

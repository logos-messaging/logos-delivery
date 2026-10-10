{.used.}

import std/random, testutils/unittests, chronos, stew/byteutils

import
  ../../logos_delivery/waku/common/protobuf,
  ../../logos_delivery/waku/waku_core,
  ../../logos_delivery/waku/waku_core/message/digest,
  ../../logos_delivery/waku/waku_core/time,
  ../../logos_delivery/waku/waku_store_sync/common,
  ../../logos_delivery/waku/waku_store_sync/codec,
  ../testlib/wakucore,
  ./sync_utils

proc randomItemSet(count: int, startTime: Timestamp, rng: var Rand): ItemSet =
  var
    elements = newSeqOfCap[SyncID](count)
    lastTime = startTime

  for i in 0 ..< count:
    let diff = rng.rand(9.uint8) + 1

    let timestamp = lastTime + diff * 1_000
    lastTime = timestamp

    let hash = randomHash(rng)

    let id = SyncID(time: Timestamp(timestamp), hash: hash)

    elements.add(id)

  return ItemSet(elements: elements, reconciled: true)

proc randomSetRange(
    count: int, startTime: Timestamp, rng: var Rand
): (Slice[SyncID], ItemSet) =
  let itemSet = randomItemSet(count, startTime, rng)

  var
    lb = itemSet.elements[0]
    ub = itemSet.elements[^1]

  #for test check equality
  lb.hash = EmptyWakuMessageHash
  ub.hash = EmptyWakuMessageHash

  let bounds = lb .. ub

  return (bounds, itemSet)

suite "Waku Store Sync Codec":
  test "empty item set encoding roundtrip":
    var origItemSet = ItemSet()

    origItemSet.reconciled = true

    var encodedSet = origItemSet.deltaEncode()

    var itemSet = ItemSet()
    let _ = deltaDecode(itemSet, encodedSet, 0)

    check:
      origItemSet == itemSet

  test "item set encoding roundtrip":
    let
      count = 10
      time = getNowInNanosecondTime()

    var rng = initRand()

    let origItemSet = randomItemSet(count, time, rng)
    var encodedSet = origItemSet.deltaEncode()

    #faking a longer payload
    let pad: seq[byte] =
      @[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    encodedSet &= pad

    var itemSet = ItemSet()
    let _ = deltaDecode(itemSet, encodedSet, count)

    check:
      origItemSet == itemSet

  test "payload item set encoding roundtrip":
    let count = 5

    var
      rng = initRand()
      time = getNowInNanosecondTime()

    let (bounds1, itemSet1) = randomSetRange(count, time, rng)
    let (bounds2, itemSet2) = randomSetRange(count, time + 11_000_000, rng)
    let (bounds3, itemSet3) = randomSetRange(count, time + 21_000_000, rng)
    let (bounds4, itemSet4) = randomSetRange(count, time + 31_000_000, rng)

    let range1 = (bounds1, RangeType.ItemSet)
    let range2 = (bounds2, RangeType.ItemSet)
    let range3 = (bounds3, RangeType.ItemSet)
    let range4 = (bounds4, RangeType.ItemSet)

    let payload = RangesData(
      pubsubTopics: @[DefaultPubsubTopic],
      contentTopics: @[],
      ranges: @[range1, range2, range3, range4],
      fingerprints: @[],
      itemSets: @[itemSet1, itemSet2, itemSet3, itemSet4],
    )

    let encodedPayload = payload.deltaEncode()

    let res = RangesData.deltaDecode(encodedPayload)
    assert res.isOk(), $res.error

    let decodedPayload = res.get()

    check:
      payload.ranges[0][0].b == decodedPayload.ranges[0][0].b
      payload.ranges[1][0].b == decodedPayload.ranges[1][0].b
      payload.ranges[2][0].b == decodedPayload.ranges[2][0].b
      payload.ranges[3][0].b == decodedPayload.ranges[3][0].b
      payload.itemSets == decodedPayload.itemSets

  test "payload fingerprint encoding roundtrip":
    let count = 4

    var
      rng = initRand()
      lastTime = getNowInNanosecondTime()
      ranges = newSeqOfCap[(Slice[SyncID], RangeType)](4)

    for i in 0 ..< count:
      let lb = SyncID(time: Timestamp(lastTime), hash: EmptyWakuMessageHash)

      let nowTime = lastTime + 10_000_000_000 # 10s

      lastTime = nowTime
      let ub = SyncID(time: Timestamp(nowTime), hash: EmptyWakuMessageHash)
      let bounds = lb .. ub
      let range = (bounds, RangeType.Fingerprint)

      ranges.add(range)

    let payload = RangesData(
      pubsubTopics: @[DefaultPubsubTopic],
      contentTopics: @[],
      ranges: ranges,
      fingerprints:
        @[randomHash(rng), randomHash(rng), randomHash(rng), randomHash(rng)],
      itemSets: @[],
    )

    let encodedPayload = payload.deltaEncode()

    let res = RangesData.deltaDecode(encodedPayload)
    assert res.isOk(), $res.error

    let decodedPayload = res.get()

    check:
      payload.ranges[0][0].b == decodedPayload.ranges[0][0].b
      payload.ranges[1][0].b == decodedPayload.ranges[1][0].b
      payload.ranges[2][0].b == decodedPayload.ranges[2][0].b
      payload.ranges[3][0].b == decodedPayload.ranges[3][0].b
      payload.fingerprints == decodedPayload.fingerprints

  test "payload mixed encoding roundtrip":
    let count = 2

    var
      rng = initRand()
      lastTime = getNowInNanosecondTime()
      ranges = newSeqOfCap[(Slice[SyncID], RangeType)](4)
      itemSets = newSeqOfCap[ItemSet](4)
      fingerprints = newSeqOfCap[Fingerprint](4)

    for i in 1 .. count:
      let lb = SyncID(time: Timestamp(lastTime), hash: EmptyWakuMessageHash)
      let nowTime = lastTime + 10_000_000_000 # 10s
      lastTime = nowTime
      let ub = SyncID(time: Timestamp(nowTime), hash: EmptyWakuMessageHash)
      let bounds = lb .. ub
      let range = (bounds, RangeType.Fingerprint)

      ranges.add(range)
      fingerprints.add(randomHash(rng))

      let (bound, itemSet) = randomSetRange(5, lastTime, rng)
      lastTime += 50_000_000_000 # 50s

      ranges.add((bound, RangeType.ItemSet))
      itemSets.add(itemSet)

    let payload = RangesData(
      pubsubTopics: @[DefaultPubsubTopic],
      contentTopics: @[],
      ranges: ranges,
      fingerprints: fingerprints,
      itemSets: itemSets,
    )

    let encodedPayload = payload.deltaEncode()

    let res = RangesData.deltaDecode(encodedPayload)
    assert res.isOk(), $res.error

    let decodedPayload = res.get()

    check:
      payload.ranges[0][0].b == decodedPayload.ranges[0][0].b
      payload.ranges[1][0].b == decodedPayload.ranges[1][0].b
      payload.ranges[2][0].b == decodedPayload.ranges[2][0].b
      payload.ranges[3][0].b == decodedPayload.ranges[3][0].b
      payload.fingerprints == decodedPayload.fingerprints
      payload.itemSets == decodedPayload.itemSets

  test "transfer encoding writes the pubsub topic as field 1 and the message as field 2":
    # TODO: logos-delivery#4483
    let msg = fakeWakuMessage()
    let payload = WakuMessageAndTopic(pubsub: DefaultPubsubTopic, message: msg)

    var expectedPayload = initProtoBuffer()
    expectedPayload.write(1, DefaultPubsubTopic)
    expectedPayload.write(2, msg.encode().buffer)

    check:
      payload.encode().buffer == expectedPayload.buffer

  test "a transfer payload with the pubsub topic as field 1 and the message as field 2 decodes":
    # TODO: logos-delivery#4483
    let msg = fakeWakuMessage()

    var payload = initProtoBuffer()
    payload.write(1, DefaultPubsubTopic)
    payload.write(2, msg.encode().buffer)

    let res = WakuMessageAndTopic.decode(payload.buffer)

    check:
      res.valueOr(WakuMessageAndTopic()) ==
        WakuMessageAndTopic(pubsub: DefaultPubsubTopic, message: msg)

  test "a transfer payload with the message as field 1 and the pubsub topic as field 2 fails to decode":
    # TODO: logos-delivery#4483
    let msg = fakeWakuMessage()

    var payload = initProtoBuffer()
    payload.write(1, msg.encode().buffer)
    payload.write(2, DefaultPubsubTopic)

    let res = WakuMessageAndTopic.decode(payload.buffer)

    check:
      $res == "err(BadWireType)"

  test "reconciliation encoding starts with the pubsub topics, the content topics and the lower bound of the first range":
    # TODO: logos-delivery#4483
    var rng = initRand()

    let
      fingerprint = randomHash(rng)
      lb = SyncID(time: Timestamp(100), hash: EmptyWakuMessageHash)
      ub = SyncID(time: Timestamp(200), hash: EmptyWakuMessageHash)

    let payload = RangesData(
      pubsubTopics: @[DefaultPubsubTopic],
      contentTopics: @[],
      ranges: @[(lb .. ub, RangeType.Fingerprint)],
      fingerprints: @[fingerprint],
      itemSets: @[],
    )

    # The payload is the pubsub topic count and topic, the content topic count, the first
    # range's lower bound, its upper bound as a difference, its range type and its fingerprint.
    let expectedPayload =
      @[byte 1, byte DefaultPubsubTopic.len] & DefaultPubsubTopic.toBytes() &
      @[byte 0, byte 100, byte 100, byte RangeType.Fingerprint] & @fingerprint

    check:
      payload.deltaEncode() == expectedPayload

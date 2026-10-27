{.used.}

import results, stew/byteutils
import std/[random, strutils], testutils/unittests, chronos

import
  ../../logos_delivery/waku/common/protobuf,
  ../../logos_delivery/waku/waku_core,
  ../../logos_delivery/waku/waku_core/message/digest,
  ../../logos_delivery/waku/waku_core/time,
  ../../logos_delivery/waku/waku_store_sync/common,
  ../../logos_delivery/waku/waku_store_sync/codec,
  ../testlib/protobuf_errors,
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
      shards: @[DefaultShardId],
      ranges: @[range1, range2, range3, range4],
      fingerprints: @[],
      itemSets: @[itemSet1, itemSet2, itemSet3, itemSet4],
    )

    let encodedPayload = payload.deltaEncode()

    let res = RangesData.deltaDecode(encodedPayload)
    assert res.isOk(), $res.error

    let decodedPayload = res.get()

    check:
      decodedPayload.ranges[0][1] == RangeType.Skip
      payload.ranges[0][0].b == decodedPayload.ranges[1][0].b
      payload.ranges[1][0].b == decodedPayload.ranges[2][0].b
      payload.ranges[2][0].b == decodedPayload.ranges[3][0].b
      payload.ranges[3][0].b == decodedPayload.ranges[4][0].b
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
      shards: @[DefaultShardId],
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
      decodedPayload.ranges[0][1] == RangeType.Skip
      payload.ranges[0][0].b == decodedPayload.ranges[1][0].b
      payload.ranges[1][0].b == decodedPayload.ranges[2][0].b
      payload.ranges[2][0].b == decodedPayload.ranges[3][0].b
      payload.ranges[3][0].b == decodedPayload.ranges[4][0].b
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
      shards: @[DefaultShardId],
      ranges: ranges,
      fingerprints: fingerprints,
      itemSets: itemSets,
    )

    let encodedPayload = payload.deltaEncode()

    let res = RangesData.deltaDecode(encodedPayload)
    assert res.isOk(), $res.error

    let decodedPayload = res.get()

    check:
      decodedPayload.ranges[0][1] == RangeType.Skip
      payload.ranges[0][0].b == decodedPayload.ranges[1][0].b
      payload.ranges[1][0].b == decodedPayload.ranges[2][0].b
      payload.ranges[2][0].b == decodedPayload.ranges[3][0].b
      payload.ranges[3][0].b == decodedPayload.ranges[4][0].b
      payload.fingerprints == decodedPayload.fingerprints
      payload.itemSets == decodedPayload.itemSets

suite "Waku Store Sync - message codec refusals":
  test "a message without a pubsub topic is refused":
    let res = WakuMessageAndTopic.decode(hexToSeqByte("0a070a010112022f74"))
    check:
      res.isErr()
      res.error == ProtobufError.missingRequiredField("pubsub")

  test "a nested message without a content topic is refused":
    let res = WakuMessageAndTopic.decode(hexToSeqByte("0a030a010112022f73"))
    check:
      res.isErr()
      res.error == ProtobufError.missingRequiredField("content_topic")

suite "Waku Store Sync - transfer payload numbering":
  # The message encodes as 0a0101 (payload 0x01) 12022f74 (content topic "/t"),
  # and the pubsub topic "/s" as 2f73.
  let msg = WakuMessage(payload: @[byte 1], contentTopic: "/t")

  test "a transfer payload is the message as field 1 and the pubsub topic as field 2":
    check WakuMessageAndTopic(pubsub: "/s", message: msg).encode() ==
      hexToSeqByte("0a070a010112022f74" & "12022f73")

  test "a transfer payload numbered as WAKU-SYNC decodes":
    let res =
      WakuMessageAndTopic.decode(hexToSeqByte("0a070a010112022f74" & "12022f73"))
    check:
      res.isOk()
      res.get() == WakuMessageAndTopic(pubsub: "/s", message: msg)

  test "a transfer payload with the pubsub topic as field 1 is refused":
    let res =
      WakuMessageAndTopic.decode(hexToSeqByte("0a022f73" & "12070a010112022f74"))
    check res.isErr()

suite "Waku Store Sync - reconciliation header":
  test "reconciliation encoding starts with the cluster, the shard count and the shards":
    let
      bounds =
        SyncID(time: Timestamp(100), hash: EmptyFingerprint) ..
        SyncID(time: Timestamp(200), hash: EmptyFingerprint)
      payload = RangesData(
        cluster: 2,
        shards: @[3'u16, 300],
        ranges: @[(bounds, RangeType.Fingerprint)],
        fingerprints: @[FullFingerprint],
      )
      encoded = payload.deltaEncode()
      res = RangesData.deltaDecode(encoded)

    check:
      # 300 is the varint ac 02
      encoded[0 ..< 5] == @[byte 2, 2, 3, 0xac, 0x02]
      res.isOk()
      res.get().cluster == 2
      res.get().shards == @[3'u16, 300]

  test "an empty payload is the cluster and the shards only":
    let
      encoded = RangesData(cluster: 2, shards: @[3'u16]).deltaEncode()
      res = RangesData.deltaDecode(encoded)

    check:
      encoded == @[byte 2, 1, 3]
      res.isOk()
      res.get().cluster == 2
      res.get().shards == @[3'u16]
      res.get().ranges.len == 0

  test "a zero-length payload decodes as empty":
    let res = RangesData.deltaDecode(@[])
    check:
      res.isOk()
      res.get().ranges.len == 0

suite "Waku Store Sync - first range":
  let
    zero = SyncID(time: Timestamp(0), hash: EmptyFingerprint)
    at100 = SyncID(time: Timestamp(100), hash: EmptyFingerprint)
    at200 = SyncID(time: Timestamp(200), hash: EmptyFingerprint)
    # cluster 2, one shard, shard 3
    header = @[byte 2, 1, 3]

  test "a payload whose first range does not start at zero begins with a skip range":
    let payload = RangesData(
      cluster: 2,
      shards: @[3'u16],
      ranges: @[(at100 .. at200, RangeType.Fingerprint)],
      fingerprints: @[FullFingerprint],
    )

    # upper bound 100 and Skip, then upper bound 100 later and Fingerprint
    check payload.deltaEncode() == header & @[byte 100, 0, 100, 1] & @FullFingerprint

  test "a payload whose first range starts at zero has no extra skip range":
    let payload = RangesData(
      cluster: 2,
      shards: @[3'u16],
      ranges: @[(zero .. at200, RangeType.Fingerprint)],
      fingerprints: @[FullFingerprint],
    )

    # upper bound 200 (the varint c8 01) and Fingerprint
    check payload.deltaEncode() == header & @[byte 0xc8, 0x01, 1] & @FullFingerprint

  test "the leading skip range decodes as the first range":
    let res = RangesData.deltaDecode(header & @[byte 100, 0, 100, 1] & @FullFingerprint)

    check:
      res.isOk()
      res.get().ranges ==
        @[(zero .. at100, RangeType.Skip), (at100 .. at200, RangeType.Fingerprint)]
      res.get().fingerprints == @[FullFingerprint]

suite "Waku Store Sync - same-timestamp bounds":
  # The WAKU-SYNC example of delta encoding for sequential SyncIDs.
  let
    zero = SyncID(time: Timestamp(0), hash: EmptyFingerprint)
    at1000 = SyncID(
      time: Timestamp(1000), hash: hexToByteArray[32]("4a8a769a" & "00".repeat(28))
    )
    at1002a = SyncID(
      time: Timestamp(1002), hash: hexToByteArray[32]("351c5e86" & "00".repeat(28))
    )
    at1002b = SyncID(
      time: Timestamp(1002), hash: hexToByteArray[32]("3560d9c4" & "00".repeat(28))
    )
    at1003 = SyncID(
      time: Timestamp(1003), hash: hexToByteArray[32]("beabef25" & "00".repeat(28))
    )
    # cluster 2, one shard, shard 3
    header = @[byte 2, 1, 3]

  test "same-timestamp bounds are encoded against the previous bound":
    let payload = RangesData(
      cluster: 2,
      shards: @[3'u16],
      ranges: @[
        (zero .. at1000, RangeType.Skip),
        (at1000 .. at1002a, RangeType.Skip),
        (at1002a .. at1002b, RangeType.Skip),
        (at1002b .. at1003, RangeType.Skip),
      ],
    )

    # 1000 (the varint e8 07), +2, +0 with the hash prefix 35 60, +1; each Skip
    check payload.deltaEncode() ==
      header & @[byte 0xe8, 0x07, 0, 2, 0, 0, 2, 0x35, 0x60, 0, 1, 0]

  test "a range after a same-timestamp bound starts at that bound":
    let res = RangesData.deltaDecode(
      header & @[byte 0xe8, 0x07, 0, 2, 0, 0, 2, 0x35, 0x60, 0, 1, 0]
    )

    # A bound after a time difference has no hash on the wire, and a hash prefix
    # decodes with the remaining bytes zero.
    let
      d1000 = SyncID(time: Timestamp(1000), hash: EmptyFingerprint)
      d1002a = SyncID(time: Timestamp(1002), hash: EmptyFingerprint)
      d1002b = SyncID(
        time: Timestamp(1002), hash: hexToByteArray[32]("3560" & "00".repeat(30))
      )
      d1003 = SyncID(time: Timestamp(1003), hash: EmptyFingerprint)

    check:
      res.isOk()
      res.get().ranges ==
        @[
          (zero .. d1000, RangeType.Skip),
          (d1000 .. d1002a, RangeType.Skip),
          (d1002a .. d1002b, RangeType.Skip),
          (d1002b .. d1003, RangeType.Skip),
        ]

  test "same-timestamp prefixes that grow and shrink keep their order":
    proc at1002(hashHex: string): SyncID =
      SyncID(
        time: Timestamp(1002),
        hash: hexToByteArray[32](hashHex & "00".repeat(32 - hashHex.len div 2)),
      )

    let
      p1 = at1002("351c5e")
      p2 = at1002("3560d9")
      p3 = at1002("3560da")
      p4 = at1002("36")
      d1000 = SyncID(time: Timestamp(1000), hash: EmptyFingerprint)
      d1003 = SyncID(time: Timestamp(1003), hash: EmptyFingerprint)
      payload = RangesData(
        cluster: 2,
        shards: @[3'u16],
        ranges: @[
          (zero .. d1000, RangeType.Skip),
          (d1000 .. p1, RangeType.Skip),
          (p1 .. p2, RangeType.Skip),
          (p2 .. p3, RangeType.Skip),
          (p3 .. p4, RangeType.Skip),
          (p4 .. d1003, RangeType.Skip),
        ],
      )
      # 1000, +2, then prefixes of 2, 3 and 1 bytes, then +1; each Skip
      bytes =
        header &
        @[
          byte 0xe8, 0x07, 0, 2, 0, 0, 2, 0x35, 0x60, 0, 0, 3, 0x35, 0x60, 0xda, 0, 0,
          1, 0x36, 0, 1, 0,
        ]

    let res = RangesData.deltaDecode(bytes)

    # Each prefix decodes with the remaining bytes zero, and still sorts above
    # the previous decoded prefix.
    check:
      payload.deltaEncode() == bytes
      res.isOk()
      res.get().ranges ==
        @[
          (zero .. d1000, RangeType.Skip),
          (d1000 .. at1002(""), RangeType.Skip),
          (at1002("") .. at1002("3560"), RangeType.Skip),
          (at1002("3560") .. at1002("3560da"), RangeType.Skip),
          (at1002("3560da") .. at1002("36"), RangeType.Skip),
          (at1002("36") .. d1003, RangeType.Skip),
        ]

suite "Store sync - codec bounds":
  test "a shard count beyond the payload is refused":
    # Cluster 2, then a shard count of int64.high.
    let res = RangesData.deltaDecode(hexToSeqByte("02ffffffffffffffff7f"))
    check:
      res.isErr()
      res.error == "Cannot decode shard count"

  test "a shard count above 65536 is refused":
    # Cluster 2, a shard count (varints 808004 = 65536, 818004 = 65537), then that
    # many zero shards.
    let
      atLimit = RangesData.deltaDecode(hexToSeqByte("02808004") & newSeq[byte](65536))
      aboveLimit =
        RangesData.deltaDecode(hexToSeqByte("02818004") & newSeq[byte](65537))
    check:
      atLimit.isOk()
      atLimit.get().shards.len == 65536
      aboveLimit.isErr()
      aboveLimit.error == "Cannot decode shard count"

  test "a shard above 65535 is refused":
    # Cluster 2, one shard, then 65536 as a varint.
    let res = RangesData.deltaDecode(hexToSeqByte("0201808004"))
    check:
      res.isErr()
      res.error == "Cannot decode shard. Shard index: 0"

  test "a time that does not fit in a Timestamp is refused":
    # Two items: the time difference int64.high, then 1.
    var itemSet = ItemSet()
    let bytes =
      hexToSeqByte("ffffffffffffffff7f" & "00".repeat(32) & "01" & "00".repeat(40))
    check deltaDecode(itemSet, bytes, 2).isErr()

  test "a range whose upper bound is not above its lower bound is refused":
    # Cluster 2, shard 3, then ranges as (time difference, hash prefix, Skip).
    let
      # (0, 0) as the first upper bound, equal to the implicit lower bound
      firstAtZero = RangesData.deltaDecode(hexToSeqByte("020103" & "000000"))
      # 100, then 100 with the one-byte prefix 00
      equalBound = RangesData.deltaDecode(hexToSeqByte("020103" & "6400" & "00010000"))
      # 100, 100 with prefix 50, then 100 with prefix 40
      lowerHash = RangesData.deltaDecode(
        hexToSeqByte("020103" & "6400" & "00015000" & "00014000")
      )
    for res in [firstAtZero, equalBound, lowerHash]:
      check:
        res.isErr()
        res.error == "Range upper bound is not above its lower bound"

  test "a malformed hash prefix is refused":
    # Cluster 2, shard 3, the upper bound 100 and Skip, then a time difference 0.
    let
      noLength = RangesData.deltaDecode(hexToSeqByte("020103" & "6400" & "00"))
      # a prefix of 33 bytes
      tooLong = RangesData.deltaDecode(
        hexToSeqByte("020103" & "6400" & "0021" & "35".repeat(33) & "00")
      )
      # a prefix of 2 bytes with 1 left in the payload
      truncated = RangesData.deltaDecode(hexToSeqByte("020103" & "6400" & "000235"))
    for res in [noLength, tooLong, truncated]:
      check:
        res.isErr()
        res.error == "Cannot decode hash prefix"

  test "an incomplete shard is refused":
    # Cluster 2, one shard, and nine bytes that all continue.
    let res = RangesData.deltaDecode(hexToSeqByte("0201" & "80".repeat(9)))
    check:
      res.isErr()
      res.error == "Cannot decode shard. Shard index: 0"

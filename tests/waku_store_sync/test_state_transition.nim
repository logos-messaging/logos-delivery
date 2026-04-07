import unittest, nimcrypto, std/sequtils
import ../../waku/waku_store_sync/[reconciliation, common]
import ../../waku/waku_store_sync/storage/seq_storage
import ../../waku/waku_core/message/digest
import ../../waku/waku_core/topics/pubsub_topic
import ../../waku/waku_core/topics/content_topic

proc toDigest*(s: string): WakuMessageHash =
  let d = nimcrypto.keccak256.digest((s & "").toOpenArrayByte(0, s.high))
  for i in 0 .. 31:
    result[i] = d.data[i]

proc `..`(a, b: SyncID): Slice[SyncID] =
  Slice[SyncID](a: a, b: b)

suite "Waku Sync – reconciliation":
  test "Fingerprint → ItemSet → zero  (default thresholds)":
    const N = 2_000
    const idx = 137

    let local = SeqStorage.new(@[], @[], @[])
    let remote = SeqStorage.new(@[], @[], @[])

    var baseH, altH: WakuMessageHash
    for i in 0 ..< N:
      let ts = 1000 + i
      let h = toDigest("msg" & $i)
      discard
        local.insert(SyncID(time: ts, hash: h), DefaultPubsubTopic, DefaultContentTopic)
      var hr = h
      if i == idx:
        baseH = h
        altH = toDigest("msg" & $i & "x")
        hr = altH
      discard remote.insert(
        SyncID(time: ts, hash: hr), DefaultPubsubTopic, DefaultContentTopic
      )

    var z: WakuMessageHash
    let whole = SyncID(time: 1000, hash: z) .. SyncID(time: 1000 + N - 1, hash: z)

    var s1, r1: seq[WakuMessageHash]
    let p1 = RangesData(
      pubsubTopics: @[DefaultPubsubTopic],
      contentTopics: @[DefaultContentTopic],
      ranges: @[(whole, RangeType.Fingerprint)],
      fingerprints: @[
        remote.computeFingerprint(whole, @[DefaultPubsubTopic], @[DefaultContentTopic])
      ],
      itemSets: @[],
    )
    let rep1 = local.processPayload(p1, s1, r1)
    check rep1.ranges.len == 8
    check rep1.ranges.allIt(it[1] == RangeType.Fingerprint)

    let mismT = 1000 + idx
    let sub =
      rep1.ranges.filterIt(mismT >= it[0].a.time and mismT <= it[0].b.time)[0][0]

    var s2, r2: seq[WakuMessageHash]
    let p2 = RangesData(
      pubsubTopics: @[DefaultPubsubTopic],
      contentTopics: @[DefaultContentTopic],
      ranges: @[(sub, RangeType.Fingerprint)],
      fingerprints:
        @[remote.computeFingerprint(sub, @[DefaultPubsubTopic], @[DefaultContentTopic])],
      itemSets: @[],
    )
    let rep2 = local.processPayload(p2, s2, r2)
    check rep2.ranges.len == 8
    check rep2.ranges.allIt(it[1] == RangeType.ItemSet)

    var s3, r3: seq[WakuMessageHash]
    discard remote.processPayload(rep2, s3, r3)
    check s3.len == 1 and s3[0] == altH
    check r3.len == 1 and r3[0] == baseH

    discard local.insert(
      SyncID(time: mismT, hash: altH), DefaultPubsubTopic, DefaultContentTopic
    )
    discard remote.insert(
      SyncID(time: mismT, hash: baseH), DefaultPubsubTopic, DefaultContentTopic
    )

    var s4, r4: seq[WakuMessageHash]
    let p3 = RangesData(
      pubsubTopics: @[DefaultPubsubTopic],
      contentTopics: @[DefaultContentTopic],
      ranges: @[(sub, RangeType.Fingerprint)],
      fingerprints:
        @[remote.computeFingerprint(sub, @[DefaultPubsubTopic], @[DefaultContentTopic])],
      itemSets: @[],
    )
    let rep3 = local.processPayload(p3, s4, r4)
    check rep3.ranges.len == 0
    check s4.len == 0 and r4.len == 0

  test "test 2 ranges includes 1 skip":
    const N = 120
    const pivot = 60

    let local = SeqStorage.new(@[], @[], @[])
    let remote = SeqStorage.new(@[], @[], @[])

    var diffHash: WakuMessageHash
    for i in 0 ..< N:
      let ts = 1000 + i
      let h = toDigest("msg" & $i)
      discard
        local.insert(SyncID(time: ts, hash: h), DefaultPubsubTopic, DefaultContentTopic)
      var hr: WakuMessageHash
      if i >= pivot:
        diffHash = toDigest("msg" & $i & "_x")
        hr = diffHash
      else:
        hr = h

      discard remote.insert(
        SyncID(time: ts, hash: hr), DefaultPubsubTopic, DefaultContentTopic
      )

    var z: WakuMessageHash
    let sliceA = SyncID(time: 1000, hash: z) .. SyncID(time: 1059, hash: z)
    let sliceB = SyncID(time: 1060, hash: z) .. SyncID(time: 1119, hash: z)

    var s, r: seq[WakuMessageHash]
    let payload = RangesData(
      pubsubTopics: @[DefaultPubsubTopic],
      contentTopics: @[DefaultContentTopic],
      ranges: @[(sliceA, RangeType.Fingerprint), (sliceB, RangeType.Fingerprint)],
      fingerprints: @[
        remote.computeFingerprint(sliceA, @[DefaultPubsubTopic], @[DefaultContentTopic]),
        remote.computeFingerprint(sliceB, @[DefaultPubsubTopic], @[DefaultContentTopic]),
      ],
      itemSets: @[],
    )
    let reply = local.processPayload(payload, s, r)

    check reply.ranges.len == 2
    check reply.ranges[0][1] == RangeType.Skip
    check reply.ranges[1][1] == RangeType.ItemSet
    check reply.itemSets.len == 1
    check not reply.itemSets[0].elements.anyIt(it.hash == diffHash)

  test "custom threshold (50) → eight ItemSets first round":
    const N = 300
    const idx = 123

    let local = SeqStorage.new(capacity = N, threshold = 50, partitions = 8)
    let remote = SeqStorage.new(capacity = N, threshold = 50, partitions = 8)

    var baseH, altH: WakuMessageHash
    for i in 0 ..< N:
      let ts = 1000 + i
      let h = toDigest("msg" & $i)
      discard
        local.insert(SyncID(time: ts, hash: h), DefaultPubsubTopic, DefaultContentTopic)
      var hr = h
      if i == idx:
        baseH = h
        altH = toDigest("msg" & $i & "_x")
        hr = altH
      discard remote.insert(
        SyncID(time: ts, hash: hr), DefaultPubsubTopic, DefaultContentTopic
      )

    var z: WakuMessageHash
    let slice = SyncID(time: 1000, hash: z) .. SyncID(time: 1000 + N - 1, hash: z)

    var toS, toR: seq[WakuMessageHash]
    let p = RangesData(
      pubsubTopics: @[DefaultPubsubTopic],
      contentTopics: @[DefaultContentTopic],
      ranges: @[(slice, RangeType.Fingerprint)],
      fingerprints: @[
        remote.computeFingerprint(slice, @[DefaultPubsubTopic], @[DefaultContentTopic])
      ],
      itemSets: @[],
    )
    let reply = local.processPayload(p, toS, toR)

    check reply.ranges.len == 8
    check reply.ranges.allIt(it[1] == RangeType.ItemSet)
    check reply.itemSets.len == 8

    let mismT = 1000 + idx
    var hit = 0
    for ist in reply.itemSets:
      if ist.elements.anyIt(it.time == mismT and it.hash == baseH):
        inc hit
    check hit == 1

  test "test N=80K,3FP,2IS,SKIP":
    const N = 80_000
    const bad = N - 10

    let local = SeqStorage.new(@[], @[], @[])
    let remote = SeqStorage.new(@[], @[], @[])

    var baseH, altH: WakuMessageHash
    for i in 0 ..< N:
      let ts = 1000 + i
      let h = toDigest("msg" & $i)
      discard
        local.insert(SyncID(time: ts, hash: h), DefaultPubsubTopic, DefaultContentTopic)

      let hr =
        if i == bad:
          baseH = h
          altH = toDigest("msg" & $i & "_x")
          altH
        else:
          h
      discard remote.insert(
        SyncID(time: ts, hash: hr), DefaultPubsubTopic, DefaultContentTopic
      )

    var slice =
      SyncID(time: 1000, hash: EmptyFingerprint) ..
      SyncID(time: 1000 + N - 1, hash: FullFingerprint)

    proc fpReply(s: Slice[SyncID], sendQ, recvQ: var seq[WakuMessageHash]): RangesData =
      local.processPayload(
        RangesData(
          pubsubTopics: @[DefaultPubsubTopic],
          contentTopics: @[DefaultContentTopic],
          ranges: @[(s, RangeType.Fingerprint)],
          fingerprints: @[
            remote.computeFingerprint(s, @[DefaultPubsubTopic], @[DefaultContentTopic])
          ],
          itemSets: @[],
        ),
        sendQ,
        recvQ,
      )

    var tmpS, tmpR: seq[WakuMessageHash]

    for r in 1 .. 3:
      let rep = fpReply(slice, tmpS, tmpR)
      check rep.ranges.len == 8
      check rep.ranges.allIt(it[1] == RangeType.Fingerprint)
      for (sl, _) in rep.ranges:
        if local.computeFingerprint(sl, @[DefaultPubsubTopic], @[DefaultContentTopic]) !=
            remote.computeFingerprint(sl, @[DefaultPubsubTopic], @[DefaultContentTopic]):
          slice = sl
          break

    let rep4 = fpReply(slice, tmpS, tmpR)
    check rep4.ranges.len == 8
    check rep4.ranges.allIt(it[1] == RangeType.ItemSet)
    for (sl, _) in rep4.ranges:
      if sl.a.time <= 1000 + bad and sl.b.time >= 1000 + bad:
        slice = sl
        break

    var send5, recv5: seq[WakuMessageHash]
    let rep5 = fpReply(slice, send5, recv5)
    check rep5.ranges.len == 1
    check rep5.ranges[0][1] == RangeType.ItemSet

    var qSend, qRecv: seq[WakuMessageHash]
    discard remote.processPayload(rep5, qSend, qRecv)
    check qSend.len == 1 and qSend[0] == altH
    check qRecv.len == 1 and qRecv[0] == baseH

    discard local.insert(
      SyncID(time: slice.a.time, hash: altH), DefaultPubsubTopic, DefaultContentTopic
    )
    discard remote.insert(
      SyncID(time: slice.a.time, hash: baseH), DefaultPubsubTopic, DefaultContentTopic
    )

    var send6, recv6: seq[WakuMessageHash]
    let rep6 = fpReply(slice, send6, recv6)
    check rep6.ranges.len == 0
    check send6.len == 0 and recv6.len == 0

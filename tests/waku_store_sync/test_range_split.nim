{.used.}

import testutils/unittests, nimcrypto, std/[sequtils, sets], results
import ../../logos_delivery/waku/waku_store_sync/common
import ../../logos_delivery/waku/waku_store_sync/codec
import ../../logos_delivery/waku/waku_store_sync/storage/seq_storage
import ../../logos_delivery/waku/waku_core/message/digest
import ../../logos_delivery/waku/waku_core/topics/pubsub_topic

proc toDigest(s: string): WakuMessageHash =
  let d = nimcrypto.keccak256.digest((s & "").toOpenArrayByte(0, (s.len - 1)))
  var res: WakuMessageHash
  for i in 0 .. 31:
    res[i] = d.data[i]
  return res

proc `..`(a, b: SyncID): Slice[SyncID] =
  Slice[SyncID](a: a, b: b)

suite "Waku Sync: range splitting":
  test "fan-out: eight fingerprint sub-ranges for large slice":
    const N = 2_048
    const mismatchI = 70

    let local = SeqStorage.new(@[], @[])
    let remote = SeqStorage.new(@[], @[])

    var baseHashMismatch: WakuMessageHash
    var remoteHashMismatch: WakuMessageHash

    for i in 0 ..< N:
      let ts = 1000 + i
      let hashLocal = toDigest("msg" & $i)

      local.insert(SyncID(time: ts, hash: hashLocal), DefaultPubsubTopic).isOkOr:
        assert false, "failed to insert hash: " & $error

      var hashRemote = hashLocal
      if i == mismatchI:
        baseHashMismatch = hashLocal
        remoteHashMismatch = toDigest("msg" & $i & "_x")
        hashRemote = remoteHashMismatch

      remote.insert(SyncID(time: ts, hash: hashRemote), DefaultPubsubTopic).isOkOr:
        assert false, "failed to insert hash: " & $error

    var z: WakuMessageHash
    let whole = SyncID(time: 1000, hash: z) .. SyncID(time: 1000 + N - 1, hash: z)

    check local.computeFingerprint(whole, @[DefaultPubsubTopic]) !=
      remote.computeFingerprint(whole, @[DefaultPubsubTopic])

    let remoteFp = remote.computeFingerprint(whole, @[DefaultPubsubTopic])
    let payload = RangesData(
      shards: @[DefaultShardId],
      ranges: @[(whole, RangeType.Fingerprint)],
      fingerprints: @[remoteFp],
      itemSets: @[],
    )

    var toSend, toRecv: seq[WakuMessageHash]
    let reply = local.processPayload(payload, toSend, toRecv)

    check reply.ranges.len == 8
    check reply.ranges.allIt(it[1] == RangeType.Fingerprint)
    check reply.itemSets.len == 0
    check reply.fingerprints.len == 8

    let mismTime = 1000 + mismatchI
    var covered = false
    for (slc, _) in reply.ranges:
      if mismTime >= slc.a.time and mismTime <= slc.b.time:
        covered = true
        break
    check covered

    check toSend.len == 0
    check toRecv.len == 0

  test "splits mismatched fingerprint into two sub-ranges then item-set":
    const threshold = 4
    const partitions = 2

    let local = SeqStorage.new(@[], @[], threshold = threshold, partitions = partitions)
    let remote =
      SeqStorage.new(@[], @[], threshold = threshold, partitions = partitions)

    var mismatchHash: WakuMessageHash
    for i in 0 ..< 8:
      let t = 1000 + i
      let baseHash = toDigest("msg" & $i)

      var localHash = baseHash
      var remoteHash = baseHash

      if i == 3:
        mismatchHash = toDigest("msg" & $i & "_x")
        localHash = mismatchHash

      discard local.insert(SyncID(time: t, hash: localHash), DefaultPubsubTopic)
      discard remote.insert(SyncID(time: t, hash: remoteHash), DefaultPubsubTopic)

    var zeroHash: WakuMessageHash
    let wholeRange =
      SyncID(time: 1000, hash: zeroHash) .. SyncID(time: 1007, hash: zeroHash)

    var toSend, toRecv: seq[WakuMessageHash]

    let payload = RangesData(
      shards: @[DefaultShardId],
      ranges: @[(wholeRange, RangeType.Fingerprint)],
      fingerprints: @[remote.computeFingerprint(wholeRange, @[DefaultPubsubTopic])],
      itemSets: @[],
    )

    let reply = local.processPayload(payload, toSend, toRecv)

    check reply.ranges.len == partitions
    check reply.itemSets.len == partitions

    check reply.itemSets.anyIt(
      it.elements.anyIt(it.hash == mismatchHash and it.time == 1003)
    )

  test "second round when N =2048 & local ":
    const N = 2_048
    const mismatchI = 70

    let local = SeqStorage.new(@[], @[])
    let remote = SeqStorage.new(@[], @[])

    var baseHashMismatch, remoteHashMismatch: WakuMessageHash

    for i in 0 ..< N:
      let ts = 1000 + i
      let hashLocal = toDigest("msg" & $i)

      local.insert(SyncID(time: ts, hash: hashLocal), DefaultPubsubTopic).isOkOr:
        assert false, "failed to insert hash: " & $error

      var hashRemote = hashLocal
      if i == mismatchI:
        baseHashMismatch = hashLocal
        remoteHashMismatch = toDigest("msg" & $i & "_x")
        hashRemote = remoteHashMismatch

        remote.insert(SyncID(time: ts, hash: hashRemote), DefaultPubsubTopic).isOkOr:
          assert false, "failed to insert hash: " & $error

    var zero: WakuMessageHash
    let sliceWhole =
      SyncID(time: 1000, hash: zero) .. SyncID(time: 1000 + N - 1, hash: zero)
    check local.computeFingerprint(sliceWhole, @[DefaultPubsubTopic]) !=
      remote.computeFingerprint(sliceWhole, @[DefaultPubsubTopic])

    let payload1 = RangesData(
      shards: @[DefaultShardId],
      ranges: @[(sliceWhole, RangeType.Fingerprint)],
      fingerprints: @[remote.computeFingerprint(sliceWhole, @[DefaultPubsubTopic])],
      itemSets: @[],
    )

    var toSend, toRecv: seq[WakuMessageHash]
    let reply1 = local.processPayload(payload1, toSend, toRecv)

    check reply1.ranges.len == 8
    check reply1.ranges.allIt(it[1] == RangeType.Fingerprint)

    let mismTime = 1000 + mismatchI
    var subSlice: Slice[SyncID]
    for (sl, _) in reply1.ranges:
      if mismTime >= sl.a.time and mismTime <= sl.b.time:
        subSlice = sl
        break
    check subSlice.a.time != 0

    let payload2 = RangesData(
      shards: @[DefaultShardId],
      ranges: @[(subSlice, RangeType.Fingerprint)],
      fingerprints: @[remote.computeFingerprint(subSlice, @[DefaultPubsubTopic])],
      itemSets: @[],
    )

    var toSend2, toRecv2: seq[WakuMessageHash]
    let reply2 = local.processPayload(payload2, toSend2, toRecv2)

    check reply2.ranges.len == 8
    check reply2.ranges.allIt(it[1] == RangeType.ItemSet)
    check reply2.itemSets.len == 8

    var matchCount = 0
    for iset in reply2.itemSets:
      if iset.elements.anyIt(it.time == mismTime and it.hash == baseHashMismatch):
        inc matchCount
        check not iset.elements.anyIt(it.hash == remoteHashMismatch)
    check matchCount == 1

    check toSend2.len == 0
    check toRecv2.len == 0

  test "second-round payload remote":
    let local = SeqStorage.new(@[], @[])
    let remote = SeqStorage.new(@[], @[])

    var baseHash: WakuMessageHash
    var alteredHash: WakuMessageHash

    for i in 0 ..< 8:
      let ts = 1000 + i
      let hashLocal = toDigest("msg" & $i)

      local.insert(SyncID(time: ts, hash: hashLocal), DefaultPubsubTopic).isOkOr:
        assert false, "failed to insert hash: " & $error

      var hashRemote = hashLocal
      if i == 3:
        baseHash = hashLocal
        alteredHash = toDigest("msg" & $i & "_x")
        hashRemote = alteredHash

      remote.insert(SyncID(time: ts, hash: hashRemote), DefaultPubsubTopic).isOkOr:
        assert false, "failed to insert hash: " & $error

    var zero: WakuMessageHash
    let slice = SyncID(time: 1000, hash: zero) .. SyncID(time: 1007, hash: zero)

    check local.computeFingerprint(slice, @[DefaultPubsubTopic]) !=
      remote.computeFingerprint(slice, @[DefaultPubsubTopic])

    var toSend1, toRecv1: seq[WakuMessageHash]

    let rangeData = RangesData(
      shards: @[DefaultShardId],
      ranges: @[(slice, RangeType.Fingerprint)],
      fingerprints: @[remote.computeFingerprint(slice, @[DefaultPubsubTopic])],
      itemSets: @[],
    )

    let rep1 = local.processPayload(rangeData, toSend1, toRecv1)

    check rep1.ranges.len == 1
    check rep1.ranges[0][1] == RangeType.ItemSet
    check toSend1.len == 0
    check toRecv1.len == 0

    var toSend2, toRecv2: seq[WakuMessageHash]
    discard remote.processPayload(rep1, toSend2, toRecv2)

    check toSend2.len == 1
    check toSend2[0] == alteredHash
    check toRecv2.len == 1
    check toRecv2[0] == baseHash

  test "an empty node gets every ID of a peer that holds more than one frame":
    const
      count = 5_000
      # About 360 IDs per frame, so the peer needs about 14 replies.
      frameSizeLimit = 12_000
      maxRounds = 200

    let
      full = SeqStorage.new(@[], @[], frameSizeLimit = frameSizeLimit)
      empty = SeqStorage.new(@[], @[], frameSizeLimit = frameSizeLimit)

    var all: seq[SyncID]
    # Pairs of IDs share a timestamp.
    for i in 0 ..< count:
      let id = SyncID(time: 1_000_000 + (i div 2) * 7, hash: toDigest("id" & $i))
      full.insert(id, DefaultPubsubTopic).isOkOr:
        assert false, "failed to insert hash: " & $error
      all.add(id)

    # The full node starts the session, as `initiate` does.
    let bounds =
      SyncID(time: 999_000, hash: EmptyFingerprint) ..
      SyncID(time: 1_100_000, hash: FullFingerprint)
    var payload = RangesData(
      shards: @[DefaultShardId],
      ranges: @[(bounds, RangeType.Fingerprint)],
      fingerprints: @[full.computeFingerprint(bounds, @[DefaultPubsubTopic])],
    )

    var
      fromFull = true
      rounds = 0
      # Replies of the full node that list some of its IDs.
      listingReplies = 0
      received: seq[SyncID]
      pushed: seq[SyncID]

    while payload.ranges.anyIt(it[1] != RangeType.Skip) and rounds < maxRounds:
      rounds.inc()

      var
        idsToSend: seq[SyncID]
        idsToRecv: seq[SyncID]

      if fromFull:
        payload = empty.processPayload(payload, idsToSend, idsToRecv)
        check idsToSend.len == 0
        # As `trackPromised` does, so that later rounds do not ask again.
        for id in idsToRecv:
          empty.insert(id, PendingPubsubTopic).isOkOr:
            assert false, "failed to insert pending hash: " & $error
        received.add(idsToRecv)
      else:
        payload = full.processPayload(payload, idsToSend, idsToRecv)
        check idsToRecv.len == 0
        pushed.add(idsToSend)
        if payload.itemSets.anyIt(it.elements.len > 0):
          listingReplies.inc()

      payload.shards = @[DefaultShardId]
      fromFull = not fromFull

      # Every reply, in both directions, fits in the frame of the node that sends it.
      let encoded = payload.deltaEncode()
      check encoded.len <= frameSizeLimit
      payload = RangesData.deltaDecode(encoded).get()

    check:
      rounds < maxRounds
      listingReplies > 1
      received.len == count
      received.toHashSet() == all.toHashSet()
      pushed.len == count
      pushed.toHashSet() == all.toHashSet()

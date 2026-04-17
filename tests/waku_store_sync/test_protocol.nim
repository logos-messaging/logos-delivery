{.used.}

import
  std/[options, sets, random, math, algorithm],
  testutils/unittests,
  chronos,
  libp2p/crypto/crypto
import chronos, chronos/asyncsync
import nimcrypto
import
  ../../waku/[
    node/peer_manager,
    waku_core,
    waku_core/message,
    waku_core/message/digest,
    waku_store_sync/common,
    waku_store_sync/storage/range_processing,
    waku_store_sync/reconciliation,
    waku_store_sync/transfer,
    waku_archive/archive,
    waku_archive/driver,
    waku_archive/common,
  ],
  ../testlib/[wakucore, testasync],
  ../waku_archive/archive_utils,
  ./sync_utils

proc collectDiffs*(
    chan: var Channel[SyncID], diffCount: int
): HashSet[WakuMessageHash] =
  var received: HashSet[WakuMessageHash]
  while received.len < diffCount:
    let sid = chan.recv() # synchronous receive
    received.incl sid.hash
  result = received

suite "Waku Sync: reconciliation":
  var serverSwitch {.threadvar.}: Switch
  var clientSwitch {.threadvar.}: Switch

  var
    idsChannel {.threadvar.}: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)]
    localWants {.threadvar.}: AsyncQueue[PeerId]
    remoteNeeds {.threadvar.}: AsyncQueue[(PeerId, WakuMessageHash)]

  var server {.threadvar.}: SyncReconciliation
  var client {.threadvar.}: SyncReconciliation

  var serverPeerInfo {.threadvar.}: RemotePeerInfo
  var clientPeerInfo {.threadvar.}: RemotePeerInfo

  asyncSetup:
    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    idsChannel = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)]()
    localWants = newAsyncQueue[PeerId]()
    remoteNeeds = newAsyncQueue[(PeerId, WakuMessageHash)]()

    serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    clientPeerInfo = clientSwitch.peerInfo.toRemotePeerInfo()

  asyncTeardown:
    await server.stop()
    await client.stop()

    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "sync 2 nodes both empty":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    check:
      idsChannel.len == 0
      remoteNeeds.len == 0

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), res.error

    check:
      idsChannel.len == 0
      remoteNeeds.len == 0

  asyncTest "sync 2 nodes empty client full server":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    let
      msg1 = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      msg2 = fakeWakuMessage(ts = now() + 1, contentTopic = DefaultContentTopic)
      msg3 = fakeWakuMessage(ts = now() + 2, contentTopic = DefaultContentTopic)
      hash1 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg1)
      hash2 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg2)
      hash3 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg3)

    server.messageIngress(hash1, DefaultPubsubTopic, msg1)
    server.messageIngress(hash2, DefaultPubsubTopic, msg2)
    server.messageIngress(hash3, DefaultPubsubTopic, msg3)

    check:
      remoteNeeds.len == 0
      localWants.len == 0
      remoteNeeds.contains((clientPeerInfo.peerId, hash1)) == false
      remoteNeeds.contains((clientPeerInfo.peerId, hash2)) == false
      remoteNeeds.contains((clientPeerInfo.peerId, hash3)) == false

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), res.error

    check:
      remoteNeeds.len == 3
      remoteNeeds.contains((clientPeerInfo.peerId, hash1)) == true
      remoteNeeds.contains((clientPeerInfo.peerId, hash2)) == true
      remoteNeeds.contains((clientPeerInfo.peerId, hash3)) == true

  asyncTest "sync 2 nodes full client empty server":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    let
      msg1 = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      msg2 = fakeWakuMessage(ts = now() + 1, contentTopic = DefaultContentTopic)
      msg3 = fakeWakuMessage(ts = now() + 2, contentTopic = DefaultContentTopic)
      hash1 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg1)
      hash2 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg2)
      hash3 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg3)

    client.messageIngress(hash1, DefaultPubsubTopic, msg1)
    client.messageIngress(hash2, DefaultPubsubTopic, msg2)
    client.messageIngress(hash3, DefaultPubsubTopic, msg3)

    check:
      remoteNeeds.len == 0
      localWants.len == 0
      remoteNeeds.contains((serverPeerInfo.peerId, hash1)) == false
      remoteNeeds.contains((serverPeerInfo.peerId, hash2)) == false
      remoteNeeds.contains((serverPeerInfo.peerId, hash3)) == false

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), res.error

    check:
      remoteNeeds.len == 3
      remoteNeeds.contains((serverPeerInfo.peerId, hash1)) == true
      remoteNeeds.contains((serverPeerInfo.peerId, hash2)) == true
      remoteNeeds.contains((serverPeerInfo.peerId, hash3)) == true

  asyncTest "sync 2 nodes different hashes":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    let
      msg1 = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      msg2 = fakeWakuMessage(ts = now() + 1, contentTopic = DefaultContentTopic)
      msg3 = fakeWakuMessage(ts = now() + 2, contentTopic = DefaultContentTopic)
      hash1 = computeMessageHash(DefaultPubsubTopic, msg1)
      hash2 = computeMessageHash(DefaultPubsubTopic, msg2)
      hash3 = computeMessageHash(DefaultPubsubTopic, msg3)

    server.messageIngress(hash1, DefaultPubsubTopic, msg1)
    server.messageIngress(hash2, DefaultPubsubTopic, msg2)
    client.messageIngress(hash1, DefaultPubsubTopic, msg1)
    client.messageIngress(hash3, DefaultPubsubTopic, msg3)

    check:
      remoteNeeds.len == 0
      localWants.len == 0
      remoteNeeds.contains((serverPeerInfo.peerId, hash3)) == false
      remoteNeeds.contains((clientPeerInfo.peerId, hash2)) == false

    var syncRes = await client.storeSynchronization(some(serverPeerInfo))
    assert syncRes.isOk(), $syncRes.error

    check:
      remoteNeeds.len == 2
      remoteNeeds.contains((serverPeerInfo.peerId, hash3)) == true
      remoteNeeds.contains((clientPeerInfo.peerId, hash2)) == true

  asyncTest "sync 2 nodes different shards":
    server = await newTestWakuRecon(
      serverSwitch,
      @["/waku/2/rs/2/1", "/waku/2/rs/2/2", "/waku/2/rs/2/3", "/waku/2/rs/2/4"],
      @[DefaultContentTopic],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
    )

    client = await newTestWakuRecon(
      clientSwitch,
      @["/waku/2/rs/2/3", "/waku/2/rs/2/4", "/waku/2/rs/2/5", "/waku/2/rs/2/6"],
      @[DefaultContentTopic],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
    )

    let
      msg1 = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      msg2 = fakeWakuMessage(ts = now() + 1, contentTopic = DefaultContentTopic)
      msg3 = fakeWakuMessage(ts = now() + 2, contentTopic = DefaultContentTopic)
      msg4 = fakeWakuMessage(ts = now() + 3, contentTopic = DefaultContentTopic)
      msg5 = fakeWakuMessage(ts = now() + 4, contentTopic = DefaultContentTopic)
      msg6 = fakeWakuMessage(ts = now() + 5, contentTopic = DefaultContentTopic)
      hash1 = computeMessageHash("/waku/2/rs/2/1", msg1)
      hash2 = computeMessageHash("/waku/2/rs/2/2", msg2)
      hash3 = computeMessageHash("/waku/2/rs/2/3", msg3)
      hash4 = computeMessageHash("/waku/2/rs/2/4", msg4)
      hash5 = computeMessageHash("/waku/2/rs/2/5", msg5)
      hash6 = computeMessageHash("/waku/2/rs/2/6", msg6)

    server.messageIngress(hash1, "/waku/2/rs/2/1", msg1)
    server.messageIngress(hash2, "/waku/2/rs/2/2", msg2)
    server.messageIngress(hash3, "/waku/2/rs/2/3", msg3)

    client.messageIngress(hash4, "/waku/2/rs/2/4", msg4)
    client.messageIngress(hash5, "/waku/2/rs/2/5", msg5)
    client.messageIngress(hash6, "/waku/2/rs/2/6", msg6)

    check:
      remoteNeeds.len == 0

    var syncRes = await client.storeSynchronization(some(serverPeerInfo))
    assert syncRes.isOk(), $syncRes.error

    check:
      remoteNeeds.len == 2
      remoteNeeds.contains((clientPeerInfo.peerId, hash3)) == true
      remoteNeeds.contains((serverPeerInfo.peerId, hash4)) == true

  asyncTest "sync 2 nodes same hashes":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    let
      msg1 = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      msg2 = fakeWakuMessage(ts = now() + 1, contentTopic = DefaultContentTopic)
      hash1 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg1)
      hash2 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg2)

    server.messageIngress(hash1, DefaultPubsubTopic, msg1)
    client.messageIngress(hash1, DefaultPubsubTopic, msg1)
    server.messageIngress(hash2, DefaultPubsubTopic, msg2)
    client.messageIngress(hash2, DefaultPubsubTopic, msg2)

    check:
      remoteNeeds.len == 0

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check:
      remoteNeeds.len == 0

  asyncTest "sync 2 nodes 100K msgs 1 diff":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    let msgCount = 100_000
    var diffIndex = rand(msgCount)
    var diff: WakuMessageHash

    # the sync window is 1 hour, spread msg equally in that time
    let timeSlice = calculateTimeRange()
    let timeWindow = int64(timeSlice.b) - int64(timeSlice.a)
    let (part, _) = divmod(timeWindow, 100_000)

    var timestamp = timeSlice.a

    for i in 0 ..< msgCount:
      let msg = fakeWakuMessage(ts = timestamp, contentTopic = DefaultContentTopic)
      let hash = computeMessageHash(DefaultPubsubTopic, msg)

      server.messageIngress(hash, DefaultPubsubTopic, msg)

      if i != diffIndex:
        client.messageIngress(hash, DefaultPubsubTopic, msg)
      else:
        diff = hash

      timestamp += Timestamp(part)

    check:
      remoteNeeds.len == 0
      remoteNeeds.contains((clientPeerInfo.peerId, WakuMessageHash(diff))) == false

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check:
      remoteNeeds.len == 1
      remoteNeeds.contains((clientPeerInfo.peerId, WakuMessageHash(diff))) == true

  asyncTest "sync 2 nodes 10K msgs 1K diffs":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    const
      msgCount = 10_000 # total messages on the server
      diffCount = 1000 # messages initially missing on the client

    ## ── choose which messages will be absent from the client ─────────────
    var missingIdx: HashSet[int]
    while missingIdx.len < diffCount:
      missingIdx.incl rand(0 ..< msgCount)

    ## ── generate messages and pre-load the two reconcilers ───────────────
    let slice = calculateTimeRange() # 1-hour window
    let step = (int64(slice.b) - int64(slice.a)) div msgCount
    var ts = slice.a

    for i in 0 ..< msgCount:
      let
        msg = fakeWakuMessage(ts = ts, contentTopic = DefaultContentTopic)
        h = computeMessageHash(DefaultPubsubTopic, msg)

      server.messageIngress(h, DefaultPubsubTopic, msg) # every msg is on the server
      if i notin missingIdx:
        client.messageIngress(h, DefaultPubsubTopic, msg) # all but 100 are on the client
      ts += Timestamp(step)

    ## ── sanity before we start the round ─────────────────────────────────
    check remoteNeeds.len == 0

    ## ── launch reconciliation from the client towards the server ─────────
    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    ## ── verify that ≈1000 diffs were queued (allow 10 % slack) ────────────
    check remoteNeeds.len >= 900 # ≈ 1000 × 0.9

  asyncTest "sync 2 nodes 400K msgs 100k diffs":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    const
      msgCount = 400_000
      diffCount = 100_000
      tol = 1000

    var diffMsgHashes: HashSet[WakuMessageHash]
    var missingIdx: HashSet[int]
    while missingIdx.len < diffCount:
      missingIdx.incl rand(0 ..< msgCount)

    let slice = calculateTimeRange()
    let step = (int64(slice.b) - int64(slice.a)) div msgCount
    var ts = slice.a

    for i in 0 ..< msgCount:
      let
        msg = fakeWakuMessage(ts = ts, contentTopic = DefaultContentTopic)
        h = computeMessageHash(DefaultPubsubTopic, msg)

      server.messageIngress(h, DefaultPubsubTopic, msg)
      if i notin missingIdx:
        client.messageIngress(h, DefaultPubsubTopic, msg)
      else:
        diffMsgHashes.incl h

      ts += Timestamp(step)

    check remoteNeeds.len == 0

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len >= diffCount - tol and remoteNeeds.len < diffCount
    let (_, deliveredHash) = await remoteNeeds.get()
    check deliveredHash in diffMsgHashes

  asyncTest "sync 2 nodes 100 msgs 20 diff – 1-second window":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    const
      msgCount = 100
      diffCount = 20

    var missingIdx: seq[int] = @[]
    while missingIdx.len < diffCount:
      let n = rand(0 ..< msgCount)
      if n notin missingIdx:
        missingIdx.add n

    var diffMsgHashes: HashSet[WakuMessageHash]

    let sliceEnd = now()
    let sliceStart = Timestamp uint64(sliceEnd) - 1_000_000_000'u64
    let step = (int64(sliceEnd) - int64(sliceStart)) div msgCount
    var ts = sliceStart

    for i in 0 ..< msgCount:
      let msg = fakeWakuMessage(ts = ts, contentTopic = DefaultContentTopic)
      let hash = computeMessageHash(DefaultPubsubTopic, msg)
      server.messageIngress(hash, DefaultPubsubTopic, msg)

      if i in missingIdx:
        diffMsgHashes.incl hash
      else:
        client.messageIngress(hash, DefaultPubsubTopic, msg)

      ts += Timestamp(step)

    check remoteNeeds.len == 0

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len == diffCount

    for _ in 0 ..< diffCount:
      let (_, deliveredHash) = await remoteNeeds.get()
      check deliveredHash in diffMsgHashes

  asyncTest "sync 2 nodes 500k msgs 300k diff – stress window":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    const
      msgCount = 500_000
      diffCount = 300_000

    randomize()
    var allIdx = newSeq[int](msgCount)
    for i in 0 ..< msgCount:
      allIdx[i] = i
    shuffle(allIdx)

    let missingIdx = allIdx[0 ..< diffCount]
    var missingSet: HashSet[int]
    for idx in missingIdx:
      missingSet.incl idx

    var diffMsgHashes: HashSet[WakuMessageHash]

    let sliceEnd = now()
    let sliceStart = Timestamp uint64(sliceEnd) - 1_000_000_000'u64
    let step = (int64(sliceEnd) - int64(sliceStart)) div msgCount
    var ts = sliceStart

    for i in 0 ..< msgCount:
      let msg = fakeWakuMessage(ts = ts, contentTopic = DefaultContentTopic)
      let hash = computeMessageHash(DefaultPubsubTopic, msg)
      server.messageIngress(hash, DefaultPubsubTopic, msg)

      if i in missingSet:
        diffMsgHashes.incl hash
      else:
        client.messageIngress(hash, DefaultPubsubTopic, msg)

      ts += Timestamp(step)

    check remoteNeeds.len == 0

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len == diffCount

    for _ in 0 ..< 1000:
      let (_, deliveredHash) = await remoteNeeds.get()
      check deliveredHash in diffMsgHashes

  #[ asyncTest "sync 2 nodes, 40 msgs: 17 in-window diff, 20 out-window ignored":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    const
      diffInWin = 17
      diffOutWin = 20
      stepOutNs = 100_000_000'u64
      outOffsetNs = 3_000_000_000'u64 # for 20 mesg they sent 2 seconds earlier 

    randomize()

    let nowNs = getNowInNanosecondTime()
    let sliceStart = Timestamp(uint64(nowNs) - 700_000_000'u64)
    let sliceEnd = nowNs
    let stepIn = (sliceEnd.int64 - sliceStart.int64) div diffInWin

    let oldStart = Timestamp(uint64(sliceStart) - outOffsetNs)
    let stepOut = Timestamp(stepOutNs)

    var inWinHashes, outWinHashes: HashSet[WakuMessageHash]

    var ts = sliceStart + (Timestamp(stepIn) * 2)
    for _ in 0 ..< diffInWin:
      let msg = fakeWakuMessage(ts = Timestamp ts, contentTopic = DefaultContentTopic)
      let hash = computeMessageHash(DefaultPubsubTopic, msg)
      server.messageIngress(hash, DefaultPubsubTopic, msg)
      inWinHashes.incl hash
      ts += Timestamp(stepIn)

    ts = oldStart
    for _ in 0 ..< diffOutWin:
      let msg = fakeWakuMessage(ts = Timestamp ts, contentTopic = DefaultContentTopic)
      let hash = computeMessageHash(DefaultPubsubTopic, msg)
      server.messageIngress(hash, DefaultPubsubTopic, msg)
      outWinHashes.incl hash
      ts += Timestamp(stepOut)

    check remoteNeeds.len == 0

    let oneSec = timer.seconds(1)

    server = await newTestWakuRecon(
      serverSwitch, @[], @[], oneSec, idsChannel, localWants, remoteNeeds
    )

    client = await newTestWakuRecon(
      clientSwitch, @[], @[], oneSec, idsChannel, localWants, remoteNeeds
    )

    defer:
      await server.stop()
      await client.stop()

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len == diffInWin

    for _ in 0 ..< diffInWin:
      let (_, deliveredHashes) = await remoteNeeds.popFirst()
      check deliveredHashes in inWinHashes
      check deliveredHashes notin outWinHashes ]#

  asyncTest "hash-fingerprint collision, same timestamp – stable sort":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    let ts = Timestamp(getNowInNanosecondTime())

    var msg1 = fakeWakuMessage(ts = ts, contentTopic = DefaultContentTopic)
    var msg2 = fakeWakuMessage(ts = ts, contentTopic = DefaultContentTopic)
    msg2.payload[0] = msg2.payload[0] xor 0x01
    var h1 = computeMessageHash(DefaultPubsubTopic, msg1)
    var h2 = computeMessageHash(DefaultPubsubTopic, msg2)

    for i in 0 ..< 8:
      h2[i] = h1[i]
    for i in 0 ..< 8:
      check h1[i] == h2[i]

    check h1 != h2

    server.messageIngress(h1, DefaultPubsubTopic, msg1)
    client.messageIngress(h2, DefaultPubsubTopic, msg2)

    check remoteNeeds.len == 0
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    defer:
      await server.stop()
      await client.stop()

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len == 1

    var vec = @[SyncID(time: ts, hash: h2), SyncID(time: ts, hash: h1)]
    vec.shuffle()
    vec.sort()

    let hFirst = vec[0].hash
    let hSecond = vec[1].hash
    check vec[0].time == ts and vec[1].time == ts

  asyncTest "malformed message-ID is ignored during reconciliation":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    let nowTs = Timestamp(getNowInNanosecondTime())

    let goodMsg = fakeWakuMessage(ts = nowTs, contentTopic = DefaultContentTopic)
    var goodHash = computeMessageHash(DefaultPubsubTopic, goodMsg)

    var badHash: WakuMessageHash
    for i in 0 ..< 32:
      badHash[i] = 0'u8
    let badMsg = fakeWakuMessage(ts = Timestamp(0), contentTopic = DefaultContentTopic)

    server.messageIngress(goodHash, DefaultPubsubTopic, goodMsg)
    server.messageIngress(badHash, DefaultPubsubTopic, badMsg)

    check remoteNeeds.len == 0

    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    defer:
      await server.stop()
      await client.stop()

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len == 1
    let (_, neededHash) = await remoteNeeds.get()
    check neededHash == goodHash
    check neededHash != badHash

  asyncTest "malformed ID: future-timestamp msg is ignored":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    let nowNs = getNowInNanosecondTime()
    let tsNow = Timestamp(nowNs)

    let goodMsg = fakeWakuMessage(ts = tsNow, contentTopic = DefaultContentTopic)
    let goodHash = computeMessageHash(DefaultPubsubTopic, goodMsg)

    const tenYearsSec = 10 * 365 * 24 * 60 * 60
    let futureNs = nowNs + int64(tenYearsSec) * 1_000_000_000'i64
    let badTs = Timestamp(futureNs.uint64)

    let badMsg = fakeWakuMessage(ts = badTs, contentTopic = DefaultContentTopic)
    let badHash = computeMessageHash(DefaultPubsubTopic, badMsg)

    server.messageIngress(goodHash, DefaultPubsubTopic, goodMsg)
    server.messageIngress(badHash, DefaultPubsubTopic, badMsg)

    check remoteNeeds.len == 0
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    defer:
      await server.stop()
      await client.stop()

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len == 1
    let (_, neededHash) = await remoteNeeds.get()
    check neededHash == goodHash
    check neededHash != badHash

  asyncTest "duplicate ID is queued only once":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    let ts = Timestamp(getNowInNanosecondTime())
    let msg = fakeWakuMessage(ts = ts, contentTopic = DefaultContentTopic)
    let h = computeMessageHash(DefaultPubsubTopic, msg)

    server.messageIngress(h, DefaultPubsubTopic, msg)
    server.messageIngress(h, DefaultPubsubTopic, msg)
    check remoteNeeds.len == 0

    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    defer:
      await server.stop()
      await client.stop()

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len == 1
    let (_, neededHash) = await remoteNeeds.get()
    check neededHash == h

  asyncTest "sync terminates immediately when no diffs exist":
    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    let ts = Timestamp(getNowInNanosecondTime())
    let msg = fakeWakuMessage(ts = ts, contentTopic = DefaultContentTopic)
    let hash = computeMessageHash(DefaultPubsubTopic, msg)

    server.messageIngress(hash, DefaultPubsubTopic, msg)
    client.messageIngress(hash, DefaultPubsubTopic, msg)

    let idsQ = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)]()
    let wantsQ = newAsyncQueue[PeerId]()
    let needsQ = newAsyncQueue[(PeerId, Fingerprint)]()

    server = await newTestWakuRecon(
      serverSwitch, @[], @[], DefaultSyncRange, idsQ, wantsQ, needsQ
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], @[], DefaultSyncRange, idsQ, wantsQ, needsQ
    )

    defer:
      await server.stop()
      await client.stop()

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check needsQ.len == 0

suite "Waku Sync: transfer":
  var
    serverSwitch {.threadvar.}: Switch
    clientSwitch {.threadvar.}: Switch

  var
    serverDriver {.threadvar.}: ArchiveDriver
    clientDriver {.threadvar.}: ArchiveDriver
    serverArchive {.threadvar.}: WakuArchive
    clientArchive {.threadvar.}: WakuArchive

  var
    serverIds {.threadvar.}: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)]
    serverLocalWants {.threadvar.}: AsyncQueue[PeerId]
    serverRemoteNeeds {.threadvar.}: AsyncQueue[(PeerId, WakuMessageHash)]
    clientIds {.threadvar.}: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)]
    clientLocalWants {.threadvar.}: AsyncQueue[PeerId]
    clientRemoteNeeds {.threadvar.}: AsyncQueue[(PeerId, WakuMessageHash)]

  var
    server {.threadvar.}: SyncTransfer
    client {.threadvar.}: SyncTransfer

  var
    serverPeerInfo {.threadvar.}: RemotePeerInfo
    clientPeerInfo {.threadvar.}: RemotePeerInfo

  asyncSetup:
    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    serverDriver = newSqliteArchiveDriver()
    clientDriver = newSqliteArchiveDriver()

    serverArchive = newWakuArchive(serverDriver)
    clientArchive = newWakuArchive(clientDriver)

    let
      serverPeerManager = PeerManager.new(serverSwitch)
      clientPeerManager = PeerManager.new(clientSwitch)

    serverIds = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)]()
    serverLocalWants = newAsyncQueue[PeerId]()
    serverRemoteNeeds = newAsyncQueue[(PeerId, WakuMessageHash)]()

    server = SyncTransfer.new(
      peerManager = serverPeerManager,
      wakuArchive = serverArchive,
      idsTx = serverIds,
      localWantsRx = serverLocalWants,
      remoteNeedsRx = serverRemoteNeeds,
    )

    clientIds = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)]()
    clientLocalWants = newAsyncQueue[PeerId]()
    clientRemoteNeeds = newAsyncQueue[(PeerId, WakuMessageHash)]()

    client = SyncTransfer.new(
      peerManager = clientPeerManager,
      wakuArchive = clientArchive,
      idsTx = clientIds,
      localWantsRx = clientLocalWants,
      remoteNeedsRx = clientRemoteNeeds,
    )

    await server.start()
    await client.start()

    serverSwitch.mount(server)
    clientSwitch.mount(client)

    serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    clientPeerInfo = clientSwitch.peerInfo.toRemotePeerInfo()

    serverPeerManager.addPeer(clientPeerInfo)
    clientPeermanager.addPeer(serverPeerInfo)

  asyncTeardown:
    await server.stop()
    await client.stop()

    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "transfer 1 message":
    let msg = fakeWakuMessage()
    let hash = computeMessageHash(DefaultPubsubTopic, msg)
    let msgs = @[msg]

    serverDriver = serverDriver.put(DefaultPubsubTopic, msgs)

    # add server info to client want channel
    let want = serverPeerInfo.peerId
    await clientLocalWants.put(want)

    # add client info and msg hash to server need channel
    let need = (clientPeerInfo.peerId, hash)
    await serverRemoteNeeds.put(need)

    # give time for transfer to happen
    await sleepAsync(500.milliseconds)

    var query = ArchiveQuery()
    query.includeData = true
    query.hashes = @[hash]

    let res = await clientArchive.findMessages(query)
    assert res.isOk(), $res.error

    let response = res.get()

    check:
      response.messages.len > 0

  ## Disabled until we impl. DOS protection again
  #[ asyncTest "Check the exact missing messages are received":
    let timeSlice = calculateTimeRange()
    let timeWindow = int64(timeSlice.b) - int64(timeSlice.a)
    let (part, _) = divmod(timeWindow, 3)

    var ts = timeSlice.a

    let msgA = fakeWakuMessage(ts = ts, contentTopic = DefaultContentTopic)
    ts += Timestamp(part)
    let msgB = fakeWakuMessage(ts = ts, contentTopic = DefaultContentTopic)
    ts += Timestamp(part)
    let msgC = fakeWakuMessage(ts = ts, contentTopic = DefaultContentTopic)

    let hA = computeMessageHash(DefaultPubsubTopic, msgA)
    let hB = computeMessageHash(DefaultPubsubTopic, msgB)
    let hC = computeMessageHash(DefaultPubsubTopic, msgC)

    discard serverDriver.put(DefaultPubsubTopic, @[msgA, msgB, msgC])
    discard clientDriver.put(DefaultPubsubTopic, @[msgA])

    await serverRemoteNeeds.put((clientPeerInfo.peerId, hB))
    await serverRemoteNeeds.put((clientPeerInfo.peerId, hC))
    await clientLocalWants.put(serverPeerInfo.peerId)

    await sleepAsync(1.seconds)
    check serverRemoteNeeds.len == 0

    let sid1 = await clientIds.get()
    let sid2 = await clientIds.get()

    let received = [sid1.hash, sid2.hash].toHashSet()
    let expected = [hB, hC].toHashSet

    check received == expected

    check clientIds.len == 0 ]#

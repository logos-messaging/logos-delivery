{.used.}

import
  results,
  std/[sets, random, math, algorithm],
  stew/byteutils,
  testutils/unittests,
  chronos,
  metrics,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/stream/bufferstream,
  libp2p/stream/connection,
  libp2p/varint
from libp2p/muxers/yamux/yamux import YamuxDefaultWindowSize
import chronos, chronos/asyncsync
import nimcrypto
import
  ../../logos_delivery/waku/[
    node/peer_manager,
    waku_core,
    waku_core/message,
    waku_core/message/digest,
    waku_store_sync/common,
    waku_store_sync/codec,
    waku_store_sync/storage/range_processing,
    waku_store_sync/reconciliation,
    waku_store_sync/transfer,
    waku_store_sync/protocols_metrics,
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

proc failureCount(reason: string): float64 =
  ## Counters are registered with the '_total' suffix; see archive_utils.insertCount.
  try:
    return logos_delivery_transfer_receive_failures.valueByName(
      "logos_delivery_transfer_receive_failures_total", [reason]
    )
  except ValueError:
    return 0.0

proc newLimitedReceiver(
    maxMessageSize: int
): Future[(Switch, SyncTransfer, WakuArchive)] {.async.} =
  ## A started transfer receiver with its own switch, archive and read limit.
  let
    switch = newTestSwitch()
    archive = newWakuArchive(newSqliteArchiveDriver())
    transfer = SyncTransfer.new(
      peerManager = PeerManager.new(switch),
      wakuArchive = archive,
      idsTx = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)](),
      localWantsRx = newAsyncQueue[PeerId](),
      remoteNeedsRx = newAsyncQueue[(PeerId, WakuMessageHash)](),
      maxMessageSize = maxMessageSize,
    )
  await switch.start()
  await transfer.start()
  switch.mount(transfer)
  return (switch, transfer, archive)

proc newSecondServer(
    idsRx: AsyncQueue[(SyncID, PubsubTopic, ContentTopic)],
    wantsTx: AsyncQueue[PeerId],
    needsTx: AsyncQueue[(PeerId, WakuMessageHash)],
    pendingTimeout: Duration = DefaultSyncInterval,
): Future[(Switch, SyncReconciliation, RemotePeerInfo)] {.async.} =
  ## A started reconciliation server with its own switch.
  let switch = newTestSwitch()
  await switch.start()
  let server = await newTestWakuRecon(
    switch,
    @[],
    DefaultSyncRange,
    idsRx,
    wantsTx,
    needsTx,
    pendingTimeout = pendingTimeout,
  )
  return (switch, server, switch.peerInfo.toRemotePeerInfo())

proc encodedLen(msg: WakuMessage): int =
  WakuMessageAndTopic(pubsub: DefaultPubsubTopic, message: msg).encode().len

proc lengthDelimited(fieldNumber: int, value: seq[byte]): seq[byte] =
  ## One length-delimited protobuf field, built without the codec. The value must
  ## be shorter than 128 bytes, so that its length is a single varint byte.
  doAssert value.len < 128
  @[byte(fieldNumber shl 3 or 2), byte(value.len)] & value

type HeldPutDriver = ref object of ArchiveDriver
  putStarted: Future[void]
  release: Future[void]

method put(
    driver: HeldPutDriver,
    messageHash: WakuMessageHash,
    pubsubTopic: PubsubTopic,
    message: WakuMessage,
): Future[ArchiveDriverResult[bool]] {.async.} =
  driver.putStarted.complete()
  await driver.release
  return ok(true)

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
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    check:
      idsChannel.len == 0
      remoteNeeds.len == 0

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), res.error

    check:
      idsChannel.len == 0
      remoteNeeds.len == 0

  asyncTest "sync 2 nodes empty client full server":
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
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

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), res.error

    check:
      remoteNeeds.len == 3
      remoteNeeds.contains((clientPeerInfo.peerId, hash1)) == true
      remoteNeeds.contains((clientPeerInfo.peerId, hash2)) == true
      remoteNeeds.contains((clientPeerInfo.peerId, hash3)) == true

  asyncTest "sync 2 nodes full client empty server":
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
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

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), res.error

    check:
      remoteNeeds.len == 3
      remoteNeeds.contains((serverPeerInfo.peerId, hash1)) == true
      remoteNeeds.contains((serverPeerInfo.peerId, hash2)) == true
      remoteNeeds.contains((serverPeerInfo.peerId, hash3)) == true

  asyncTest "a second round does not queue a message the first round already promised":
    # Given two servers holding one message and an empty client
    let
      msg = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      hash = computeMessageHash(DefaultPubsubTopic, msg)
      (switchB, serverB, serverBPeerInfo) =
        await newSecondServer(idsChannel, localWants, remoteNeeds)
    defer:
      await serverB.stop()
      await switchB.stop()
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    server.messageIngress(hash, DefaultPubsubTopic, msg)
    serverB.messageIngress(hash, DefaultPubsubTopic, msg)

    # When the client syncs with both before the message arrives
    var res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), res.error
    check remoteNeeds.len == 1
    res = await client.storeSynchronization(Opt.some(serverBPeerInfo))
    assert res.isOk(), res.error

    # Then only the first server queued it
    check:
      remoteNeeds.len == 1
      remoteNeeds.contains((clientPeerInfo.peerId, hash))

  asyncTest "a promised message is asked for again once the pending timeout passes":
    # Given two servers holding one message and an empty client with a short timeout
    let
      msg = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      hash = computeMessageHash(DefaultPubsubTopic, msg)
      (switchB, serverB, serverBPeerInfo) =
        await newSecondServer(idsChannel, localWants, remoteNeeds)
    defer:
      await serverB.stop()
      await switchB.stop()
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch,
      @[],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      pendingTimeout = 500.milliseconds,
    )
    server.messageIngress(hash, DefaultPubsubTopic, msg)
    serverB.messageIngress(hash, DefaultPubsubTopic, msg)

    # When the message has not arrived by the timeout
    var res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), res.error
    check remoteNeeds.len == 1
    await sleepAsync(600.milliseconds)
    res = await client.storeSynchronization(Opt.some(serverBPeerInfo))
    assert res.isOk(), res.error

    # Then the second server queues it too
    check remoteNeeds.len == 2

  asyncTest "a promised message that arrives is kept after the pending timeout":
    # Given two servers holding one message and an empty client with a short timeout
    let
      msg = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      hash = computeMessageHash(DefaultPubsubTopic, msg)
      clientIds = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)]()
      (switchB, serverB, serverBPeerInfo) =
        await newSecondServer(idsChannel, localWants, remoteNeeds)
    defer:
      await serverB.stop()
      await switchB.stop()
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch,
      @[],
      DefaultSyncRange,
      clientIds,
      localWants,
      remoteNeeds,
      pendingTimeout = 500.milliseconds,
    )
    server.messageIngress(hash, DefaultPubsubTopic, msg)
    serverB.messageIngress(hash, DefaultPubsubTopic, msg)

    # When the message arrives by transfer before the timeout
    var res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), res.error
    check remoteNeeds.len == 1
    await clientIds.put(
      (SyncID(time: msg.timestamp, hash: hash), DefaultPubsubTopic, DefaultContentTopic)
    )
    # The receiver inserts the id as soon as it takes it off the queue.
    while clientIds.len > 0:
      await sleepAsync(10.milliseconds)
    await sleepAsync(600.milliseconds)
    res = await client.storeSynchronization(Opt.some(serverBPeerInfo))
    assert res.isOk(), res.error

    # Then the second server does not queue it
    check remoteNeeds.len == 1

  asyncTest "a peer that asks for a pending message gets it when it arrives":
    # Given a server holding one message, an empty client and an empty third node
    let
      msg = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      hash = computeMessageHash(DefaultPubsubTopic, msg)
      clientIds = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)]()
      (switchC, nodeC, _) = await newSecondServer(idsChannel, localWants, remoteNeeds)
    defer:
      await nodeC.stop()
      await switchC.stop()
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, clientIds, localWants, remoteNeeds
    )
    server.messageIngress(hash, DefaultPubsubTopic, msg)

    # When the third node syncs with the client while the message is pending there
    var res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), res.error
    check remoteNeeds.len == 1
    res = await nodeC.storeSynchronization(Opt.some(clientPeerInfo))
    assert res.isOk(), res.error
    check remoteNeeds.len == 1

    # And the message then arrives at the client
    await clientIds.put(
      (SyncID(time: msg.timestamp, hash: hash), DefaultPubsubTopic, DefaultContentTopic)
    )
    while clientIds.len > 0:
      await sleepAsync(10.milliseconds)

    # Then the client queues it for the third node
    check:
      remoteNeeds.len == 2
      remoteNeeds.contains((switchC.peerInfo.peerId, hash))

  asyncTest "a peer that asks twice for a pending message gets it once":
    # Given a server holding one message, an empty client and an empty third node
    # whose own pending entries expire fast
    let
      msg = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      hash = computeMessageHash(DefaultPubsubTopic, msg)
      clientIds = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)]()
      (switchC, nodeC, _) = await newSecondServer(
        idsChannel, localWants, remoteNeeds, pendingTimeout = 500.milliseconds
      )
    defer:
      await nodeC.stop()
      await switchC.stop()
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, clientIds, localWants, remoteNeeds
    )
    server.messageIngress(hash, DefaultPubsubTopic, msg)

    # When the third node asks the client for it in two rounds
    var res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), res.error
    res = await nodeC.storeSynchronization(Opt.some(clientPeerInfo))
    assert res.isOk(), res.error
    await sleepAsync(600.milliseconds)
    res = await nodeC.storeSynchronization(Opt.some(clientPeerInfo))
    assert res.isOk(), res.error
    check remoteNeeds.len == 1

    # And the message then arrives at the client
    await clientIds.put(
      (SyncID(time: msg.timestamp, hash: hash), DefaultPubsubTopic, DefaultContentTopic)
    )
    while clientIds.len > 0:
      await sleepAsync(10.milliseconds)

    # Then the client queues it for the third node one time
    check remoteNeeds.len == 2

  asyncTest "sync 2 nodes empty client full server, relay jitter shifts the time range":
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch,
      @[],
      20.seconds,
      idsChannel,
      localWants,
      remoteNeeds,
      relayJitter = 25.seconds,
    )

    # The client's time range is [now - 45 s, now - 25 s].
    let
      olderMsg = fakeWakuMessage(
        ts = now() - 60.seconds.nanos, contentTopic = DefaultContentTopic
      )
      inRangeMsg = fakeWakuMessage(
        ts = now() - 35.seconds.nanos, contentTopic = DefaultContentTopic
      )
      youngerMsg = fakeWakuMessage(
        ts = now() - 10.seconds.nanos, contentTopic = DefaultContentTopic
      )
      olderHash = computeMessageHash(pubsubTopic = DefaultPubsubTopic, olderMsg)
      inRangeHash = computeMessageHash(pubsubTopic = DefaultPubsubTopic, inRangeMsg)
      youngerHash = computeMessageHash(pubsubTopic = DefaultPubsubTopic, youngerMsg)

    server.messageIngress(olderHash, DefaultPubsubTopic, olderMsg)
    server.messageIngress(inRangeHash, DefaultPubsubTopic, inRangeMsg)
    server.messageIngress(youngerHash, DefaultPubsubTopic, youngerMsg)

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))

    check:
      res.isOk()
      remoteNeeds.len == 1
      remoteNeeds.contains((clientPeerInfo.peerId, inRangeHash)) == true

  const
    narrowSyncRange = 1780.seconds
    narrowRelayJitter = 20.seconds

  proc newNarrowServerAndClient(
      now: Timestamp
  ): Future[(SyncReconciliation, SyncReconciliation)] {.async.} =
    ## A server whose time range is [now - 1800 s, now - 20 s] and a client with
    ## the default range, [now - 3600 s, now], both on a clock fixed at `now`.
    let clock = proc(): Timestamp {.gcsafe, raises: [].} =
      now
    let server = await newTestWakuRecon(
      serverSwitch,
      @[],
      narrowSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      relayJitter = narrowRelayJitter,
      clock = clock,
    )
    let client = await newTestWakuRecon(
      clientSwitch,
      @[],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      clock = clock,
    )
    return (server, client)

  asyncTest "a peer with a longer range only pushes messages inside the server's window":
    let now = getNowInNanosecondTime()
    (server, client) = await newNarrowServerAndClient(now)

    let
      oldMsg = fakeWakuMessage(
        ts = now - 2000.seconds.nanos, contentTopic = DefaultContentTopic
      )
      recentMsg = fakeWakuMessage(
        ts = now - 100.seconds.nanos, contentTopic = DefaultContentTopic
      )
      oldHash = computeMessageHash(DefaultPubsubTopic, oldMsg)
      recentHash = computeMessageHash(DefaultPubsubTopic, recentMsg)

    client.messageIngress(oldHash, DefaultPubsubTopic, oldMsg)
    client.messageIngress(recentHash, DefaultPubsubTopic, recentMsg)

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))

    check:
      res.isOk()
      remoteNeeds.len == 1
      remoteNeeds.contains((serverPeerInfo.peerId, recentHash)) == true
      remoteNeeds.contains((serverPeerInfo.peerId, oldHash)) == false

  asyncTest "a server does not offer messages older than its window":
    let now = getNowInNanosecondTime()
    (server, client) = await newNarrowServerAndClient(now)

    let
      oldMsg = fakeWakuMessage(
        ts = now - 2000.seconds.nanos, contentTopic = DefaultContentTopic
      )
      recentMsg = fakeWakuMessage(
        ts = now - 100.seconds.nanos, contentTopic = DefaultContentTopic
      )
      oldHash = computeMessageHash(DefaultPubsubTopic, oldMsg)
      recentHash = computeMessageHash(DefaultPubsubTopic, recentMsg)

    server.messageIngress(oldHash, DefaultPubsubTopic, oldMsg)
    server.messageIngress(recentHash, DefaultPubsubTopic, recentMsg)
    client.messageIngress(recentHash, DefaultPubsubTopic, recentMsg)

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))

    check:
      res.isOk()
      remoteNeeds.len == 0

  asyncTest "partitioned ranges stay inside the server's window":
    let now = getNowInNanosecondTime()
    (server, client) = await newNarrowServerAndClient(now)

    const
      msgCount = 1000
      diffIndexes = [501, 750, 998]

    # The client holds 1000 messages spread over its window. The server holds
    # the ones inside its own window except three, so that it answers with
    # partitions of the part of the client's range it processes.
    let windowStart = calculateTimeRange(now, narrowRelayJitter, narrowSyncRange).a
    let timeSlice = calculateTimeRange(now, 0.seconds, DefaultSyncRange)
    let step = (timeSlice.b - timeSlice.a) div msgCount

    var diffs: HashSet[WakuMessageHash]
    var timestamp = timeSlice.a
    for i in 0 ..< msgCount:
      let msg = fakeWakuMessage(ts = timestamp, contentTopic = DefaultContentTopic)
      let hash = computeMessageHash(DefaultPubsubTopic, msg)

      client.messageIngress(hash, DefaultPubsubTopic, msg)

      if i in diffIndexes:
        diffs.incl(hash)
      elif timestamp >= windowStart:
        server.messageIngress(hash, DefaultPubsubTopic, msg)

      timestamp += step

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len == diffs.len
    for hash in diffs:
      check remoteNeeds.contains((serverPeerInfo.peerId, hash))

  asyncTest "preProcessPayload splits a crossing item set range and drops its older elements":
    let now = getNowInNanosecondTime()
    (server, client) = await newNarrowServerAndClient(now)

    let lowerBound = calculateTimeRange(now, narrowRelayJitter, narrowSyncRange).a
    var h1, h2, h3: WakuMessageHash
    h1[0] = 1
    h2[0] = 2
    h3[0] = 3

    # Two ranges end before the bound, one Fingerprint and one ItemSet, so the
    # crossing range's item set is only at index 0 once theirs are removed.
    let
      split = SyncID(time: lowerBound, hash: EmptyFingerprint)
      farStart = SyncID(time: lowerBound - 3000.seconds.nanos, hash: EmptyFingerprint)
      farEnd = SyncID(time: lowerBound - 2000.seconds.nanos, hash: EmptyFingerprint)
      nearEnd = SyncID(time: lowerBound - 1000.seconds.nanos, hash: EmptyFingerprint)
      rangeEnd = SyncID(time: lowerBound + 1000.seconds.nanos, hash: EmptyFingerprint)
      elements = @[
        SyncID(time: lowerBound - 1, hash: h1),
        SyncID(time: lowerBound, hash: h2),
        SyncID(time: lowerBound + 1, hash: h3),
      ]
      payload = RangesData(
        ranges: @[
          (farStart .. farEnd, RangeType.Fingerprint),
          (farEnd .. nearEnd, RangeType.ItemSet),
          (nearEnd .. rangeEnd, RangeType.ItemSet),
        ],
        fingerprints: @[FullFingerprint],
        itemSets: @[
          ItemSet(elements: @[SyncID(time: farEnd.time, hash: h1)], reconciled: true),
          ItemSet(elements: elements, reconciled: false),
        ],
      )

    let processed = server.preProcessPayload(payload, lowerBound).get()

    check:
      processed.ranges ==
        @[
          (farStart .. farEnd, RangeType.Skip),
          (farEnd .. nearEnd, RangeType.Skip),
          (nearEnd .. split, RangeType.Skip),
          (split .. rangeEnd, RangeType.ItemSet),
        ]
      processed.fingerprints.len == 0
      processed.itemSets == @[ItemSet(elements: elements[1 .. 2], reconciled: false)]

  asyncTest "preProcessPayload skips a range that ends exactly at the lower bound":
    let now = getNowInNanosecondTime()
    (server, client) = await newNarrowServerAndClient(now)

    let lowerBound = calculateTimeRange(now, narrowRelayJitter, narrowSyncRange).a
    var h1: WakuMessageHash
    h1[0] = 1

    let
      split = SyncID(time: lowerBound, hash: EmptyFingerprint)
      farStart = SyncID(time: lowerBound - 1000.seconds.nanos, hash: EmptyFingerprint)
      rangeEnd = SyncID(time: lowerBound + 1000.seconds.nanos, hash: EmptyFingerprint)
      payload = RangesData(
        ranges: @[
          (farStart .. split, RangeType.ItemSet),
          (split .. rangeEnd, RangeType.Fingerprint),
        ],
        fingerprints: @[FullFingerprint],
        itemSets: @[
          ItemSet(
            elements: @[SyncID(time: lowerBound - 1, hash: h1)], reconciled: false
          )
        ],
      )

    let processed = server.preProcessPayload(payload, lowerBound).get()

    check:
      processed.ranges ==
        @[
          (farStart .. split, RangeType.Skip),
          (split .. rangeEnd, RangeType.Fingerprint),
        ]
      processed.fingerprints == @[FullFingerprint]
      processed.itemSets.len == 0

  asyncTest "a node offers the messages of every content topic":
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    let
      defaultMsg = fakeWakuMessage(contentTopic = DefaultContentTopic)
      otherMsg = fakeWakuMessage(contentTopic = "/other/1/topic/proto")
      defaultHash = computeMessageHash(DefaultPubsubTopic, defaultMsg)
      otherHash = computeMessageHash(DefaultPubsubTopic, otherMsg)

    client.messageIngress(defaultHash, DefaultPubsubTopic, defaultMsg)
    client.messageIngress(otherHash, DefaultPubsubTopic, otherMsg)

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))

    check:
      res.isOk()
      remoteNeeds.contains((serverPeerInfo.peerId, defaultHash)) == true
      remoteNeeds.contains((serverPeerInfo.peerId, otherHash)) == true

  asyncTest "sync 2 nodes different hashes":
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
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

    var syncRes = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert syncRes.isOk(), $syncRes.error

    check:
      remoteNeeds.len == 2
      remoteNeeds.contains((serverPeerInfo.peerId, hash3)) == true
      remoteNeeds.contains((clientPeerInfo.peerId, hash2)) == true

  asyncTest "sync 2 nodes different shards":
    server = await newTestWakuRecon(
      serverSwitch,
      @[1'u16, 2, 3, 4],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      cluster = 2,
    )

    client = await newTestWakuRecon(
      clientSwitch,
      @[3'u16, 4, 5, 6],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      cluster = 2,
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

    var syncRes = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert syncRes.isOk(), $syncRes.error

    check:
      remoteNeeds.len == 2
      remoteNeeds.contains((clientPeerInfo.peerId, hash3)) == true
      remoteNeeds.contains((serverPeerInfo.peerId, hash4)) == true

  asyncTest "two nodes with no message on their shared shards exchange nothing":
    server = await newTestWakuRecon(
      serverSwitch,
      @[1'u16, 2, 3, 4],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      cluster = 2,
    )
    client = await newTestWakuRecon(
      clientSwitch,
      @[3'u16, 4, 5, 6],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      cluster = 2,
    )

    # Each holds one message on a shard the other does not share.
    let
      serverMsg = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      clientMsg = fakeWakuMessage(ts = now() + 1, contentTopic = DefaultContentTopic)
      serverHash = computeMessageHash("/waku/2/rs/2/1", serverMsg)
      clientHash = computeMessageHash("/waku/2/rs/2/5", clientMsg)

    server.messageIngress(serverHash, "/waku/2/rs/2/1", serverMsg)
    client.messageIngress(clientHash, "/waku/2/rs/2/5", clientMsg)

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))

    check:
      res.isOk()
      remoteNeeds.len == 0

  asyncTest "sync 2 nodes on different clusters fails and exchanges nothing":
    server = await newTestWakuRecon(
      serverSwitch,
      @[],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      cluster = 1,
    )
    client = await newTestWakuRecon(
      clientSwitch,
      @[],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      cluster = 2,
    )

    let
      serverMsg = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      clientMsg = fakeWakuMessage(ts = now() + 1, contentTopic = DefaultContentTopic)
      serverHash = computeMessageHash(DefaultPubsubTopic, serverMsg)
      clientHash = computeMessageHash(DefaultPubsubTopic, clientMsg)

    server.messageIngress(serverHash, DefaultPubsubTopic, serverMsg)
    client.messageIngress(clientHash, DefaultPubsubTopic, clientMsg)

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))

    check:
      res.isErr()
      remoteNeeds.len == 0

  asyncTest "sync 2 nodes with no shared shard fails and exchanges nothing":
    server = await newTestWakuRecon(
      serverSwitch,
      @[1'u16],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      cluster = 2,
    )
    client = await newTestWakuRecon(
      clientSwitch,
      @[2'u16],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      cluster = 2,
    )

    let
      serverMsg = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      clientMsg = fakeWakuMessage(ts = now() + 1, contentTopic = DefaultContentTopic)
      serverHash = computeMessageHash("/waku/2/rs/2/1", serverMsg)
      clientHash = computeMessageHash("/waku/2/rs/2/2", clientMsg)

    server.messageIngress(serverHash, "/waku/2/rs/2/1", serverMsg)
    client.messageIngress(clientHash, "/waku/2/rs/2/2", clientMsg)

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))

    check:
      res.isErr()
      remoteNeeds.len == 0

  asyncTest "a reply advertises the shards both peers share":
    server = await newTestWakuRecon(
      serverSwitch,
      @[1'u16, 2, 3],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      cluster = 2,
    )
    client = await newTestWakuRecon(
      clientSwitch,
      @[],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      cluster = 2,
    )

    let
      bounds =
        SyncID(time: Timestamp(100), hash: EmptyFingerprint) ..
        SyncID(time: Timestamp(200), hash: EmptyFingerprint)
      payload = RangesData(
        cluster: 2,
        shards: @[2'u16, 3, 4],
        ranges: @[(bounds, RangeType.Fingerprint)],
        fingerprints: @[FullFingerprint],
      )

    # When a peer on shards 2, 3 and 4 sends a payload to the server on 1, 2 and 3
    let conn = await clientSwitch.dial(
      serverPeerInfo.peerId, serverPeerInfo.addrs, WakuReconciliationCodec
    )
    await conn.writeLp(payload.deltaEncode())

    # Then the reply advertises the shards its ranges cover, 2 and 3
    let reply = RangesData.deltaDecode(await conn.readLp(64 * 1024))
    check:
      reply.isOk()
      reply.get().cluster == 2
      reply.get().shards.sorted() == @[2'u16, 3]
    await conn.close()

  asyncTest "a peer on another cluster gets a reply with only the cluster and the shards":
    server = await newTestWakuRecon(
      serverSwitch,
      @[3'u16],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      cluster = 2,
    )
    client = await newTestWakuRecon(
      clientSwitch,
      @[],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      cluster = 1,
    )

    let
      bounds =
        SyncID(time: Timestamp(100), hash: EmptyFingerprint) ..
        SyncID(time: Timestamp(200), hash: EmptyFingerprint)
      payload = RangesData(
        cluster: 1,
        shards: @[3'u16],
        ranges: @[(bounds, RangeType.Fingerprint)],
        fingerprints: @[FullFingerprint],
      )

    # When a peer on cluster 1 sends a payload to the server on cluster 2
    let conn = await clientSwitch.dial(
      serverPeerInfo.peerId, serverPeerInfo.addrs, WakuReconciliationCodec
    )
    await conn.writeLp(payload.deltaEncode())

    # Then the server answers with its cluster (2) and its one shard (3) only
    let reply = await conn.readLp(64 * 1024)
    check reply == @[byte 2, 1, 3]
    await conn.close()

  asyncTest "sync 2 nodes same hashes":
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
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

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), $res.error

    check:
      remoteNeeds.len == 0

  asyncTest "sync 2 nodes 100K msgs, diffs at first, last and a random message":
    let now = getNowInNanosecondTime()
    let clock = proc(): Timestamp {.gcsafe, raises: [].} =
      now

    server = await newTestWakuRecon(
      serverSwitch,
      @[],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      clock = clock,
    )
    client = await newTestWakuRecon(
      clientSwitch,
      @[],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      clock = clock,
    )

    const msgCount = 100_000
    let diffIndexes = [0, rand(1 .. msgCount - 2), msgCount - 1]
    var diffs: HashSet[WakuMessageHash]

    # spread msgs equally over the nodes' 1 hour sync window
    let timeSlice = calculateTimeRange(now, 0.seconds, DefaultSyncRange)
    let part = (timeSlice.b - timeSlice.a) div msgCount

    var timestamp = timeSlice.a

    for i in 0 ..< msgCount:
      let msg = fakeWakuMessage(ts = timestamp, contentTopic = DefaultContentTopic)
      let hash = computeMessageHash(DefaultPubsubTopic, msg)

      server.messageIngress(hash, DefaultPubsubTopic, msg)

      if i in diffIndexes:
        diffs.incl(hash)
      else:
        client.messageIngress(hash, DefaultPubsubTopic, msg)

      timestamp += part

    check:
      remoteNeeds.len == 0

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), $res.error

    check:
      remoteNeeds.len == diffs.len
    for hash in diffs:
      check remoteNeeds.contains((clientPeerInfo.peerId, hash))

  asyncTest "sync 2 nodes 10K msgs 1K diffs":
    let now = getNowInNanosecondTime()
    let clock = proc(): Timestamp {.gcsafe, raises: [].} =
      now

    server = await newTestWakuRecon(
      serverSwitch,
      @[],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      clock = clock,
    )
    client = await newTestWakuRecon(
      clientSwitch,
      @[],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      clock = clock,
    )

    const
      msgCount = 10_000 # total messages on the server
      diffCount = 1000 # messages initially missing on the client

    ## ── choose which messages will be absent from the client ─────────────
    var missingIdx: HashSet[int]
    while missingIdx.len < diffCount:
      missingIdx.incl rand(0 ..< msgCount)

    ## ── generate messages and pre-load the two reconcilers ───────────────
    # nodes' 1-hour window
    let slice = calculateTimeRange(now, 0.seconds, DefaultSyncRange)
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
    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), $res.error

    ## ── verify that every missing message was queued ─────────────────────
    check remoteNeeds.len == diffCount

  asyncTest "sync 2 nodes 400K msgs 100k diffs":
    let now = getNowInNanosecondTime()
    let clock = proc(): Timestamp {.gcsafe, raises: [].} =
      now

    server = await newTestWakuRecon(
      serverSwitch,
      @[],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      clock = clock,
    )
    client = await newTestWakuRecon(
      clientSwitch,
      @[],
      DefaultSyncRange,
      idsChannel,
      localWants,
      remoteNeeds,
      clock = clock,
    )

    const
      msgCount = 400_000
      diffCount = 100_000

    var diffMsgHashes: HashSet[WakuMessageHash]
    var missingIdx: HashSet[int]
    while missingIdx.len < diffCount:
      missingIdx.incl rand(0 ..< msgCount)

    let slice = calculateTimeRange(now, 0.seconds, DefaultSyncRange)
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

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len == diffCount
    let (_, deliveredHash) = await remoteNeeds.get()
    check deliveredHash in diffMsgHashes

  asyncTest "sync 2 nodes 100 msgs 20 diff – 1-second window":
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
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

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len == diffCount

    for _ in 0 ..< diffCount:
      let (_, deliveredHash) = await remoteNeeds.get()
      check deliveredHash in diffMsgHashes

  asyncTest "sync 2 nodes 500k msgs 300k diff – stress window":
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
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

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
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

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len == diffInWin

    for _ in 0 ..< diffInWin:
      let (_, deliveredHashes) = await remoteNeeds.popFirst()
      check deliveredHashes in inWinHashes
      check deliveredHashes notin outWinHashes ]#

  asyncTest "hash-fingerprint collision, same timestamp – stable sort":
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
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
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    defer:
      await server.stop()
      await client.stop()

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
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
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
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
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    defer:
      await server.stop()
      await client.stop()

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len == 1
    let (_, neededHash) = await remoteNeeds.get()
    check neededHash == goodHash
    check neededHash != badHash

  asyncTest "malformed ID: future-timestamp msg is ignored":
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
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
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    defer:
      await server.stop()
      await client.stop()

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len == 1
    let (_, neededHash) = await remoteNeeds.get()
    check neededHash == goodHash
    check neededHash != badHash

  asyncTest "duplicate ID is queued only once":
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    let ts = Timestamp(getNowInNanosecondTime())
    let msg = fakeWakuMessage(ts = ts, contentTopic = DefaultContentTopic)
    let h = computeMessageHash(DefaultPubsubTopic, msg)

    server.messageIngress(h, DefaultPubsubTopic, msg)
    server.messageIngress(h, DefaultPubsubTopic, msg)
    check remoteNeeds.len == 0

    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    defer:
      await server.stop()
      await client.stop()

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), $res.error

    check remoteNeeds.len == 1
    let (_, neededHash) = await remoteNeeds.get()
    check neededHash == h

  asyncTest "sync terminates immediately when no diffs exist":
    server = await newTestWakuRecon(
      serverSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )
    client = await newTestWakuRecon(
      clientSwitch, @[], DefaultSyncRange, idsChannel, localWants, remoteNeeds
    )

    let ts = Timestamp(getNowInNanosecondTime())
    let msg = fakeWakuMessage(ts = ts, contentTopic = DefaultContentTopic)
    let hash = computeMessageHash(DefaultPubsubTopic, msg)

    server.messageIngress(hash, DefaultPubsubTopic, msg)
    client.messageIngress(hash, DefaultPubsubTopic, msg)

    let idsQ = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)]()
    let wantsQ = newAsyncQueue[PeerId]()
    let needsQ = newAsyncQueue[(PeerId, Fingerprint)]()

    server =
      await newTestWakuRecon(serverSwitch, @[], DefaultSyncRange, idsQ, wantsQ, needsQ)
    client =
      await newTestWakuRecon(clientSwitch, @[], DefaultSyncRange, idsQ, wantsQ, needsQ)

    defer:
      await server.stop()
      await client.stop()

    let res = await client.storeSynchronization(Opt.some(serverPeerInfo))
    assert res.isOk(), $res.error

    check needsQ.len == 0

suite "Waku Sync: reconciliation stop":
  asyncTest "a periodic sync stopped while it waits for its peer completes its stop":
    # Given a peer that reads the first sync payload and never answers
    let
      stalledSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
      payloadRead = newFuture[void]("stalled peer read the first payload")
    await allFutures(stalledSwitch.start(), clientSwitch.start())

    proc stalledHandler(
        conn: Connection, proto: string
    ) {.async: (raises: [CancelledError]).} =
      try:
        discard await conn.readLp(-1)
        if not payloadRead.finished():
          payloadRead.complete()
        while true:
          discard await conn.readLp(-1)
      except LPStreamError:
        discard

    let stalled = LPProtocol.new(@[WakuReconciliationCodec], stalledHandler)
    await stalled.start()
    stalledSwitch.mount(stalled)
    PeerManager.new(clientSwitch).addPeer(stalledSwitch.peerInfo.toRemotePeerInfo())

    # When a node syncs with it periodically and is stopped during a round
    let client = await newTestWakuRecon(
      clientSwitch,
      idsRx = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)](),
      wantsTx = newAsyncQueue[PeerId](),
      needsTx = newAsyncQueue[(PeerId, WakuMessageHash)](),
      syncInterval = 100.milliseconds,
    )
    check await payloadRead.withTimeout(5.seconds)
    let stopping = client.stop()

    # Then the stop completes
    check await stopping.join().withTimeout(3.seconds)

    await stalledSwitch.stop()
    await clientSwitch.stop()

suite "Waku Sync: transfer handler cancellation":
  asyncTest "a transfer handler cancelled while it archives a message ends cancelled":
    # Given a receiver whose archive insert waits
    let
      driver = HeldPutDriver(
        putStarted: newFuture[void]("put started"),
        release: newFuture[void]("release put"),
      )
      receiver = SyncTransfer.new(
        peerManager = PeerManager.new(newTestSwitch()),
        wakuArchive = newWakuArchive(driver),
        idsTx = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)](),
        localWantsRx = newAsyncQueue[PeerId](),
        remoteNeedsRx = newAsyncQueue[(PeerId, WakuMessageHash)](),
        maxMessageSize = int(DefaultMaxWakuMessageSize),
      )
      stream = BufferStream.new()
      payload = WakuMessageAndTopic(
        pubsub: DefaultPubsubTopic, message: fakeWakuMessage()
      ).encode()

    # When its handler reads a message and is cancelled during the insert
    let handling = receiver.handler(stream, WakuTransferCodec)
    await stream.pushData(@(PB.toBytes(uint64(payload.len)).toOpenArray()) & payload)
    check await driver.putStarted.withTimeout(5.seconds)
    handling.cancelSoon()

    # Then the handler ends cancelled
    check:
      await handling.join().withTimeout(1.seconds)
      handling.cancelled()

    await stream.close()

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
    serverPeerManager {.threadvar.}: PeerManager
    clientPeerManager {.threadvar.}: PeerManager
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
      maxMessageSize = int(DefaultMaxWakuMessageSize),
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
      maxMessageSize = int(DefaultMaxWakuMessageSize),
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

    serverDriver = await serverDriver.put(DefaultPubsubTopic, msgs)

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

  asyncTest "transfer a 100 KiB message and a message encoded at the default limit":
    let
      maxSize = int(DefaultMaxWakuMessageSize)
      largeMsg = fakeWakuMessage(payload = newSeq[byte](100 * 1024))
      encodingOverhead =
        fakeWakuMessage(payload = newSeq[byte](maxSize)).encode().len - maxSize
      atLimitMsg = fakeWakuMessage(payload = newSeq[byte](maxSize - encodingOverhead))
      laterMsg = fakeWakuMessage()
      largeHash = computeMessageHash(DefaultPubsubTopic, largeMsg)
      atLimitHash = computeMessageHash(DefaultPubsubTopic, atLimitMsg)
      laterHash = computeMessageHash(DefaultPubsubTopic, laterMsg)

    serverDriver =
      await serverDriver.put(DefaultPubsubTopic, @[largeMsg, atLimitMsg, laterMsg])
    await clientLocalWants.put(serverPeerInfo.peerId)

    # The read limit is the max message size plus the protocol overhead, so a message
    # encoded at the limit fits together with its pubsub topic (#4485).
    await serverRemoteNeeds.put((clientPeerInfo.peerId, largeHash))
    await serverRemoteNeeds.put((clientPeerInfo.peerId, atLimitHash))
    await serverRemoteNeeds.put((clientPeerInfo.peerId, laterHash))

    check atLimitMsg.encode().len == maxSize
    checkUntilTimeout:
      await clientArchive.holdsMessages(@[largeHash, atLimitHash, laterHash])

  asyncTest "a receiver refuses messages above its limit without stalling the sender":
    # Given a third peer whose read limit is 1024 bytes plus the protocol overhead
    let (smallSwitch, small, smallArchive) = await newLimitedReceiver(1024)
    defer:
      await small.stop()
      await smallSwitch.stop()
    let smallPeerInfo = smallSwitch.peerInfo.toRemotePeerInfo()
    serverPeerManager.addPeer(smallPeerInfo)

    # and a server holding two messages of half the yamux window each, which together
    # exceed the window whatever its size, and a small one
    var bigMsgs: seq[WakuMessage]
    for i in 1 .. 2:
      bigMsgs.add(
        fakeWakuMessage(
          payload = newSeq[byte](YamuxDefaultWindowSize div 2),
          ts = now() - i.seconds.nanos,
        )
      )
    var bigHashes: seq[WakuMessageHash]
    for msg in bigMsgs:
      bigHashes.add(computeMessageHash(DefaultPubsubTopic, msg))
    let
      smallMsg = fakeWakuMessage()
      smallHash = computeMessageHash(DefaultPubsubTopic, smallMsg)
    serverDriver = await serverDriver.put(DefaultPubsubTopic, bigMsgs & @[smallMsg])
    let refusedBefore = failureCount("too_large")

    # When the server sends the big messages back to back, then the small one
    for hash in bigHashes:
      await serverRemoteNeeds.put((smallPeerInfo.peerId, hash))
    await serverRemoteNeeds.put((smallPeerInfo.peerId, smallHash))

    # Then the small one arrives: with a plain close instead of a reset, the second
    # write would block on the full window for good. At least the first big one is
    # refused; whether the receiver also sees the second depends on timing.
    checkUntilTimeout:
      await smallArchive.holdsMessages(@[smallHash])
    check failureCount("too_large") >= refusedBefore + 1
    for hash in bigHashes:
      check not await smallArchive.holdsMessages(@[hash])

  asyncTest "a sender does not re-send a message its peer refused as too large":
    # Given a server holding a message above the default read limit, which the
    # client refuses, but below the yamux window, so its own write succeeds
    let
      bigMsg = fakeWakuMessage(payload = newSeq[byte](230_000))
      bigHash = computeMessageHash(DefaultPubsubTopic, bigMsg)
      smallMsg = fakeWakuMessage()
      smallHash = computeMessageHash(DefaultPubsubTopic, smallMsg)
    check:
      encodedLen(bigMsg) >
        int(DefaultMaxWakuMessageSize) + DefaultSafetyBufferProtocolOverhead
      encodedLen(bigMsg) < YamuxDefaultWindowSize
    serverDriver = await serverDriver.put(DefaultPubsubTopic, @[bigMsg, smallMsg])
    let refusedBefore = failureCount("too_large")

    # When the client refuses it once
    await serverRemoteNeeds.put((clientPeerInfo.peerId, bigHash))
    checkUntilTimeout:
      failureCount("too_large") == refusedBefore + 1
    # The receiver counts before it resets, so give the reset time to reach the
    # server; otherwise the next write may land in the old session.
    await sleepAsync(200.milliseconds)

    # and the next round asks for it again, first in the queue
    await serverRemoteNeeds.put((clientPeerInfo.peerId, bigHash))

    # Then a later message arrives. It is queued again because a write into a
    # session the server has not yet seen reset fails and drops it.
    var smallHeld = false
    for _ in 0 ..< 10:
      await serverRemoteNeeds.put((clientPeerInfo.peerId, smallHash))
      await sleepAsync(200.milliseconds)
      if await clientArchive.holdsMessages(@[smallHash]):
        smallHeld = true
        break
    check smallHeld

    # and the big one was refused only once
    check failureCount("too_large") == refusedBefore + 1
    check not await clientArchive.holdsMessages(@[bigHash])

  asyncTest "a refused message is offered again once the sender's sync range has passed":
    # Given a sender with a 2 s sync range holding a message the client refuses
    let
      bigMsg = fakeWakuMessage(payload = newSeq[byte](230_000))
      bigHash = computeMessageHash(DefaultPubsubTopic, bigMsg)
      firstSmallMsg = fakeWakuMessage(@[byte 1])
      firstSmallHash = computeMessageHash(DefaultPubsubTopic, firstSmallMsg)
      secondSmallMsg = fakeWakuMessage(@[byte 2])
      secondSmallHash = computeMessageHash(DefaultPubsubTopic, secondSmallMsg)
      senderSwitch = newTestSwitch()
      senderPeerManager = PeerManager.new(senderSwitch)
      senderNeeds = newAsyncQueue[(PeerId, WakuMessageHash)]()
      senderDriver = await newSqliteArchiveDriver().put(
        DefaultPubsubTopic, @[bigMsg, firstSmallMsg, secondSmallMsg]
      )
      sender = SyncTransfer.new(
        peerManager = senderPeerManager,
        wakuArchive = newWakuArchive(senderDriver),
        idsTx = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)](),
        localWantsRx = newAsyncQueue[PeerId](),
        remoteNeedsRx = senderNeeds,
        maxMessageSize = int(DefaultMaxWakuMessageSize),
        syncRange = 2.seconds,
      )
    await senderSwitch.start()
    await sender.start()
    senderSwitch.mount(sender)
    defer:
      await sender.stop()
      await senderSwitch.stop()
    senderPeerManager.addPeer(clientPeerInfo)
    let refusedBefore = failureCount("too_large")

    # A write into a session the sender has not yet seen reset fails and drops
    # the message, so it is queued until the client holds it.
    proc deliver(hash: WakuMessageHash): Future[bool] {.async.} =
      for _ in 0 ..< 10:
        await senderNeeds.put((clientPeerInfo.peerId, hash))
        await sleepAsync(200.milliseconds)
        if await clientArchive.holdsMessages(@[hash]):
          return true
      return false

    # When the client refuses it once
    await senderNeeds.put((clientPeerInfo.peerId, bigHash))
    checkUntilTimeout:
      failureCount("too_large") == refusedBefore + 1
    check await deliver(firstSmallHash)

    # Then it is skipped within the sync range
    await senderNeeds.put((clientPeerInfo.peerId, bigHash))
    check await deliver(secondSmallHash)
    check failureCount("too_large") == refusedBefore + 1

    # and offered, and refused, again once the range has passed
    await sleepAsync(2500.milliseconds)
    await senderNeeds.put((clientPeerInfo.peerId, bigHash))
    checkUntilTimeout:
      failureCount("too_large") == refusedBefore + 2

  asyncTest "a malformed length prefix is counted as a read error and the next session works":
    let
      msg = fakeWakuMessage()
      hash = computeMessageHash(DefaultPubsubTopic, msg)
    clientDriver = await clientDriver.put(DefaultPubsubTopic, @[msg])
    let readErrorsBefore = failureCount("read_error")

    # When a stream to the server starts with ten varint continuation bytes
    let conn = await clientSwitch.dial(
      serverPeerInfo.peerId, serverPeerInfo.addrs, WakuTransferCodec
    )
    var junk = newSeq[byte](10)
    for b in junk.mitems:
      b = 0xFF
    await conn.write(junk)

    # Then the server counts a read error
    checkUntilTimeout:
      failureCount("read_error") == readErrorsBefore + 1
    await conn.close()

    # and still receives a message in a new session
    await clientRemoteNeeds.put((serverPeerInfo.peerId, hash))
    checkUntilTimeout:
      await serverArchive.holdsMessages(@[hash])

  asyncTest "an undecodable payload is counted as a decode error":
    let decodeErrorsBefore = failureCount("decode_error")

    # When a stream to the server carries a framed payload that is not a WakuMessageAndTopic
    let conn = await clientSwitch.dial(
      serverPeerInfo.peerId, serverPeerInfo.addrs, WakuTransferCodec
    )
    await conn.writeLp(@[byte 0xFF, 0xFF, 0xFF])

    # Then the server counts a decode error
    checkUntilTimeout:
      failureCount("decode_error") == decodeErrorsBefore + 1
    await conn.close()

  asyncTest "a transfer payload numbered as WAKU-SYNC is stored, one numbered the old way is not":
    let
      specMsg = fakeWakuMessage(payload = "message as field 1")
      oldMsg = fakeWakuMessage(payload = "pubsub topic as field 1")
      specHash = computeMessageHash(DefaultPubsubTopic, specMsg)
      oldHash = computeMessageHash(DefaultPubsubTopic, oldMsg)
      topic = DefaultPubsubTopic.toBytes()
      specPayload = lengthDelimited(1, specMsg.encode()) & lengthDelimited(2, topic)
      oldPayload = lengthDelimited(1, topic) & lengthDelimited(2, oldMsg.encode())
      decodeErrorsBefore = failureCount("decode_error")

    # When a stream to the server carries a payload in the old numbering, then one
    # numbered as WAKU-SYNC
    let conn = await clientSwitch.dial(
      serverPeerInfo.peerId, serverPeerInfo.addrs, WakuTransferCodec
    )
    await conn.writeLp(oldPayload)
    await conn.writeLp(specPayload)

    # Then the server stores the second and counts the first as a decode error. It
    # reads a stream in order, so the first is handled once the second is stored.
    checkUntilTimeout:
      await serverArchive.holdsMessages(@[specHash])
    check not await serverArchive.holdsMessages(@[oldHash])
    check failureCount("decode_error") == decodeErrorsBefore + 1
    await conn.close()

  asyncTest "a message encoded exactly at the read limit is received, one byte more is refused":
    # Given a peer whose read limit is 1024 bytes plus the protocol overhead
    let (limitedSwitch, limited, limitedArchive) = await newLimitedReceiver(1024)
    defer:
      await limited.stop()
      await limitedSwitch.stop()
    let limitedPeerInfo = limitedSwitch.peerInfo.toRemotePeerInfo()
    serverPeerManager.addPeer(limitedPeerInfo)

    # and two messages whose encoded WakuMessageAndTopic is the limit and the limit + 1
    let
      readLimit = 1024 + DefaultSafetyBufferProtocolOverhead
      encodingOverhead =
        encodedLen(fakeWakuMessage(payload = newSeq[byte](readLimit))) - readLimit
      atLimitMsg = fakeWakuMessage(payload = newSeq[byte](readLimit - encodingOverhead))
      aboveLimitMsg =
        fakeWakuMessage(payload = newSeq[byte](readLimit - encodingOverhead + 1))
      atLimitHash = computeMessageHash(DefaultPubsubTopic, atLimitMsg)
      aboveLimitHash = computeMessageHash(DefaultPubsubTopic, aboveLimitMsg)
    check:
      encodedLen(atLimitMsg) == readLimit
      encodedLen(aboveLimitMsg) == readLimit + 1
    serverDriver =
      await serverDriver.put(DefaultPubsubTopic, @[atLimitMsg, aboveLimitMsg])
    let refusedBefore = failureCount("too_large")

    # When the server sends both
    await serverRemoteNeeds.put((limitedPeerInfo.peerId, atLimitHash))
    await serverRemoteNeeds.put((limitedPeerInfo.peerId, aboveLimitHash))

    # Then the one at the limit is stored and the other is refused
    checkUntilTimeout:
      await limitedArchive.holdsMessages(@[atLimitHash])
      failureCount("too_large") == refusedBefore + 1
    check not await limitedArchive.holdsMessages(@[aboveLimitHash])

  asyncTest "a stream that ends mid-payload is a read error, not a refusal":
    let
      msg = fakeWakuMessage()
      hash = computeMessageHash(DefaultPubsubTopic, msg)
    clientDriver = await clientDriver.put(DefaultPubsubTopic, @[msg])
    let
      readErrorsBefore = failureCount("read_error")
      refusedBefore = failureCount("too_large")

    # When a stream announces 1000 bytes, sends 10 and closes
    let conn = await clientSwitch.dial(
      serverPeerInfo.peerId, serverPeerInfo.addrs, WakuTransferCodec
    )
    await conn.write(@[byte 0xE8, 0x07] & newSeq[byte](10)) # varint 1000
    await conn.close()

    # Then the server counts a read error and no refusal
    checkUntilTimeout:
      failureCount("read_error") == readErrorsBefore + 1
    check failureCount("too_large") == refusedBefore

    # and still receives a message in a new session
    await clientRemoteNeeds.put((serverPeerInfo.peerId, hash))
    checkUntilTimeout:
      await serverArchive.holdsMessages(@[hash])

  ## Disabled until we impl. DOS protection again
  #[ asyncTest "Check the exact missing messages are received":
    let timeSlice = calculateTimeRange(
      getNowInNanosecondTime(), DefaultGossipSubJitter, DefaultSyncRange
    )
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

    discard await serverDriver.put(DefaultPubsubTopic, @[msgA, msgB, msgC])
    discard await clientDriver.put(DefaultPubsubTopic, @[msgA])

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

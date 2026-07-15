## Message-path performance benchmark (Phase 1 of the async-copy refactor).
##
## Validates the decode/hash-per-message claims in
## `docs/analysis/async_copy_analysis.md` on the *current* code, before any
## Phase 2/3 change, and produces reproducible before/after numbers.
##
## Two scenarios:
##   * micro  - in-process, no network. Replays the WakuRelay inbound sequence
##              (ordered validator decode + topicHandler decode + full
##              uniqueTopicHandler dispatch chain: trace/filter/archive/sync/
##              internal/legacyApp) by calling the relay's own registered
##              artifacts. NOTE: the onRecv/onValidated/onSend gossipsub
##              observers are NOT exercised here (they fire only in real libp2p
##              dispatch) - the macro scenario covers those.
##   * macro  - two in-process nodes over loopback gossipsub. Node A publishes,
##              node B (archive + sync mounted) receives. Captures the libp2p
##              observer decodes too, so counters here show the full inbound
##              decode/hash budget.
##
## Requires `-d:msgPathCounters` (the nimble task `benchMessagePath` sets it).
## Build+run:  nimble benchMessagePath
##
## Determinism: fixed-seed workload (seed 42), payload mix 10/50/150 kB at
## 25/50/25 %, unique per-message payload prefix + timestamp (no dedup).

{.push raises: [].}

import
  std/[options, algorithm, random, monotimes, times, strformat, strutils],
  results,
  chronos,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/crypto/crypto as libp2p_keys

import
  logos_delivery/waku/[
    waku_core,
    waku_node,
    node/waku_node/relay,
    node/waku_node/store,
    waku_relay,
    waku_relay/protocol,
  ]
import brokers/broker_context
import tests/testlib/[wakucore, wakunode]
import tests/waku_archive/archive_utils

# ---------------------------------------------------------------------------
# Workload
# ---------------------------------------------------------------------------

const
  WarmupCount = 100
  MeasuredCount = 1000
  Kb = 1000
  PayloadSmall = 10 * Kb
  PayloadMedium = 50 * Kb
  PayloadLarge = 150 * Kb
  PayloadProfile = "10/50/150kB@25/50/25"

type Workload = object
  msgs: seq[WakuMessage]
  encoded: seq[seq[byte]]

proc buildSizeMix(total: int): seq[int] =
  ## Deterministic 25/50/25 size mix, shuffled with a fixed seed so ordering is
  ## stable across runs but not pathologically grouped.
  result = newSeqOfCap[int](total)
  let nSmall = total div 4
  let nLarge = total div 4
  let nMedium = total - nSmall - nLarge
  for _ in 0 ..< nSmall:
    result.add(PayloadSmall)
  for _ in 0 ..< nMedium:
    result.add(PayloadMedium)
  for _ in 0 ..< nLarge:
    result.add(PayloadLarge)
  var r = initRand(42)
  shuffle(r, result)

proc buildWorkload(shard: PubsubTopic, count: int): Workload =
  ## Generate `count` deterministic messages + their pre-encoded proto buffers.
  ## First 8 payload bytes encode the index (uniqueness -> distinct hash -> no
  ## gossipsub dedup). Timestamps are unique and near `now()` so the archive
  ## timestamp validator accepts them.
  let sizes = buildSizeMix(count)
  let baseTs = getNowInNanosecondTime()
  result.msgs = newSeqOfCap[WakuMessage](count)
  result.encoded = newSeqOfCap[seq[byte]](count)
  for i in 0 ..< count:
    let size = sizes[i]
    var payload = newSeq[byte](size)
    # unique 8-byte index prefix
    for b in 0 ..< 8:
      payload[b] = byte((i shr (b * 8)) and 0xFF)
    # deterministic filler (content does not affect decode/hash cost, size does)
    for j in 8 ..< size:
      payload[j] = byte((j * 2654435761 + i) and 0xFF)
    let msg = WakuMessage(
      payload: payload,
      contentTopic: DefaultContentTopic,
      meta: @[],
      version: 2,
      timestamp: Timestamp(int64(baseTs) + int64(i)),
      ephemeral: false,
      proof: @[],
    )
    result.msgs.add(msg)
    result.encoded.add(msg.encode().buffer)

# ---------------------------------------------------------------------------
# Metrics helpers
# ---------------------------------------------------------------------------

type ScenarioResult = object
  scenario: string
  msgs: int
  wallNs: int64
  p50Ns: int64
  p99Ns: int64
  decodeCalls: int64
  hashCalls: int64
  decodedBytes: int64
  hashedBytes: int64
  occupiedDeltaBytes: int64
  gcStats: string

proc percentiles(durs: var seq[int64]): (int64, int64) =
  if durs.len == 0:
    return (0'i64, 0'i64)
  sort(durs)
  let p50 = durs[durs.len div 2]
  let p99 = durs[min(durs.len - 1, (durs.len * 99) div 100)]
  (p50, p99)

proc parseGcCollections(stats: string): int64 =
  ## Best-effort extraction of a collections count from GC_getStatistics().
  for line in stats.splitLines():
    let low = line.toLowerAscii()
    if "collections" in low:
      for tok in low.split({' ', ':', '\t'}):
        try:
          if tok.len > 0 and tok[0] in {'0' .. '9'}:
            return parseBiggestInt(tok)
        except ValueError:
          discard
  return 0

const CsvHeader =
  "scenario,msgs,payload_profile,wall_ms,msg_per_s,ns_per_msg_p50,ns_per_msg_p99," &
  "decodes_per_msg,hashes_per_msg,hashed_MB,decoded_MB,occupied_mem_delta_MB,gc_collections"

proc emit(res: ScenarioResult) =
  let wallMs = res.wallNs.float / 1_000_000.0
  let msgPerS =
    if res.wallNs > 0:
      res.msgs.float * 1_000_000_000.0 / res.wallNs.float
    else:
      0.0
  let msgsDiv = max(res.msgs, 1).float
  let decodesPerMsg = res.decodeCalls.float / msgsDiv
  let hashesPerMsg = res.hashCalls.float / msgsDiv
  let hashedMB = res.hashedBytes.float / 1_000_000.0
  let decodedMB = res.decodedBytes.float / 1_000_000.0
  let memDeltaMB = res.occupiedDeltaBytes.float / 1_000_000.0
  let gcColl = parseGcCollections(res.gcStats)

  echo "----------------------------------------------------------------"
  echo "scenario           : ", res.scenario
  echo "messages           : ", res.msgs
  echo "payload_profile    : ", PayloadProfile
  echo "wall               : ", fmt"{wallMs:.3f} ms"
  echo "throughput         : ", fmt"{msgPerS:.1f} msg/s"
  echo "ns/msg p50 / p99   : ", res.p50Ns, " / ", res.p99Ns
  echo "decodes_per_msg    : ",
    fmt"{decodesPerMsg:.3f}", "  (", res.decodeCalls, " total)"
  echo "hashes_per_msg     : ", fmt"{hashesPerMsg:.3f}", "  (", res.hashCalls, " total)"
  echo "decoded_MB         : ", fmt"{decodedMB:.2f}"
  echo "hashed_MB          : ", fmt"{hashedMB:.2f}"
  echo "occupied_mem_delta : ", fmt"{memDeltaMB:.2f} MB"
  echo "GC_getStatistics   :"
  echo res.gcStats
  echo "CSV,",
    res.scenario,
    ",",
    res.msgs,
    ",",
    PayloadProfile,
    ",",
    fmt"{wallMs:.3f}",
    ",",
    fmt"{msgPerS:.1f}",
    ",",
    res.p50Ns,
    ",",
    res.p99Ns,
    ",",
    fmt"{decodesPerMsg:.3f}",
    ",",
    fmt"{hashesPerMsg:.3f}",
    ",",
    fmt"{hashedMB:.2f}",
    ",",
    fmt"{decodedMB:.2f}",
    ",",
    fmt"{memDeltaMB:.2f}",
    ",",
    gcColl

# ---------------------------------------------------------------------------
# Node setup
# ---------------------------------------------------------------------------

proc dummyHandler(envelope: WakuEnvelope) {.async, gcsafe.} =
  discard

proc buildIngestNode(
    shard: PubsubTopic, appHandler: WakuRelayHandler
): Future[WakuNode] {.async.} =
  ## A single node: relay + archive (in-memory sqlite) + store-sync, subscribed
  ## to `shard`. Built under a fresh broker context (mirrors the test helpers).
  ## `appHandler` is installed as the (only) relay app handler for the shard;
  ## registerRelayHandler ignores later handlers on an already-subscribed shard,
  ## so the receiving node must be built with its counting handler up front.
  var node: WakuNode
  lockNewGlobalBrokerContext:
    node = newTestWakuNode(generateSecp256k1Key())
    node.mountMetadata(DefaultClusterId, @[DefaultShardId]).isOkOr:
      raiseAssert "mountMetadata failed: " & error
    (await node.mountRelay()).isOkOr:
      raiseAssert "mountRelay failed: " & error
    node.mountArchive(newSqliteArchiveDriver()).isOkOr:
      raiseAssert "mountArchive failed: " & error
    (await node.mountStoreSync(DefaultClusterId, @[DefaultShardId], @[], 3600, 300, 20)).isOkOr:
      raiseAssert "mountStoreSync failed: " & error
    await node.start()
  node.subscribe((kind: PubsubSub, topic: shard), appHandler).isOkOr:
    raiseAssert "subscribe failed: " & error
  return node

# ---------------------------------------------------------------------------
# Micro scenario
# ---------------------------------------------------------------------------

proc runMicro(
    node: WakuNode, shard: PubsubTopic, work: Workload, label: string
): Future[ScenarioResult] {.async.} =
  let relay = node.wakuRelay
  let validator = relay.benchTopicValidator(shard)
  let handler = relay.benchTopicHandler(shard)
  doAssert not validator.isNil(), "no validator installed for shard"
  doAssert not handler.isNil(), "no topicHandler installed for shard"

  # Warmup (excluded from timing and counters)
  for i in 0 ..< min(WarmupCount, work.encoded.len):
    discard await validator(shard, Message(topic: shard, data: work.encoded[i]))
    await handler(shard, work.encoded[i])

  GC_fullCollect()
  resetMsgPathCounters()
  let occBefore = getOccupiedMem()
  var durs = newSeqOfCap[int64](work.encoded.len)

  let wallStart = getMonoTime()
  for i in 0 ..< work.encoded.len:
    let t0 = getMonoTime()
    discard await validator(shard, Message(topic: shard, data: work.encoded[i]))
    await handler(shard, work.encoded[i])
    durs.add((getMonoTime() - t0).inNanoseconds)
  let wallNs = (getMonoTime() - wallStart).inNanoseconds

  let occAfter = getOccupiedMem()
  let (p50, p99) = percentiles(durs)

  return ScenarioResult(
    scenario: label,
    msgs: work.encoded.len,
    wallNs: wallNs,
    p50Ns: p50,
    p99Ns: p99,
    decodeCalls: msgPathCounters.decodeCalls,
    hashCalls: msgPathCounters.hashCalls,
    decodedBytes: msgPathCounters.decodedBytes,
    hashedBytes: msgPathCounters.hashedBytes,
    occupiedDeltaBytes: int64(occAfter) - int64(occBefore),
    gcStats: GC_getStatistics(),
  )

# ---------------------------------------------------------------------------
# Macro scenario
# ---------------------------------------------------------------------------

type Arrivals = ref object
  count: int
  target: int
  done: AsyncEvent
  times: seq[MonoTime]

proc runMacro(shard: PubsubTopic, work: Workload): Future[ScenarioResult] {.async.} =
  let arrivals = Arrivals(
    count: 0,
    target: work.msgs.len,
    done: newAsyncEvent(),
    times: newSeqOfCap[MonoTime](work.msgs.len),
  )

  proc countingHandler(envelope: WakuEnvelope) {.async, gcsafe.} =
    arrivals.times.add(getMonoTime())
    arrivals.count += 1
    if arrivals.count >= arrivals.target:
      arrivals.done.fire()

  # Node B: receiver with archive + sync, counting handler installed up front.
  let nodeB = await buildIngestNode(shard, countingHandler)

  # Node A: publisher (relay only).
  var nodeA: WakuNode
  lockNewGlobalBrokerContext:
    nodeA = newTestWakuNode(generateSecp256k1Key())
    nodeA.mountMetadata(DefaultClusterId, @[DefaultShardId]).isOkOr:
      raiseAssert "nodeA mountMetadata failed: " & error
    (await nodeA.mountRelay()).isOkOr:
      raiseAssert "nodeA mountRelay failed: " & error
    await nodeA.start()
  nodeA.subscribe((kind: PubsubSub, topic: shard), dummyHandler).isOkOr:
    raiseAssert "nodeA subscribe failed: " & error

  await nodeA.connectToNodes(@[nodeB.peerInfo.toRemotePeerInfo()])

  # Wait for the relay mesh to form.
  var meshFormed = false
  for _ in 0 ..< 100:
    if nodeA.wakuRelay.getNumPeersInMesh(shard).valueOr(0) > 0:
      meshFormed = true
      break
    await sleepAsync(chronos.milliseconds(100))
  doAssert meshFormed, "nodeA<->nodeB relay mesh did not form"

  # Warmup publishes (separate messages so they don't count against the batch).
  let warmup = buildWorkload(shard, min(WarmupCount, 50))
  for i in 0 ..< warmup.msgs.len:
    discard await nodeA.publish(some(shard), warmup.msgs[i])
  # let warmup drain
  await sleepAsync(chronos.milliseconds(500))

  GC_fullCollect()
  resetMsgPathCounters()
  arrivals.count = 0
  arrivals.times.setLen(0)
  let occBefore = getOccupiedMem()

  var pubOk = 0
  var pubErr = 0
  let wallStart = getMonoTime()
  for i in 0 ..< work.msgs.len:
    let r = await nodeA.publish(some(shard), work.msgs[i])
    if r.isOk():
      pubOk += 1
    else:
      pubErr += 1
    # Flow control: pace the publisher to node B's consumption so the single
    # loopback gossipsub send queue never overflows (bursts drop large msgs).
    # The guard caps the wait so a dropped message can't stall the loop forever.
    var guard = 0
    while (i + 1) - arrivals.count > 32 and guard < 1000:
      await sleepAsync(chronos.milliseconds(1))
      inc guard

  # Wait for all arrivals on node B (bounded).
  let allReceived = await arrivals.done.wait().withTimeout(chronos.seconds(30))
  let wallNs = (getMonoTime() - wallStart).inNanoseconds
  echo "macro publish: ok=", pubOk, " err=", pubErr, " received=", arrivals.count
  let occAfter = getOccupiedMem()

  if not allReceived:
    echo "WARNING macro: only ",
      arrivals.count, "/", arrivals.target, " messages received before timeout"

  # inter-arrival deltas as ns/msg proxy
  var durs = newSeqOfCap[int64](arrivals.times.len)
  for i in 1 ..< arrivals.times.len:
    durs.add((arrivals.times[i] - arrivals.times[i - 1]).inNanoseconds)
  let (p50, p99) = percentiles(durs)

  let received = arrivals.count
  let res = ScenarioResult(
    scenario: "macro",
    msgs: received,
    wallNs: wallNs,
    p50Ns: p50,
    p99Ns: p99,
    decodeCalls: msgPathCounters.decodeCalls,
    hashCalls: msgPathCounters.hashCalls,
    decodedBytes: msgPathCounters.decodedBytes,
    hashedBytes: msgPathCounters.hashedBytes,
    occupiedDeltaBytes: int64(occAfter) - int64(occBefore),
    gcStats: GC_getStatistics(),
  )

  await nodeA.stop()
  await nodeB.stop()
  return res

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

proc main() {.async.} =
  when not defined(msgPathCounters):
    echo "ERROR: build with -d:msgPathCounters (use `nimble benchMessagePath`)"
    return

  let shard = DefaultPubsubTopic
  echo "=== message_path_bench ==="
  echo CsvHeader

  # Micro: run twice for the determinism check.
  let microNode = await buildIngestNode(shard, dummyHandler)
  let work = buildWorkload(shard, MeasuredCount)

  let micro1 = await runMicro(microNode, shard, work, "micro_run1")
  emit(micro1)
  let micro2 = await runMicro(microNode, shard, work, "micro_run2")
  emit(micro2)

  let s1 = micro1.msgs.float * 1e9 / micro1.wallNs.float
  let s2 = micro2.msgs.float * 1e9 / micro2.wallNs.float
  let variancePct = abs(s1 - s2) / max(s1, s2) * 100.0
  echo "----------------------------------------------------------------"
  echo "micro determinism  : run1=",
    fmt"{s1:.1f}",
    " msg/s, run2=",
    fmt"{s2:.1f}",
    " msg/s, variance=",
    fmt"{variancePct:.2f}",
    "% (target <5%)"

  await microNode.stop()

  # Macro.
  let macroRes = await runMacro(shard, work)
  emit(macroRes)

  echo "=== done ==="

when isMainModule:
  waitFor main()

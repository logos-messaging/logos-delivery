{.used.}

## End-to-end mix transport, in one process: 4 core nodes (relay, lightpush,
## mix) and one sender publish over the real sphinx path: entry, two hops, exit
## as destination, relay publish and SURB reply.

import
  std/[net, os, strutils, sequtils],
  testutils/unittests,
  chronos,
  chronicles,
  results,
  metrics,
  stew/byteutils,
  libp2p/crypto/crypto,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p_mix/[curve25519, mix_protocol, mix_metrics]

import
  logos_delivery/waku/
    [waku_core, node/peer_manager, waku_node, waku_mix, waku_lightpush],
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  logos_delivery/waku/waku,
  logos_delivery/waku/api/publish,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/api/types,
  logos_delivery/api/conf/modes,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/[send_service, delivery_task],
  ../testlib/[wakucore, wakunode, wakunodeconf]

const
  NumCore = 4
  HopX = 1 ## core node reachable only through the byte-limited proxy
  BatchSize = 4 ## concurrent mixed sends in the batch test
  ReceiveTimeout = chronos.seconds(10)
    ## Time for the message to reach the sender over relay after the exit's
    ## reply: the gossipsub hop only, with room for a loaded CI host.

type MixNet = object
  nodes: seq[WakuNode] # 0 ..< NumCore are core, NumCore is the sender
  pubInfos: seq[MixNodePubInfo]

proc sender(mixnet: MixNet): WakuNode =
  mixnet.nodes[NumCore]

type HopCounts = object
  ## The mix counters are global to the process, which holds all five nodes. A
  ## mixed send moves them: at least two hops forward it and one exit receives
  ## it. A plain publish moves none of them.
  forwarded: float64
  exited: float64
  rejected: float64
  timeouts: float64

proc counterValue(
    counter: Counter, labels: openArray[string] = []
): float64 {.gcsafe.} =
  ## A labelled series exists only from its first increment; before that the
  ## read raises, and the value is zero.
  try:
    counter.value(labels)
  except CatchableError:
    0.0

proc surbBuildErrors(): float64 {.gcsafe.} =
  ## The counter that the mix library increments when the SURB build rejects the
  ## sender's own hop.
  {.cast(gcsafe).}:
    counterValue(mix_messages_error, ["Entry/SURB", "INVALID_MIX_INFO"])

proc hopCounts(): HopCounts {.gcsafe.} =
  {.cast(gcsafe).}:
    HopCounts(
      forwarded: counterValue(mix_messages_forwarded, ["Intermediate"]),
      exited: counterValue(mix_messages_recvd, ["Exit"]),
      rejected: counterValue(mix_surb_creds_rejected),
      timeouts: counterValue(mix_reply_timeouts),
    )

proc subscribeCores(mixnet: MixNet, shard: PubsubTopic) =
  ## The cores relay the shard; nothing reads what they receive.
  for i in 0 ..< NumCore:
    proc coreHandler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async.} =
      discard

    mixnet.nodes[i].subscribe((kind: PubsubSub, topic: shard), coreHandler).isOkOr:
      raiseAssert "subscribe core " & $i & ": " & $error

var cutCount = 0
var proxyBytes = 0
var proxyConns = 0

proc pump(
    src, dst: StreamTransport, limit: int, sent: ref int, dead: ref bool
) {.async.} =
  ## Copies src -> dst; past `limit` bytes it drops the chunk and closes both
  ## ends, as the circuit-relay `RelayConnection.write` does.
  try:
    var buf = newSeq[byte](16384)
    while not dead[]:
      let n = await src.readOnce(addr buf[0], buf.len)
      if n <= 0:
        break
      sent[] += n
      proxyBytes += n
      if limit > 0 and sent[] > limit:
        break
      discard await dst.write(addr buf[0], n)
  except CatchableError:
    discard
  dead[] = true
  src.close()
  dst.close()


proc startLimitProxy(listenPort, targetPort, limit: int): StreamServer =
  proc cb(server: StreamServer, client: StreamTransport) {.async: (raises: []).} =
    try:
      let target = await connect(initTAddress("127.0.0.1", targetPort))
      proxyConns.inc()
      let dead = new bool
      let up = new int
      let down = new int
      # `limit` applies per direction, as in the relay server.
      let a = pump(client, target, limit, up, dead)
      let b = pump(target, client, limit, down, dead)
      await allFutures(a, b)
      if limit > 0 and (up[] > limit or down[] > limit):
        cutCount.inc()
    except CatchableError:
      discard

  return createStreamServer(initTAddress("127.0.0.1", listenPort), cb, {ReuseAddr})

proc setupMixNet(basePort: int, proxyPort: int): Future[MixNet] {.async.} =
  var mixnet = MixNet()
  var mixPrivs: seq[FieldElement] = @[]
  for i in 0 .. NumCore:
    let port = basePort + i
    let n =
      if i == HopX:
        newTestWakuNode(
          generateSecp256k1Key(),
          parseIpAddress("127.0.0.1"),
          Port(port),
          extMultiAddrs =
            @[MultiAddress.init("/ip4/127.0.0.1/tcp/" & $proxyPort).tryGet()],
          extMultiAddrsOnly = true,
        )
      else:
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(port))
    let kp = generateKeyPair().expect("mix key pair")
    mixnet.nodes.add(n)
    mixPrivs.add(kp.privateKey)
    let shown = if i == HopX: proxyPort else: port
    mixnet.pubInfos.add(
      MixNodePubInfo(
        multiAddr: "/ip4/127.0.0.1/tcp/" & $shown & "/p2p/" & $n.peerInfo.peerId,
        pubKey: kp.publicKey,
      )
    )
  for i in 0 .. NumCore:
    let others = (0 .. NumCore).toSeq().filterIt(it != i).mapIt(mixnet.pubInfos[it])
    if i < NumCore:
      (await mixnet.nodes[i].mountRelay()).isOkOr:
        raiseAssert "mountRelay: " & $error
      (await mixnet.nodes[i].mountLightpush()).isOkOr:
        raiseAssert "mountLightpush: " & $error
    else:
      (await mixnet.nodes[i].mountRelay()).isOkOr:
        raiseAssert "mountRelay sender: " & $error
      mixnet.nodes[i].mountLightpushClient()
    mixnet.nodes[i].mountMetadata(uint32(DefaultClusterId), @[0'u16]).isOkOr:
      raiseAssert "mountMetadata: " & $error
    (await mixnet.nodes[i].mountMix(DefaultClusterId, mixPrivs[i], others)).isOkOr:
      raiseAssert "mountMix: " & $error
  for n in mixnet.nodes:
    await n.start()
  # HopX connects to nobody and nobody pre-connects to it: every connection
  # that reaches it is dialed by mix through the proxy address.
  for i in 0 .. NumCore:
    if i == HopX:
      continue
    let peers = (0 .. NumCore).toSeq().filterIt(it != i and it != HopX).mapIt(
        mixnet.nodes[it].peerInfo.toRemotePeerInfo()
      )
    await mixnet.nodes[i].connectToNodes(peers)
  return mixnet

proc runBatch(label: string, limit: int, basePort: int, sends: int) {.async.} =
  let proxyPort = basePort + 50
  let proxy = startLimitProxy(proxyPort, basePort + HopX, limit)
  proxy.start()
  let mixnet = await setupMixNet(basePort, proxyPort)
  let shard = DefaultPubsubTopic
  mixnet.subscribeCores(shard)
  await sleepAsync(chronos.seconds(2))
  let dest = mixnet.nodes[0].peerInfo.toRemotePeerInfo()
  var ok = 0
  var failed = 0
  var okSeq = ""
  for i in 0 ..< sends:
    let msg = WakuMessage(
      payload: toBytes("relay-limit-" & $i),
      contentTopic: "/mix-e2e/1/probe/proto",
      version: 2,
      timestamp: getNowInNanosecondTime(),
    )
    let res = await mixnet.sender().lightpushPublish(
      Opt.some(shard), msg, Opt.some(dest), mixify = true
    )
    echo "SEND ",
      label,
      " ",
      i,
      " ",
      (if res.isOk(): "ok" else: "FAIL: " & res.error.desc.get("")),
      " cuts=",
      cutCount
    stdout.flushFile()
    if res.isOk():
      ok.inc()
      okSeq.add("+")
    else:
      failed.inc()
      okSeq.add("-")
  echo "RESULT ",
    label, " limit=", limit, " ok=", ok, " failed=", failed, " proxyCuts=", cutCount, " proxyBytes=", proxyBytes, " proxyConns=", proxyConns
  echo "SEQ ", okSeq
  for n in mixnet.nodes:
    await n.stop()
  proxy.close()
  await proxy.join()

suite "Mix over a byte-limited hop":
  ## One case per process (the broker providers are process-global): set
  ## RELAY_LIMIT=0 for the baseline and RELAY_LIMIT=131072 for the limited hop.
  asyncTest "lightpush over mix with a byte-limited hop":
    let limit = parseInt(getEnv("RELAY_LIMIT", "131072"))
    await runBatch("limit" & $limit, limit, 24200, parseInt(getEnv("SENDS", "80")))

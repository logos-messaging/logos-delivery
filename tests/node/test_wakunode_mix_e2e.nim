{.used.}

## End-to-end mix transport, in one process: 4 core nodes (relay, lightpush,
## mix) and one sender publish over the real sphinx path: entry, two hops, exit
## as destination, relay publish and SURB reply.

import
  std/[net, strutils, sequtils],
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

proc setupMixNet(
    basePort: int, senderAnnounce: string = "", senderDns4 = false
): Future[MixNet] {.async.} =
  ## Builds and starts the 5-node mixnet on fixed local ports. `senderAnnounce`
  ## replaces the sender's announced address, as NAT does. `senderDns4` makes the
  ## sender announce only a dns4 name, with its external IP set as the factory does.
  var mixnet = MixNet()
  var mixPrivs: seq[FieldElement] = @[]

  for i in 0 .. NumCore:
    let port = basePort + i
    let n =
      if senderAnnounce.len > 0 and i == NumCore:
        newTestWakuNode(
          generateSecp256k1Key(),
          parseIpAddress("127.0.0.1"),
          Port(port),
          extMultiAddrs = @[MultiAddress.init(senderAnnounce).tryGet()],
          extMultiAddrsOnly = true,
        )
      elif senderDns4 and i == NumCore:
        newTestWakuNode(
          generateSecp256k1Key(),
          parseIpAddress("127.0.0.1"),
          Port(port),
          extIp = Opt.some(parseIpAddress("127.0.0.1")),
          extPort = Opt.some(Port(port)),
          dns4DomainName = Opt.some("sender.test"),
        )
      else:
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(port))
    let kp = generateKeyPair().expect("mix key pair")
    mixnet.nodes.add(n)
    mixPrivs.add(kp.privateKey)
    mixnet.pubInfos.add(
      MixNodePubInfo(
        multiAddr: "/ip4/127.0.0.1/tcp/" & $port & "/p2p/" & $n.peerInfo.peerId,
        pubKey: kp.publicKey,
      )
    )

  for i in 0 .. NumCore:
    let others = (0 .. NumCore).toSeq().filterIt(it != i).mapIt(mixnet.pubInfos[it])
    if i < NumCore:
      (await mixnet.nodes[i].mountRelay()).isOkOr:
        raiseAssert "mountRelay core " & $i & ": " & $error
      (await mixnet.nodes[i].mountLightpush()).isOkOr:
        raiseAssert "mountLightpush core " & $i & ": " & $error
    else:
      (await mixnet.nodes[i].mountRelay()).isOkOr:
        raiseAssert "mountRelay sender: " & $error
      mixnet.nodes[i].mountLightpushClient()
    # Every node mounts waku-metadata for the cluster: a node with waku-metadata
    # drops a peer that does not speak it for the same cluster, after identify.
    mixnet.nodes[i].mountMetadata(uint32(DefaultClusterId), @[0'u16]).isOkOr:
      raiseAssert "mountMetadata " & $i & ": " & $error
    (await mixnet.nodes[i].mountMix(DefaultClusterId, mixPrivs[i], others)).isOkOr:
      raiseAssert "mountMix " & $i & ": " & $error

  for n in mixnet.nodes:
    await n.start()

  for i in 0 .. NumCore:
    let peers = (0 .. NumCore).toSeq().filterIt(it != i).mapIt(
        mixnet.nodes[it].peerInfo.toRemotePeerInfo()
      )
    await mixnet.nodes[i].connectToNodes(peers)

  return mixnet

proc teardownMixNet(mixnet: MixNet) {.async.} =
  for n in mixnet.nodes:
    await n.stop()

suite "Waku Mix - end to end transport":
  asyncTest "a message crosses the mixnet and the reply comes back":
    let mixnet = await setupMixNet(23840)
    defer:
      await teardownMixNet(mixnet)

    check mixnet.sender().getMixNodePoolSize() == NumCore

    let shard = DefaultPubsubTopic
    let marker = "mix-e2e-" & $Moment.now()
    let arrival = newFuture[string]("mix-e2e-arrival")

    proc handler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async.} =
      let p = string.fromBytes(msg.payload)
      if p.startsWith(marker) and not arrival.finished():
        arrival.complete(p)

    mixnet.sender().subscribe((kind: PubsubSub, topic: shard), handler).isOkOr:
      raiseAssert "subscribe sender: " & $error
    mixnet.subscribeCores(shard)

    await sleepAsync(chronos.seconds(2)) # gossipsub mesh

    let msg = WakuMessage(
      payload: toBytes(marker & " over mix"),
      contentTopic: "/mix-e2e/1/probe/proto",
      version: 2,
      timestamp: getNowInNanosecondTime(),
    )
    let dest = mixnet.nodes[0].peerInfo.toRemotePeerInfo()
    let before = hopCounts()
    let res = await mixnet.sender().lightpushPublish(
      Opt.some(shard), msg, Opt.some(dest), mixify = true
    )

    # The SURB reply is the lightpush response itself.
    check res.isOk()

    # The exit really published: the message comes back to the sender on relay.
    # The handler completes the future only on the marker, so arrival is proof.
    check await arrival.withTimeout(ReceiveTimeout)

    # At least two hops forwarded the packet and the exit received it; a plain
    # publish passes the two checks above.
    let after = hopCounts()
    check:
      after.forwarded - before.forwarded >= 2.0
      after.exited - before.exited >= 1.0

  asyncTest "four mixed sends in flight at once all get their own reply":
    ## Four mixed sends from one node at once each complete on their own reply
    ## and release their own credentials. The batched send pass relies on this.
    let mixnet = await setupMixNet(23900)
    defer:
      await teardownMixNet(mixnet)

    let shard = DefaultPubsubTopic
    let marker = "mix-e2e-batch-" & $Moment.now()
    var arrivals: seq[string]
    let allArrived = newFuture[void]("mix-e2e-batch-arrivals")

    proc handler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async.} =
      let p = string.fromBytes(msg.payload)
      if p.startsWith(marker) and p notin arrivals:
        arrivals.add(p)
        if arrivals.len == BatchSize and not allArrived.finished():
          allArrived.complete()

    mixnet.sender().subscribe((kind: PubsubSub, topic: shard), handler).isOkOr:
      raiseAssert "subscribe sender: " & $error
    mixnet.subscribeCores(shard)

    await sleepAsync(chronos.seconds(2)) # gossipsub mesh

    let dest = mixnet.nodes[0].peerInfo.toRemotePeerInfo()
    let before = hopCounts()
    var sends: seq[Future[WakuLightPushResult]]
    for i in 0 ..< BatchSize:
      let msg = WakuMessage(
        payload: toBytes(marker & " batch " & $i),
        contentTopic: "/mix-e2e/1/probe/proto",
        version: 2,
        timestamp: getNowInNanosecondTime(),
      )
      sends.add(
        mixnet.sender().lightpushPublish(
          Opt.some(shard), msg, Opt.some(dest), mixify = true
        )
      )
    await allFutures(sends)

    # Every send completed on its own reply; an ok result already means the
    # exit relayed to at least one peer.
    for send in sends:
      check send.read().isOk()

    # All four came back over relay, and no SURB credential is left behind.
    check await allArrived.withTimeout(ReceiveTimeout)
    let after = hopCounts()
    check:
      arrivals.len == BatchSize
      mixnet.sender().wakuMix.surbCredsLen() == 0
      # Four packets crossed the exit: the four open sends never crossed.
      after.exited - before.exited >= float64(BatchSize)
      # These fail only if the node's 5 s deadline stops preempting the library's
      # 30 s reply timeout, or one credential per send reaches the store's cap.
      after.rejected == before.rejected
      after.timeouts == before.timeouts

  asyncTest "the reply arrives over existing connections, not the advertised address":
    ## A sender behind NAT: nobody can dial its announced address, which the SURB
    ## embeds. The reply still arrives, because the last hop reuses its live
    ## connection to the sender's peer id.
    let mixnet = await setupMixNet(23860, senderAnnounce = "/ip4/127.0.0.1/tcp/23879")
    defer:
      await teardownMixNet(mixnet)

    let shard = DefaultPubsubTopic
    let msg = WakuMessage(
      payload: toBytes("mix-e2e-natsim over mix"),
      contentTopic: "/mix-e2e/1/probe/proto",
      version: 2,
      timestamp: getNowInNanosecondTime(),
    )
    mixnet.subscribeCores(shard)
    await sleepAsync(chronos.seconds(2))

    let dest = mixnet.nodes[1].peerInfo.toRemotePeerInfo()
    let before = hopCounts()
    let res = await mixnet.sender().lightpushPublish(
      Opt.some(shard), msg, Opt.some(dest), mixify = true
    )
    check res.isOk()
    # A plain publish also returns ok, so check the mix counters.
    let after = hopCounts()
    check:
      after.forwarded - before.forwarded >= 2.0
      after.exited - before.exited >= 1.0

  asyncTest "a sender announcing only a name is answered at the host the name resolved to":
    ## The fleet's shape: `--dns4-domain-name` makes the sender announce a name,
    ## which mix cannot encode. The self hop is the resolved ENR endpoint, so the
    ## SURB build succeeds.
    let mixnet = await setupMixNet(23890, senderDns4 = true)
    defer:
      await teardownMixNet(mixnet)

    check:
      mixnet.sender().announcedAddresses.allIt("/dns4/" in $it)
      $mixnet.sender().wakuMix.localMixPubInfo().multiAddr ==
        "/ip4/127.0.0.1/tcp/" & $(23890 + NumCore)

    let shard = DefaultPubsubTopic
    let msg = WakuMessage(
      payload: toBytes("mix-e2e-dns4 sender over mix"),
      contentTopic: "/mix-e2e/1/probe/proto",
      version: 2,
      timestamp: getNowInNanosecondTime(),
    )
    mixnet.subscribeCores(shard)
    await sleepAsync(chronos.seconds(2))

    let dest = mixnet.nodes[1].peerInfo.toRemotePeerInfo()
    let before = hopCounts()
    let surbErrorsBefore = surbBuildErrors()
    let res = await mixnet.sender().lightpushPublish(
      Opt.some(shard), msg, Opt.some(dest), mixify = true
    )
    check res.isOk()
    check mixnet.sender().wakuMix.surbCredsLen() == 0
    # The packet went through mix, and the SURB build did not reject the hop.
    let after = hopCounts()
    check:
      after.forwarded - before.forwarded >= 2.0
      after.exited - before.exited >= 1.0
      surbBuildErrors() == surbErrorsBefore

  asyncTest "a mixed send through the send service completes and is marked as mixed":
    ## `MixSendProcessor` sets `propagatedAnonymously` after a real mixed publish, which
    ## no unit test reaches. The sender is a `Waku` with the `Required` chain.
    let mixnet = await setupMixNet(23910)
    defer:
      await teardownMixNet(mixnet)
    let shard = DefaultPubsubTopic
    mixnet.subscribeCores(shard)

    # The same cluster as the cores: a metadata mismatch would disconnect them
    # and empty the pool.
    var nodeConf = defaultTestWakuNodeConf()
    nodeConf.clusterId = Opt.some(DefaultClusterId)
    let conf = nodeConf.toWakuConf().valueOr:
      raiseAssert error
    let waku = (await Waku.new(conf)).expect("Waku.new")
    defer:
      discard await waku.stop()
    let kp = generateKeyPair().expect("mix key pair")
    (
      await waku.node.mountMix(
        DefaultClusterId, kp.privateKey, mixnet.pubInfos[0 ..< NumCore]
      )
    ).isOkOr:
      raiseAssert "mountMix sender: " & $error
    (await waku.start()).expect("start")
    await waku.node.connectToNodes(
      (0 ..< NumCore).toSeq().mapIt(mixnet.nodes[it].peerInfo.toRemotePeerInfo())
    )
    # Identify fills this from waku-metadata too; set it here so the exit scan
    # does not wait for that round trip.
    let shardInfo = RelayShard.parse(shard).expect("shard")
    for i in 0 ..< NumCore:
      waku.node.peerManager.switch.peerStore.setShardInfo(
        mixnet.nodes[i].peerInfo.peerId, @[shardInfo.shardId]
      )
    # Identify fills the lightpush codec on connect; wait for the exit scan.
    let deadline = Moment.now() + chronos.seconds(5)
    while not (waku.mixReady() and waku.selectMixLightpushPeer(shard).isSome()) and
        Moment.now() < deadline:
      await sleepAsync(chronos.milliseconds(50))
    check:
      waku.mixReady()
      waku.selectMixLightpushPeer(shard).isSome()

    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let chain = setupSendProcessorChain(waku, AnonymityLevel.Required).expect("chain")
    let service = SendService
      .new(false, waku, manager, chain, AnonymityLevel.Required)
      .expect("SendService.new")
    let msg = WakuMessage(
      payload: toBytes("mix-e2e-send-service over mix"),
      contentTopic: "/mix-e2e/1/probe/proto",
      version: 2,
      timestamp: getNowInNanosecondTime(),
    )
    let task = DeliveryTask(
      requestId: RequestId("mix-e2e-required"),
      pubsubTopic: shard,
      msg: msg,
      msgHash: computeMessageHash(shard, msg),
      state: DeliveryState.Entry,
      firstAdmittedTime: Opt.some(Moment.now()), # admitted: no budget, no proof
    )
    let before = hopCounts()
    await service.send(task)
    let after = hopCounts()
    check:
      task.state == DeliveryState.SuccessfullyPropagated
      task.propagatedAnonymously # no store query for this task
      task.anonymized # set at the attempt
      after.exited - before.exited >= 1.0

{.used.}

import std/net
import chronos, chronicles, testutils/unittests, results, stew/byteutils

import
  libp2p_mix/curve25519,
  libp2p/[peerid, multiaddress],
  libp2p/stream/connection,
  logos_delivery/waku/waku,
  logos_delivery/waku/api/publish,
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  logos_delivery/waku/node/waku_node/lightpush,
  logos_delivery/waku/waku_lightpush/common,
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service, send_processor, mix_processor, delivery_task]
import ../testlib/[testasync, wakucore]

## Anonymity-level coverage for the send path: the mix processor owns the task
## for a whole mix window, and only a `BestEffort` chain ever hands it to the
## plain relay/lightpush processors behind it. The node under test has no mix
## mounted, which is exactly the "mix cannot deliver" case the levels differ on.

type PlainSendProcessor = ref object of BaseSendProcessor
  calls: int

method isValidProcessor(self: PlainSendProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: PlainSendProcessor, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  task.state = DeliveryState.SuccessfullyPropagated
  task.firstPropagatedTime = Opt.some(Moment.now())

proc testConf(): WakuConf =
  var conf = MessagingClientConf()
    .toWakuNodeConf(messaging_conf.LogosDeliveryMode.Core).valueOr:
      raiseAssert error
  conf.listenAddress = parseIpAddress("0.0.0.0")
  conf.tcpPort = Port(0)
  conf.discv5UdpPort = Port(0)
  conf.clusterId = Opt.some(3'u16)
  conf.numShardsInNetwork = 1
  conf.rest = false
  return conf.toWakuConf().valueOr:
    raiseAssert error

suite "SendService - anonymity level":
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")

  asyncTeardown:
    discard await waku.stop()

  proc buildTask(id: string, admittedAgo: Duration): DeliveryTask =
    let msg = WakuMessage(
      contentTopic: "/test/1/anonymity/proto",
      payload: "hi".toBytes(),
      timestamp: 1_700_000_000_000_000_000,
    )
    let pubsubTopic = PubsubTopic("/waku/2/rs/3/0")
    return DeliveryTask(
      requestId: RequestId(id),
      pubsubTopic: pubsubTopic,
      msg: msg,
      msgHash: computeMessageHash(pubsubTopic, msg),
      state: DeliveryState.Entry,
      firstAdmittedTime: Opt.some(Moment.now() - admittedAgo),
    )

  asyncTest "a Required task keeps waiting for mix instead of using the plain path":
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("required", chronos.minutes(10))
    await mix.process(task)

    check:
      plain.calls == 0 # mix cannot deliver, but the plain path is off limits
      task.state == DeliveryState.NextRoundRetry

  asyncTest "a BestEffort task stays on mix while the mix window is open":
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.BestEffort, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("best-effort-early", chronos.seconds(5))
    await mix.process(task)

    check:
      plain.calls == 0
      task.state == DeliveryState.NextRoundRetry

  asyncTest "a BestEffort task falls back to the plain path once the window elapsed":
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.BestEffort, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("best-effort-late", chronos.minutes(2))
    # Mix has owned the task since admission and got nowhere with it.
    task.firstMixTriedTime = Opt.some(Moment.now() - chronos.minutes(2))
    await mix.process(task)

    check:
      plain.calls == 1
      task.state == DeliveryState.SuccessfullyPropagated

  asyncTest "an RLN proof refresh does not restart the BestEffort mix window":
    ## `parkForRlnProofRefresh` clears `firstAdmittedTime` on purpose, to
    ## re-charge the nonce the regenerated proof draws. A mix window measured
    ## off that field would restart on every stale proof and strand the task on
    ## mix forever, so the window keeps its own timestamp.
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.BestEffort, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("rln-park", chronos.minutes(2))
    task.firstMixTriedTime = Opt.some(Moment.now() - chronos.minutes(2))
    task.firstAdmittedTime = Opt.none(Moment) # what the RLN park leaves behind

    await mix.process(task)

    check:
      plain.calls == 1
      task.state == DeliveryState.SuccessfullyPropagated

  asyncTest "the mix window starts when mix first takes the task, not at admission":
    ## A task parked for rate-limit budget must not burn its mix window while
    ## parked, so the window cannot start before the mix processor sees it.
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.BestEffort, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("late-admission", chronos.minutes(2))
    check task.firstMixTriedTime.isNone()

    await mix.process(task)

    check:
      task.firstMixTriedTime.isSome() # stamped on this first pass ...
      plain.calls == 0 # ... so the window has not elapsed yet
      task.state == DeliveryState.NextRoundRetry

  asyncTest "BestEffort gets a second delivery window, the other levels do not":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")

    let plainService = SendService
      .new(false, waku, manager, anonymityLevel = AnonymityLevel.None)
      .expect("SendService.new")
    let mixOnlyService = SendService
      .new(false, waku, manager, anonymityLevel = AnonymityLevel.Required)
      .expect("SendService.new")
    let bestEffortService = SendService
      .new(false, waku, manager, anonymityLevel = AnonymityLevel.BestEffort)
      .expect("SendService.new")

    check:
      plainService.maxDeliveryTime == MaxTimeInCache
      mixOnlyService.maxDeliveryTime == MaxTimeInCache
      bestEffortService.maxDeliveryTime == MaxTimeInCache + MaxTimeInCache

suite "Mix send path - exit peer selection":
  ## With `exit_is_dest` the lightpush server terminates the sphinx path, so mix
  ## refuses a destination that carries no mix public key. Selection must skip
  ## plain lightpush peers instead of handing mix an unusable exit.
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")

  asyncTeardown:
    discard await waku.stop()

  const shard = PubsubTopic("/waku/2/rs/3/0")

  proc addLightpushPeer(
      mixCapable: bool, address = "/ip4/127.0.0.1/tcp/60000"
  ): PeerId =
    let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
    let keyPair = generateKeyPair().expect("mix key pair")
    let mixPubKey =
      if mixCapable:
        Opt.some(keyPair.publicKey)
      else:
        Opt.none(typeof(keyPair.publicKey))
    waku.node.peerManager.addPeer(
      RemotePeerInfo.init(
        peerId,
        @[MultiAddress.init(address).tryGet()],
        protocols = @[WakuLightPushCodec],
        shards = @[0'u16],
        mixPubKey = mixPubKey,
      )
    )
    waku.node.peerManager.switch.peerStore.setShardInfo(peerId, @[0'u16])
    return peerId

  asyncTest "a plain lightpush peer is never offered as a mix exit":
    discard addLightpushPeer(mixCapable = false)

    check:
      waku.lightpushPeerAvailable(shard) # usable for a plain send
      waku.selectMixLightpushPeer(shard).isNone() # but not as a mix exit

  asyncTest "a mix key alone does not make a peer a usable exit":
    ## Mix routes over IPv4 TCP or QUIC-v1 only. A peer advertising anything
    ## else is not in the pool however good its mix key is, and handing it over
    ## as a destination costs a delivery round and evicts it from the pool.
    discard addLightpushPeer(mixCapable = true, address = "/dns4/node.test/tcp/60000")

    check:
      waku.lightpushPeerAvailable(shard)
      waku.selectMixLightpushPeer(shard).isNone()

  asyncTest "the mix-capable peer is picked out of a mixed set":
    discard addLightpushPeer(mixCapable = false)
    let mixPeer = addLightpushPeer(mixCapable = true)
    discard addLightpushPeer(mixCapable = false)

    let selected = waku.selectMixLightpushPeer(shard).valueOr:
      raiseAssert "expected the mix-capable peer to be selected"
    check selected.peerId == mixPeer

  asyncTest "a statically configured lightpush node is usable as a mix exit":
    ## `--lightpushnode` lands in the peer manager's service slot from a bare
    ## multiaddr: no protocols, no shards, no mix key. Both of `selectPeers`'
    ## filters drop it until identify and waku-metadata have filled those books,
    ## while `selectPeer` returns it from the slot right away. Mix exit selection
    ## has to follow the slot too, or the plain path works and mix never does.
    let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
    let address = MultiAddress.init("/ip4/127.0.0.1/tcp/60000").tryGet()
    waku.node.peerManager.addServicePeer(
      RemotePeerInfo.init(peerId, @[address]), WakuLightPushCodec
    )

    check:
      waku.lightpushPeerAvailable(shard) # the plain path already works
      # ... and the peer is invisible to the shard-filtered protocol scan
      waku.node.peerManager.selectPeers(WakuLightPushCodec, Opt.some(shard)).len == 0
      waku.selectMixLightpushPeer(shard).isNone() # no mix key learned yet

    # Discovery (kademlia / rendezvous) later learns the peer's mix key.
    let keyPair = generateKeyPair().expect("mix key pair")
    waku.node.peerManager.addPeer(
      RemotePeerInfo.init(peerId, @[address], mixPubKey = Opt.some(keyPair.publicKey))
    )

    let selected = waku.selectMixLightpushPeer(shard).valueOr:
      raiseAssert "the slotted lightpush node should be offered as a mix exit"
    check selected.peerId == peerId

## A stand-in for `libp2p_mix`'s `MixEntryConnection`, reproducing the three
## behaviours that make a lost SURB reply dangerous: `write` succeeds (the
## sphinx packet left), `readOnce` blocks on a future only the reply completes,
## and `closeImpl` merely cancels the closure that would have completed it — so
## the connection has no read deadline and never reaches EOF on its own.
type StubMixConn = ref object of Connection
  incoming: AsyncQueue[seq[byte]]
  incomingFut: Future[void]
  replyReceivedFut: Future[void]
  sendStall: Future[void].Raising([CancelledError])
  stallInSend: bool
  cached: seq[byte]

method readOnce(
    s: StubMixConn, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  if s.isEof:
    raise newLPStreamEOFError()
  if s.cached.len == 0:
    try:
      await s.replyReceivedFut
      if s.cached.len == 0:
        s.isEof = true
        raise newLPStreamEOFError()
    except CancelledError as exc:
      raise exc
    except LPStreamEOFError as exc:
      raise exc
    except CatchableError as exc:
      raise (ref LPStreamError)(msg: "error in readOnce: " & exc.msg, parent: exc)
  let toRead = min(nbytes, s.cached.len)
  copyMem(pbytes, addr s.cached[0], toRead)
  s.cached = s.cached[toRead ..^ 1]
  return toRead

method write(
    s: StubMixConn, msg: sink seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
  # `stallInSend` stands in for the first-hop dial inside
  # `anonymizeLocalProtocolSend`: mix dials through `switch.dial`, bypassing the
  # peer manager and its `DefaultDialTimeout`, and mix-pool entries never
  # expire, so dialing a mix node that has gone away is the routine failure.
  if s.stallInSend:
    await s.sendStall

method closeImpl(s: StubMixConn): Future[void] {.async: (raises: []).} =
  if not s.incomingFut.isNil():
    s.incomingFut.cancelSoon()

method getWrapped(s: StubMixConn): Connection =
  nil

proc newStubMixConn(stallInSend = false): StubMixConn =
  var inst = StubMixConn(stallInSend: stallInSend)
  inst.incoming = newAsyncQueue[seq[byte]]()
  inst.replyReceivedFut = newFuture[void]("stub.replyReceived")
  inst.sendStall = Future[void].Raising([CancelledError]).init("stub.sendStall")
  let checkForIncoming = proc(): Future[void] {.async: (raises: [CancelledError]).} =
    inst.cached = await inst.incoming.get()
    inst.replyReceivedFut.complete()
  inst.incomingFut = checkForIncoming()
  return inst

suite "Mix send path - the reply budget":
  ## `publishOverMix` is the only thing bounding a mix-routed lightpush: the mix
  ## connection has no read deadline, and mix dials its first hop past the peer
  ## manager and its dial timeout. Left unbounded, either stall froze the whole
  ## send-service loop — every message on the node, not just this one. Both
  ## stalls are covered here, and what is asserted is not only that the wait
  ## ends but that *abandoning* it returns, which is the half that regressed.
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")

  asyncTeardown:
    discard await waku.stop()

  # `publishOverMix` waits `MixReplyTimeout` by default; the budget is shortened
  # here because what is under test is the guard, not the constant.
  const ReplyBudget = chronos.milliseconds(200)

  proc givesUpOn(stallInSend: bool): Future[WakuLightPushResult] {.async.} =
    ## Drives the real `publishOverMix` against a mix connection that never
    ## answers, and returns its verdict. The call is raced against a generous
    ## guard rather than awaited outright: if the guard under test ever
    ## regresses, this fails a check instead of hanging the whole suite — which
    ## is also why `publishOverMix` itself cannot be written with `withTimeout`,
    ## since that waits for the very cancellation that would be stuck.
    let conn = newStubMixConn(stallInSend = stallInSend)
    let msg = fakeWakuMessage(contentTopic = "/test/1/anonymity/proto")

    let publishFut = waku.node.publishOverMix(
      Connection(conn), PubsubTopic("/waku/2/rs/3/0"), msg, ReplyBudget
    )
    let guard = sleepAsync(chronos.seconds(5))
    discard await race(FutureBase(publishFut), FutureBase(guard))
    await guard.cancelAndWait()

    if not publishFut.finished():
      publishFut.cancelSoon()
      raiseAssert "publishOverMix never returned; the send-service loop would wedge"
    return await publishFut

  asyncTest "a dropped reply is given up on instead of waited on forever":
    let res = await givesUpOn(stallInSend = false)
    check:
      res.isErr()
      res.error.code == LightPushErrorCode.SERVICE_NOT_AVAILABLE

  asyncTest "a stalled first-hop dial is given up on too":
    ## The sibling shape, and the one that bites hardest: with the stall in the
    ## send, the reply future is still pending when the client's
    ## `defer: closeWithEOF()` reads the stream for an EOF that will never come,
    ## and closing already cancelled the closure that could have completed it.
    ## Without the `reset` that makes `closeWithEOF` take its early return, the
    ## unwind never finishes and the whole send-service loop wedges with it.
    let res = await givesUpOn(stallInSend = true)
    check:
      res.isErr()
      res.error.code == LightPushErrorCode.SERVICE_NOT_AVAILABLE

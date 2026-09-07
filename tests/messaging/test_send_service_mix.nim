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

## Tests for the anonymity levels of the send path. The mix processor keeps the
## task for the mix window. Only a `Preferred` chain gives the task to the relay
## and lightpush processors. The node in these tests has no mix mounted, so mix
## cannot deliver.

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

  asyncTest "a Preferred task stays on mix while the mix window is open":
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("preferred-early", chronos.seconds(5))
    await mix.process(task)

    check:
      plain.calls == 0
      task.state == DeliveryState.NextRoundRetry

  asyncTest "a Preferred task falls back to the plain path once the window elapsed":
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )
    mix.chain(plain)

    # Mix had the task since admission and did not deliver it.
    let task = buildTask("preferred-late", chronos.minutes(2))
    await mix.process(task)

    check:
      plain.calls == 1
      task.state == DeliveryState.SuccessfullyPropagated

  asyncTest "an RLN proof refresh starts a new Preferred mix window":
    ## `parkForRlnProofRefresh` clears `firstAdmittedTime`, so the new proof
    ## draws a new nonce. The mix window runs from that field, so the task gets
    ## a new window and stays on mix.
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("rln-park", chronos.minutes(2))
    task.firstAdmittedTime = Opt.none(Moment) # what the RLN park leaves behind

    await mix.process(task)

    check:
      plain.calls == 0
      task.state == DeliveryState.NextRoundRetry

  asyncTest "a task parked for budget does not spend its mix window":
    ## The window runs from admission. A task that did not pass admission has
    ## no window, whatever the age of the message.
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("late-admission", chronos.minutes(2))
    task.firstAdmittedTime = Opt.none(Moment) # parked for epoch budget

    await mix.process(task)

    check:
      plain.calls == 0
      task.state == DeliveryState.NextRoundRetry

  asyncTest "Preferred gets a second delivery window, the other levels do not":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")

    let plainService = SendService
      .new(false, waku, manager, anonymityLevel = AnonymityLevel.None)
      .expect("SendService.new")
    let mixOnlyService = SendService
      .new(false, waku, manager, anonymityLevel = AnonymityLevel.Required)
      .expect("SendService.new")
    let bestEffortService = SendService
      .new(false, waku, manager, anonymityLevel = AnonymityLevel.Preferred)
      .expect("SendService.new")

    check:
      plainService.maxDeliveryTime == MaxTimeInCache
      mixOnlyService.maxDeliveryTime == MaxTimeInCache
      bestEffortService.maxDeliveryTime == MaxTimeInCache + MaxTimeInCache

suite "Mix send path - exit peer selection":
  ## With `exit_is_dest` the lightpush server is the last node of the sphinx
  ## path. Mix refuses a destination that has no mix public key. The selection
  ## must skip a plain lightpush peer.
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
    ## Mix routes IPv4 TCP and QUIC-v1 addresses only. A peer with another
    ## address is not in the pool, whatever its mix key is. Mix evicts such a
    ## peer at the first path construction.
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
    ## A `lightpushnode` peer reaches the service slot with its address only.
    ## `selectPeers` drops it until identify and waku-metadata fill the books.
    let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
    let address = MultiAddress.init("/ip4/127.0.0.1/tcp/60000").tryGet()
    waku.node.peerManager.addServicePeer(
      RemotePeerInfo.init(peerId, @[address]), WakuLightPushCodec
    )

    check:
      waku.lightpushPeerAvailable(shard) # the plain path already works
      # ... and the protocol scan with the shard filter does not return it
      waku.node.peerManager.selectPeers(WakuLightPushCodec, Opt.some(shard)).len == 0
      waku.selectMixLightpushPeer(shard).isNone() # no mix key learned yet

    # Later, discovery (kademlia or rendezvous) learns the mix key of the peer.
    let keyPair = generateKeyPair().expect("mix key pair")
    waku.node.peerManager.addPeer(
      RemotePeerInfo.init(peerId, @[address], mixPubKey = Opt.some(keyPair.publicKey))
    )

    let selected = waku.selectMixLightpushPeer(shard).valueOr:
      raiseAssert "the slotted lightpush node should be offered as a mix exit"
    check selected.peerId == peerId

## A stub for `MixEntryConnection` of `libp2p_mix`. `write` completes, `readOnce`
## waits for the reply future, and `closeImpl` cancels the closure that fills it.
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
  # `stallInSend` models the first-hop dial. Mix dials with `switch.dial`, so
  # `DefaultDialTimeout` does not apply.
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
  ## `publishOverMix` bounds a mix-routed lightpush. The mix connection does
  ## not bound the first-hop dial. These tests stall each phase in turn.
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")

  asyncTeardown:
    discard await waku.stop()

  # `publishOverMix` waits `MixReplyTimeout` by default. These tests use a short
  # limit, because the test subject is the mechanism and not the constant.
  const ReplyBudget = chronos.milliseconds(200)

  proc givesUpOn(stallInSend: bool): Future[WakuLightPushResult] {.async.} =
    ## Calls the real `publishOverMix` with a mix connection that does not
    ## answer, and returns the result. The test does not await the call
    ## directly. It uses `race` with a long timer: when `publishOverMix` does
    ## not return, the test fails one check and the suite continues.
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
      raiseAssert "publishOverMix did not return, so the send service loop would stop"
    return await publishFut

  asyncTest "a dropped reply is given up on instead of waited on forever":
    let res = await givesUpOn(stallInSend = false)
    check:
      res.isErr()
      res.error.code == LightPushErrorCode.SERVICE_NOT_AVAILABLE

  asyncTest "a stalled first-hop dial is given up on too":
    ## A stall in the send leaves the reply future pending, and the close of
    ## the connection cancels the closure that completes it.
    let res = await givesUpOn(stallInSend = true)
    check:
      res.isErr()
      res.error.code == LightPushErrorCode.SERVICE_NOT_AVAILABLE

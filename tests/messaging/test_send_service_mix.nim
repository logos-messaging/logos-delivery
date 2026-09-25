{.used.}

import std/sets
import chronos, chronicles, testutils/unittests, results, stew/byteutils

import
  libp2p_mix,
  libp2p_mix/curve25519,
  libp2p/[peerid, multiaddress],
  libp2p/stream/connection,
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_mix,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/api/publish,
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  logos_delivery/waku/node/waku_node/lightpush,
  logos_delivery/waku/waku_lightpush/common,
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service, send_processor, mix_processor, delivery_task]
import ../testlib/[testasync, wakucore, wakunodeconf]

## Tests for the anonymity levels of the send path. The first suite mounts no
## mix, so the level decides at once; the second mounts mix and fills the pool
## by hand.

type PlainSendProcessor = ref object of BaseSendProcessor
  calls: int

method isValidProcessor(self: PlainSendProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: PlainSendProcessor, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  task.state = DeliveryState.SuccessfullyPropagated
  task.firstPropagatedTime = Opt.some(Moment.now())

type RetryingProcessor = ref object of BaseSendProcessor
  ## Leaves every task for the next round, with `reason` in `errorDesc`.
  reason: string

method isValidProcessor(self: RetryingProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: RetryingProcessor, task: DeliveryTask): Future[void] {.async.} =
  task.errorDesc = self.reason
  task.state = DeliveryState.NextRoundRetry

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

proc buildTask(id: string, admittedAgo: Duration): DeliveryTask =
  ## An admitted task, so `admitAndProve` skips admission and, with no RLN, does
  ## not suspend.
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

suite "SendService - anonymity level":
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")

  asyncTeardown:
    discard await waku.stop()

  asyncTest "a Required task fails at once when mix cannot deliver":
    ## `Required` has no second path, so the task fails at once with the reason.
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("required", chronos.seconds(5))
    await mix.process(task)

    check:
      plain.calls == 0 # `Required` never uses the plain path
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == MixUnavailableReason

  asyncTest "a Required task past its window still never reaches the plain path":
    ## With mix unusable, the reasons decide before the window, so a `Required`
    ## task past its window fails with the reason and never reaches the plain path.
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("required-past-window", chronos.minutes(10))
    await mix.process(task)

    check:
      plain.calls == 0
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == MixUnavailableReason

  asyncTest "a Preferred task takes the plain path at once when mix cannot deliver":
    ## No wait can mount mix, so the task goes to the plain path at once. The
    ## mounted suite covers a mounted mix that cannot attempt the send.
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("preferred-early", chronos.seconds(5))
    await mix.process(task)

    check:
      plain.calls == 1
      task.state == DeliveryState.SuccessfullyPropagated

  asyncTest "Preferred gets a second delivery window, the other levels do not":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")

    proc serviceFor(level: AnonymityLevel): SendService =
      let chain = setupSendProcessorChain(waku, level).expect("send processor chain")
      return
        SendService.new(false, waku, manager, chain, level).expect("SendService.new")

    let plainService = serviceFor(AnonymityLevel.None)
    let mixOnlyService = serviceFor(AnonymityLevel.Required)
    let bestEffortService = serviceFor(AnonymityLevel.Preferred)

    check:
      plainService.maxDeliveryTime == MaxTimeInCache
      mixOnlyService.maxDeliveryTime == MaxTimeInCache
      bestEffortService.maxDeliveryTime == MaxTimeInCache + MaxTimeInCache

  asyncTest "a terminal outcome is not emitted before send() yields to its caller":
    ## The messaging API returns the request id when `send` yields, and a
    ## `Required` fail-fast needs no other suspension, so the error must come
    ## after that yield.
    var errors = 0
    let listener = MessageErrorEvent
      .listen(
        waku.brokerCtx,
        proc(e: MessageErrorEvent) {.async: (raises: []).} =
          inc errors
        ,
      )
      .expect("listen")
    defer:
      await MessageErrorEvent.dropListener(waku.brokerCtx, listener)
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let chain = setupSendProcessorChain(waku, AnonymityLevel.Required).expect(
        "send processor chain"
      )
    let service = SendService
      .new(false, waku, manager, chain, AnonymityLevel.Required)
      .expect("SendService.new")

    let fut = service.send(buildTask("failfast", chronos.seconds(1)))
    check errors == 0 # no event before the yield
    await fut
    await sleepAsync(chronos.milliseconds(10))
    check errors == 1 # ... and exactly once after the yield

  asyncTest "a send counts toward the cap before it yields":
    ## The messaging API checks `isFull()` and then spawns `send`, which runs to
    ## its first suspension at once. Counting before the yield makes a burst in
    ## one loop turn fill the cap, so the API rejects the rest itself.
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let chain = setupSendProcessorChain(waku, AnonymityLevel.Required).expect(
        "send processor chain"
      )
    let service = SendService
      .new(false, waku, manager, chain, AnonymityLevel.Required, maxTaskCacheSize = 1)
      .expect("SendService.new")
    check not service.isFull()

    let fut = service.send(buildTask("first-of-burst", chronos.seconds(1)))
    check service.isFull() # counted, and still suspended at the yield
    await fut

suite "SendService - anonymity level with a mounted mix":
  ## Mix is mounted before start, as the node factory does. The tests fill the
  ## pool by hand, with or without the lightpush codec that makes a member an exit.
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")
    let mixKeys = generateKeyPair().expect("mix key pair")
    (await waku.node.mountMix(3'u16, mixKeys.privateKey, @[])).isOkOr:
      raiseAssert "Failed to mount mix: " & $error

  asyncTeardown:
    discard await waku.stop()

  const shard = PubsubTopic("/waku/2/rs/3/0")

  proc addMixPeer(port: int, lightpush: bool) =
    let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
    let keyPair = generateKeyPair().expect("mix key pair")
    waku.node.peerManager.addPeer(
      RemotePeerInfo.init(
        peerId,
        @[MultiAddress.init("/ip4/127.0.0.1/tcp/" & $port).tryGet()],
        protocols = (if lightpush: @[WakuLightPushCodec] else: @[]),
        shards = @[0'u16],
        mixPubKey = Opt.some(keyPair.publicKey),
      )
    )
    waku.node.peerManager.switch.peerStore.setShardInfo(peerId, @[0'u16])

  asyncTest "a Required task tries three times while the pool is short, then fails":
    ## A short pool is a reason mix cannot attempt the task. A `Required` task
    ## waits `MixUnusableRetries` more passes, then fails with that reason.
    for i in 0 ..< MinMixPoolSize - 1:
      addMixPeer(60100 + i, lightpush = true)
    check not waku.mixReady()

    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    let task = buildTask("short-pool", chronos.seconds(5))
    for _ in 0 ..< MixUnusableRetries:
      await mix.process(task)
      check:
        task.state == DeliveryState.NextRoundRetry
        task.errorDesc == MixUnavailableReason # written while it waits
    await mix.process(task)
    check:
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == MixUnavailableReason

    # One more routable member and the pool can build a path.
    addMixPeer(60103, lightpush = true)
    check waku.mixReady()

  asyncTest "a Required task starts its tries over once mix can attempt it":
    ## `heldRounds` counts the passes a task waited; an attempt resets it, so a
    ## later stretch without mix gets its full `MixUnusableRetries` again.
    for i in 0 ..< MinMixPoolSize - 1:
      addMixPeer(60210 + i, lightpush = true)
    check not waku.mixReady()

    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    let task = buildTask("held-then-usable", chronos.seconds(5))
    await mix.process(task)
    check:
      task.state == DeliveryState.NextRoundRetry
      task.heldRounds == 1

    addMixPeer(60210 + MinMixPoolSize - 1, lightpush = true)
    check waku.mixReady()
    let fut = mix.process(task)
    check:
      task.tryCount == 1 # mix attempts it
      task.heldRounds == 0 # ... and the count starts over
    await fut.cancelAndWait()

  asyncTest "a Required task tries three times with no exit on the shard, then fails":
    ## A full pool with no lightpush member on the shard has no exit, as in a
    ## seeded pool before identify and waku-metadata fill its books.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60110 + i, lightpush = false)
    check:
      waku.mixReady()
      waku.selectMixLightpushPeer(shard).isNone()

    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("no-exit", chronos.seconds(5))
    for _ in 0 ..< MixUnusableRetries:
      await mix.process(task)
      check task.state == DeliveryState.NextRoundRetry
    await mix.process(task)
    check:
      plain.calls == 0
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == MixNoExitReason

  asyncTest "a Preferred task that mix cannot attempt takes the plain path at once":
    ## No wait for the window: with no exit on the shard, a fresh `Preferred`
    ## task goes to the plain path in the same round.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60120 + i, lightpush = false)
    check waku.mixReady()

    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )
    mix.chain(plain)

    let fresh = buildTask("no-exit-preferred", chronos.seconds(5))
    await mix.process(fresh)
    check:
      plain.calls == 1
      fresh.state == DeliveryState.SuccessfullyPropagated

  asyncTest "a Preferred hand-over for an unusable mix is visible, once, and so is the recovery":
    ## `fellBackFor()` holds the reason that the INFO lines print. No exit hands
    ## over for `MixUnusable.NoExit`; an exit clears the reason.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60180 + i, lightpush = false)
    check waku.mixReady()

    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )
    mix.chain(plain)
    check mix.fellBackFor() == MixUnusable.None

    let spent = buildTask("no-exit-spent", chronos.minutes(2))
    await mix.process(spent)
    check:
      plain.calls == 1
      spent.state == DeliveryState.SuccessfullyPropagated
      spent.errorDesc.len == 0 # the plain path reports its own outcome
      mix.fellBackFor() == MixUnusable.NoExit

    let again = buildTask("no-exit-spent-again", chronos.minutes(2))
    await mix.process(again)
    check:
      plain.calls == 2
      mix.fellBackFor() == MixUnusable.NoExit # unchanged, so logged once

    addMixPeer(60184, lightpush = true)
    check waku.selectMixLightpushPeer(shard).isSome()
    let back = buildTask("exit-back", chronos.seconds(5))
    let fut = mix.process(back)
    check:
      back.tryCount == 1 # mix attempts it
      mix.fellBackFor() == MixUnusable.None # ... and the recovery was logged
    await fut.cancelAndWait()

  asyncTest "the delivery reaper reports the reason a processor left on the task":
    ## A processor that leaves a task for the next round can write why in
    ## `errorDesc`; the reaper reports it instead of the generic timeout text.
    var errors: seq[MessageErrorEvent]
    let listener = MessageErrorEvent
      .listen(
        waku.brokerCtx,
        proc(e: MessageErrorEvent) {.async: (raises: []).} =
          errors.add(e),
      )
      .expect("listen")
    defer:
      await MessageErrorEvent.dropListener(waku.brokerCtx, listener)

    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService
      .new(false, waku, manager, RetryingProcessor(reason: "scripted reason"))
      .expect("SendService.new")

    # Past its delivery window, so the send's own report reaps it.
    let task = buildTask("reaper", MaxTimeInCache + chronos.seconds(1))
    await service.send(task)
    await sleepAsync(chronos.milliseconds(10))
    check:
      task.state == DeliveryState.FailedToDeliver
      errors.len == 1
      errors[0].requestId == task.requestId
      errors[0].error == "scripted reason"

  asyncTest "a Preferred task falls back to the plain path once the window elapsed":
    ## The window ends the mix phase of a task that mix did not deliver. Only a
    ## usable mix shows this: with an unusable mix the reasons decide first.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60140 + i, lightpush = true)

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
    ## draws a new nonce. The window runs from that field, so the refreshed task
    ## gets a whole window again and mix attempts it.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60145 + i, lightpush = true)

    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("rln-park", chronos.minutes(2))
    task.msg.proof = @[1'u8, 2, 3] # a proof the service would have rejected

    # The park clears the proof and `firstAdmittedTime`, which resets the window.
    task.parkForRlnProofRefresh(waku)
    check task.msg.proof.len == 0

    let fut = mix.process(task)
    check:
      task.tryCount == 1 # a whole window again, so mix attempts it
      plain.calls == 0 # no hand-over
    await fut.cancelAndWait()

  asyncTest "a task parked for budget does not spend its mix window":
    ## The window runs from admission. A task that did not pass admission has
    ## spent none of it, however old its message is, so mix attempts it.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60150 + i, lightpush = true)

    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("late-admission", chronos.minutes(2))
    task.firstAdmittedTime = Opt.none(Moment) # parked for epoch budget

    let fut = mix.process(task)
    check:
      task.tryCount == 1 # the window is intact, so mix attempts it
      plain.calls == 0
    await fut.cancelAndWait()

    # The same processor hands over a task that has spent its window, so the
    # case above cannot pass on a window that never elapses.
    let spent = buildTask("late-admission-spent", chronos.minutes(2))
    await mix.process(spent)
    check:
      plain.calls == 1
      spent.state == DeliveryState.SuccessfullyPropagated

  asyncTest "a Required task tries three times when mix cannot encode its own hop, then fails":
    ## The pool is usable and the self hop is not, so no reply path can be built.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60160 + i, lightpush = true)
    check waku.mixReady()

    discard waku.node.wakuMix.updateSelfHop(
      @[MultiAddress.init("/dns4/node.test/tcp/30303").tryGet()], @[]
    )
    check:
      not waku.node.wakuMix.selfHopUsable()
      not waku.mixReady()

    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("self-hop", chronos.seconds(5))
    for _ in 0 ..< MixUnusableRetries:
      await mix.process(task)
      check task.state == DeliveryState.NextRoundRetry
    await mix.process(task)
    check:
      plain.calls == 0
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == MixSelfHopReason

    # An address the encoder takes, committed later, reopens the gate.
    discard waku.node.wakuMix.updateSelfHop(
      @[MultiAddress.init("/ip4/127.0.0.1/tcp/30303").tryGet()], @[]
    )
    check waku.mixReady()

  asyncTest "a Required task past its window is still attempted over a usable mix":
    ## Tests the `fallbackAllowed` guard on the window branch, which only a usable
    ## mix reaches: a `Required` task past its window must never go out in clear.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60200 + i, lightpush = true)
    check waku.mixReady()

    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("required-spent-usable", chronos.minutes(10))
    let fut = mix.process(task)
    check:
      task.tryCount == 1 # attempted, window or no window
      plain.calls == 0 # never handed over
    await fut.cancelAndWait()
    check plain.calls == 0

  asyncTest "a mix attempt marks the task before it can know whether it worked":
    ## The exit publishes before it replies, so the mark must be set before any
    ## reply. The test cancels the attempt before a reply can arrive.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60170 + i, lightpush = true)

    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    let task = buildTask("announced-at-attempt", chronos.seconds(5))

    let fut = mix.process(task)
    await sleepAsync(chronos.milliseconds(10))
    await fut.cancelAndWait()

    check:
      task.state != DeliveryState.SuccessfullyPropagated # no reply ever came
      task.anonymized # ... and it was marked anyway

  asyncTest "a usable mix is attempted, not decided against":
    ## A routable pool with an exit passes the pre-check. `tryCount` grows before
    ## the first await; the test then cancels the attempt.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60130 + i, lightpush = true)
    check:
      waku.mixReady()
      waku.selectMixLightpushPeer(shard).isSome()

    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    let task = buildTask("usable", chronos.seconds(5))
    let fut = mix.process(task)
    check task.tryCount == 1 # the pre-check let the attempt start
    await fut.cancelAndWait()
    check task.state != DeliveryState.FailedToDeliver

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

  asyncTest "repeated selections spread over every mix-capable exit":
    ## Three usable exits and a hundred draws: every exit must come up. A uniform
    ## draw misses one with probability below 1e-17; a draw that always skips one
    ## candidate never sees three.
    for _ in 0 ..< 3:
      discard addLightpushPeer(mixCapable = true)

    var seen: HashSet[PeerId]
    for _ in 0 ..< 100:
      let selected = waku.selectMixLightpushPeer(shard).valueOr:
        raiseAssert "expected a mix-capable exit to be selected"
      seen.incl(selected.peerId)
    check seen.len == 3

  asyncTest "two mix-capable exits are both selected over repeated draws":
    ## A permutation that always moves the first candidate off the front, as
    ## Sattolo's algorithm in `Rng.shuffle` does, returns the same exit on every
    ## call with two candidates, and fails this.
    for _ in 0 ..< 2:
      discard addLightpushPeer(mixCapable = true)

    var seen: HashSet[PeerId]
    for _ in 0 ..< 50:
      let selected = waku.selectMixLightpushPeer(shard).valueOr:
        raiseAssert "expected a mix-capable exit to be selected"
      seen.incl(selected.peerId)
    check seen.len == 2

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

suite "Mix send path - the node's own hop":
  ## `mixReady()` is false while mix cannot encode this node's own hop: every
  ## reply path and cover packet would fail at build time.
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")

  asyncTeardown:
    # The test mix is not mounted on the switch, so the node must not stop it.
    waku.node.wakuMix = nil
    discard await waku.stop()

  proc addMixPeer(port: int) =
    let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
    let keyPair = generateKeyPair().expect("mix key pair")
    waku.node.peerManager.addPeer(
      RemotePeerInfo.init(
        peerId,
        @[MultiAddress.init("/ip4/127.0.0.1/tcp/" & $port).tryGet()],
        protocols = @[WakuLightPushCodec],
        shards = @[0'u16],
        mixPubKey = Opt.some(keyPair.publicKey),
      )
    )

  asyncTest "a hop mix cannot encode keeps the send gate closed whatever the pool holds":
    ## `WakuMix.new` takes the address as a string, as `mountMix` passes it, so
    ## the test gives it a name. Nothing dials; the test reads only the gate.
    let mixKeys = generateKeyPair().expect("mix key pair")
    waku.node.wakuMix = WakuMix
      .new(
        "/dns4/node.test/tcp/30303",
        waku.node.peerManager,
        3'u16,
        mixKeys.privateKey,
        @[],
      )
      .expect("WakuMix.new")
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60300 + i)
    check:
      waku.node.getMixNodePoolSize() >= MinMixPoolSize
      not waku.node.wakuMix.selfHopUsable()
      not waku.mixReady()

    # The same node with a hop the encoder accepts: the gate opens.
    waku.node.wakuMix
      .setLocalMultiAddr(MultiAddress.init("/ip4/127.0.0.1/tcp/30303").tryGet())
      .expect("an IPv4 TCP hop is accepted")
    check:
      waku.node.wakuMix.selfHopUsable()
      waku.mixReady()

{.used.}

import std/[sequtils, sets, strutils]
import chronos, testutils/unittests, results, stew/byteutils

import
  libp2p_mix,
  libp2p_mix/curve25519,
  mix_rln_spam_protection/module_api,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/net/bound_ports,
  logos_delivery/waku/node/waku_node/mix_rln,
  libp2p/[peerid, multiaddress],
  libp2p/stream/connection,
  libp2p/[varint, vbuffer],
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_mix,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/api/publish,
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  logos_delivery/waku/node/waku_node/lightpush,
  logos_delivery/waku/rln/rln_plugin,
  logos_delivery/waku/rln/types as rln_types,
  logos_delivery/waku/waku_lightpush/[common, rpc, rpc_codec],
  logos_delivery/waku/waku_lightpush/client as lightpush_client,
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/messaging/messaging_client,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service {.all.}, send_processor, mix_processor, delivery_task]
import ../testlib/[futures, testasync, wakucore, wakunodeconf]

## Tests for the anonymity levels of the send path. The first suite mounts no
## mix, so the level decides at once; the second mounts mix and fills the pool
## by hand.

type PlainSendProcessor = ref object of BaseSendProcessor
  calls: int
  hashes: seq[WakuMessageHash] ## The hash of the message of each attempt.

method attempt(
    self: PlainSendProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  inc self.calls
  self.hashes.add(computeMessageHash(task.pubsubTopic, task.msg))
  return StepReport.init(Trigger.Published)

type ScriptedResultProcessor = ref object of BaseSendProcessor
  ## Returns `trigger` and `desc` from each attempt.
  trigger: Trigger
  desc: string

method attempt(
    self: ScriptedResultProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  return StepReport.init(self.trigger, self.desc)

proc serviceAt(
    waku: Waku,
    level: AnonymityLevel,
    mix: MixSendProcessor,
    plain: BaseSendProcessor = nil,
    manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new"),
): SendService =
  ## A service of `level` with `plain` as its lightpush processor.
  ## A round needs no tick, so the retry loop ticks once an hour.
  return SendService
    .new(
      false,
      waku,
      manager,
      SendProcessors(mix: mix, lightpush: plain),
      level,
      retryInterval = chronos.hours(1),
    )
    .expect("SendService.new")

proc runRound(
    service: SendService, task: DeliveryTask
): Future[DeliveryState] {.async.} =
  ## Runs one round of `task`, up to a wait or a final state.
  var state = service.start(task)
  while state in RoundStates:
    state = await service.step(task, state)
  return state

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

proc buildTask(
    id: string, admittedAgo: Duration, contentTopic = "/test/1/anonymity/proto"
): DeliveryTask =
  ## An admitted task with no RLN, so its round does not start in `Admission`.
  ## The id is the payload, so two tasks never have one hash.
  let msg = WakuMessage(
    contentTopic: contentTopic,
    payload: id.toBytes(),
    timestamp: 1_700_000_000_000_000_000,
  )
  let pubsubTopic = PubsubTopic("/waku/2/rs/3/0")
  return DeliveryTask(
    pubsubTopic: pubsubTopic,
    msg: msg,
    msgHash: computeMessageHash(pubsubTopic, msg),
    firstAdmittedTime: Opt.some(Moment.now() - admittedAgo),
  )

proc sizedTask(id: string, size: int): DeliveryTask =
  ## An admitted task whose lightpush request over mix has `size` bytes.
  let task = buildTask(id, chronos.seconds(5))
  for n in 0 .. size:
    task.msg.payload = newSeq[byte](n)
    if mixLightpushSize(task.pubsubTopic, task.msg).size == size:
      task.msgHash = computeMessageHash(task.pubsubTopic, task.msg)
      return task
  raiseAssert "no payload gives a request of " & $size & " bytes"

proc mixLimit(): int =
  let task = buildTask("probe", chronos.seconds(5))
  return mixLightpushSize(task.pubsubTopic, task.msg).limit

proc sizedProofTask(id: string, size, proofBytes: int): DeliveryTask =
  let task = buildTask(id, ZeroDuration)
  task.firstAdmittedTime = Opt.none(Moment)
  task.msg.timestamp = getNowInNanosecondTime()
  task.msg.proof = newSeq[byte](proofBytes)
  for n in 0 .. size:
    task.msg.payload = newSeq[byte](n)
    if mixLightpushSize(task.pubsubTopic, task.msg).size == size:
      task.msg.proof = @[]
      task.msgHash = computeMessageHash(task.pubsubTopic, task.msg)
      return task
  raiseAssert "no payload gives a request of " & $size & " bytes"

proc countingRln(waku: Waku, proofBytes: int): ref int =
  let draws = new int
  proc generate(
      message: WakuMessage
  ): Future[Result[seq[byte], rln_types.RlnError]] {.async.} =
    draws[].inc()
    return ok(newSeq[byte](proofBytes))

  waku.node.rlnPlugin =
    Opt.some(RlnPlugin(generateProof: generate, proofSize: Opt.some(proofBytes)))
  return draws

suite "SendService - mix size before admission":
  var waku {.threadvar.}: Waku
  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")
    let keys = generateKeyPair().expect("mix key pair")
    (await waku.node.mountMix(3'u16, keys.privateKey, @[])).expect("mountMix")
  asyncTeardown:
    discard await waku.stop()

  proc newManager(): RateLimitManager =
    RateLimitManager
      .new(RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1))
      .expect("RateLimitManager.new")

  asyncTest "proof overhead rejects Required before admission and leaves budget for a fitting task":
    const proofBytes = 289
    let draws = countingRln(waku, proofBytes)
    let manager = newManager()
    let mix = MixSendProcessor.new(waku, waku.brokerCtx)
    let service = serviceAt(waku, AnonymityLevel.Required, mix, manager = manager)
    service.startSendService()
    defer:
      await service.stopSendService()
    var errors: seq[MessageErrorEvent]
    let listener = MessageErrorEvent
      .listen(
        waku.brokerCtx,
        proc(event: MessageErrorEvent) {.async: (raises: []).} =
          errors.add(event),
      )
      .expect("listen")
    defer:
      await MessageErrorEvent.dropListener(waku.brokerCtx, listener)

    let large = sizedProofTask("unproven-fits", mixLimit(), 0)
    check service.enqueue(large).isOk()
    checkUntilTimeout:
      errors.len == 1
    check:
      large.state == DeliveryState.NotPropagated
      large.lastFailure == Opt.some(Trigger.TooLargeForMix)
      large.errorText().startsWith(MixTooLargeReason)
      large.firstAdmittedTime.isNone()
      large.msg.proof.len == 0
      large.tryCount == 0
      not large.anonymized
      draws[] == 0
      manager.sentInCurrentEpoch == 0
      not large.queuedEventEmitted

    let fits = sizedProofTask("proven-fits", mixLimit(), proofBytes)
    check service.enqueue(fits).isOk()
    checkUntilTimeout:
      fits.state == DeliveryState.NextRoundRetry
    check:
      draws[] == 1
      manager.sentInCurrentEpoch == 1
      fits.firstAdmittedTime.isSome()
      fits.msg.proof.len == proofBytes
      mixLightpushSize(fits.pubsubTopic, fits.msg).size == mixLimit()
      fits.lastFailure == Opt.some(Trigger.MixUnavailable)
      errors.len == 1

  asyncTest "Required rejects one byte above the proven limit without spending budget":
    let draws = countingRln(waku, 289)
    let manager = newManager()
    let mix = MixSendProcessor.new(waku, waku.brokerCtx)
    let service = serviceAt(waku, AnonymityLevel.Required, mix, manager = manager)
    service.startSendService()
    defer:
      await service.stopSendService()
    let task = sizedProofTask("proven-too-large", mixLimit() + 1, 289)
    check service.enqueue(task).isOk()
    checkUntilTimeout:
      task.state == DeliveryState.NotPropagated
    check:
      task.errorText().contains("the request has " & $(mixLimit() + 1) & " bytes")
      draws[] == 0
      manager.sentInCurrentEpoch == 0
      task.firstAdmittedTime.isNone()

  asyncTest "Preferred spends one proof and one admission for its plain fallback":
    let draws = countingRln(waku, 289)
    let manager = newManager()
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(waku, waku.brokerCtx)
    let service =
      serviceAt(waku, AnonymityLevel.Preferred, mix, plain, manager = manager)
    service.startSendService()
    defer:
      await service.stopSendService()
    let task = sizedProofTask("plain-fallback", mixLimit() + 1, 289)
    check service.enqueue(task).isOk()
    checkUntilTimeout:
      task.state == DeliveryState.Propagated
    check:
      plain.calls == 1
      draws[] == 1
      manager.sentInCurrentEpoch == 1
      task.msg.proof.len == 289
      not task.anonymized
      task.tryCount == 1 # the plain attempt, and none over mix

  asyncTest "a supplied proof uses its actual length before admission":
    let draws = countingRln(waku, 400)
    let task = sizedProofTask("supplied-proof", mixLimit(), 289)
    task.msg.proof = newSeq[byte](289)
    let mix = MixSendProcessor.new(waku, waku.brokerCtx)
    check mix.checkBeforeAdmission(task).isOk()
    check:
      draws[] == 0
      task.msg.proof.len == 289
      mixLightpushSize(task.pubsubTopic, task.msg).size == mixLimit()
    task.msg.proof.add(1)
    check mix.checkBeforeAdmission(task).error.trigger == Trigger.TooLargeForMix
    check draws[] == 0

  asyncTest "an undeclared proof size fails Required before drawing a proof":
    let draws = countingRln(waku, 289)
    var plugin = waku.node.rlnPlugin.get()
    plugin.proofSize = Opt.none(int)
    waku.node.rlnPlugin = Opt.some(plugin)
    let manager = newManager()
    let mix = MixSendProcessor.new(waku, waku.brokerCtx)
    let service = serviceAt(waku, AnonymityLevel.Required, mix, manager = manager)
    service.startSendService()
    defer:
      await service.stopSendService()
    let task = sizedProofTask("unknown-proof", mixLimit(), 0)
    check service.enqueue(task).isOk()
    checkUntilTimeout:
      task.state == DeliveryState.NotPropagated
    check:
      task.lastFailure == Opt.some(Trigger.ProofSizeUnknown)
      task.errorText().contains("does not declare its proof size")
      draws[] == 0
      manager.sentInCurrentEpoch == 0

  asyncTest "direct mix Lightpush rejects proof overhead without drawing a proof":
    let draws = countingRln(waku, 289)
    let task = sizedProofTask("direct-unproven-fits", mixLimit(), 0)
    let publishResult = await waku.node.lightpushPublish(
      Opt.some(task.pubsubTopic),
      task.msg,
      Opt.some(RemotePeerInfo.init(waku.node.peerId())),
      mixify = true,
    )
    check:
      publishResult.isErr()
      publishResult.error.code == LightPushErrorCode.INVALID_MESSAGE
      publishResult.error.desc.get("").startsWith(MixTooLargeReason)
      draws[] == 0
      task.msg.proof.len == 0

  asyncTest "direct mix Lightpush fails an undeclared proof size as a node error":
    let draws = countingRln(waku, 289)
    var plugin = waku.node.rlnPlugin.get()
    plugin.proofSize = Opt.none(int)
    waku.node.rlnPlugin = Opt.some(plugin)
    let task = sizedProofTask("direct-unknown-proof", mixLimit(), 0)
    let publishResult = await waku.node.lightpushPublish(
      Opt.some(task.pubsubTopic),
      task.msg,
      Opt.some(RemotePeerInfo.init(waku.node.peerId())),
      mixify = true,
    )
    check:
      publishResult.isErr()
      publishResult.error.code == LightPushErrorCode.INTERNAL_SERVER_ERROR
      publishResult.error.desc.get("").contains("does not declare its proof size")
      draws[] == 0
      task.msg.proof.len == 0

suite "SendService - anonymity level":
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")

  asyncTeardown:
    discard await waku.stop()

  asyncTest "a Required task fails at once when mix cannot deliver":
    ## `Required` has no second path, so the task fails at once with the reason.
    let plain = PlainSendProcessor()
    let service = serviceAt(
      waku, AnonymityLevel.Required, MixSendProcessor.new(waku, waku.brokerCtx), plain
    )

    let task = buildTask("required", chronos.seconds(5))
    check (await service.runRound(task)) == DeliveryState.NotPropagated

    check:
      plain.calls == 0 # `Required` never uses the plain path
      task.lastFailure == Opt.some(Trigger.MixNotMounted)
      task.errorText() == MixUnavailableReason

  asyncTest "a Required task past its window still never reaches the plain path":
    ## With mix unusable, the reasons decide before the window, so a `Required`
    ## task past its window fails with the reason and never reaches the plain path.
    let plain = PlainSendProcessor()
    let service = serviceAt(
      waku, AnonymityLevel.Required, MixSendProcessor.new(waku, waku.brokerCtx), plain
    )

    let task = buildTask("required-past-window", chronos.minutes(10))
    check (await service.runRound(task)) == DeliveryState.NotPropagated

    check:
      plain.calls == 0
      task.errorText() == MixUnavailableReason

  asyncTest "a Preferred task takes the plain path at once when mix cannot deliver":
    ## No wait can mount mix, so the task goes to the plain path at once. The
    ## mounted suite covers a mounted mix that cannot attempt the send.
    let plain = PlainSendProcessor()
    let service = serviceAt(
      waku, AnonymityLevel.Preferred, MixSendProcessor.new(waku, waku.brokerCtx), plain
    )

    let task = buildTask("preferred-early", chronos.seconds(5))
    check (await service.runRound(task)) == DeliveryState.Propagated
    check plain.calls == 1

  asyncTest "Preferred gets a second delivery window, the other levels do not":
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")

    proc serviceFor(level: AnonymityLevel): SendService =
      let processors = setupSendProcessors(waku, level).expect("send processors")
      return SendService.new(false, waku, manager, processors, level).expect(
          "SendService.new"
        )

    let plainService = serviceFor(AnonymityLevel.None)
    let mixOnlyService = serviceFor(AnonymityLevel.Required)
    let bestEffortService = serviceFor(AnonymityLevel.Preferred)

    check:
      plainService.maxDeliveryTime == DeliveryWindow
      mixOnlyService.maxDeliveryTime == DeliveryWindow
      bestEffortService.maxDeliveryTime == DeliveryWindow + DeliveryWindow

  asyncTest "a node that sends over mix withholds the hash of a task from its first record":
    ## The task made no mix attempt yet, so it does not have its mark.
    let task = buildTask("first-record", ZeroDuration)
    let plain = SendService
      .new(
        false,
        waku,
        RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new"),
        SendProcessors(lightpush: ScriptedResultProcessor(trigger: Trigger.Published)),
      )
      .expect("SendService.new")
    let mixFirst = serviceAt(
      waku,
      AnonymityLevel.Preferred,
      MixSendProcessor.new(waku, waku.brokerCtx),
      ScriptedResultProcessor(trigger: Trigger.Published),
    )
    check:
      not task.anonymized
      plain.loggedHash(task) == task.msgHash.to0xHex()
      mixFirst.loggedHash(task) == "withheld"

  asyncTest "a messaging client with no lightpush client keeps its startup error text":
    let lightpushClient = waku.node.wakuLightpushClient
    waku.node.wakuLightpushClient = nil
    defer:
      waku.node.wakuLightpushClient = lightpushClient
    let client = MessagingClient.new(
      MessagingClientConf(anonymityLevel: Opt.some(AnonymityLevel.Required)), waku
    )
    check:
      client.isErr()
      client.error ==
        "failed to setup SendProcessorChain: " &
        "Mix sending needs a lightpush client, which is not mounted"

  asyncTest "enqueue emits no event, and the service emits the outcome later":
    ## A `Required` task that mix cannot attempt fails with no network call.
    ## `enqueue` makes no attempt, so the error comes once, later.
    let errors = EventCounter()
    let listener = MessageErrorEvent
      .listen(
        waku.brokerCtx,
        proc(e: MessageErrorEvent) {.async: (raises: []).} =
          errors.inc(),
      )
      .expect("listen")
    defer:
      await MessageErrorEvent.dropListener(waku.brokerCtx, listener)
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let processors =
      setupSendProcessors(waku, AnonymityLevel.Required).expect("send processors")
    let service = SendService
      .new(false, waku, manager, processors, AnonymityLevel.Required)
      .expect("SendService.new")

    service.startSendService()
    defer:
      await service.stopSendService()
    let task = buildTask("failfast", chronos.seconds(1))
    check:
      service.enqueue(task).isOk()
      errors.value == 0 # no event inside `enqueue`
    check await errors.waitCount(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check not await errors.waitCount(2).withTimeout(FUTURE_TIMEOUT_SHORT)
    check:
      task.state == DeliveryState.NotPropagated
      errors.value == 1 # ... and exactly one later

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

  proc newService(level: AnonymityLevel, plain: BaseSendProcessor = nil): SendService =
    return serviceAt(waku, level, MixSendProcessor.new(waku, waku.brokerCtx), plain)

  asyncTest "a Required task waits for a short pool during its grace, then fails":
    ## A short pool is a reason mix cannot attempt the task. A `Required` task
    ## waits while its admission is within `MixUnusableGrace`, then fails with
    ## that reason.
    for i in 0 ..< MinMixPoolSize - 1:
      addMixPeer(60100 + i, lightpush = true)
    check not waku.mixReady()

    let service = newService(AnonymityLevel.Required)
    let task = buildTask("short-pool", ZeroDuration)
    check:
      (await service.runRound(task)) == DeliveryState.NextRoundRetry
      task.lastFailure == Opt.some(Trigger.MixUnavailable) # written while it waits
    task.firstAdmittedTime =
      Opt.some(Moment.now() - MixUnusableGrace - chronos.seconds(1))
    check:
      (await service.runRound(task)) == DeliveryState.NotPropagated
      task.errorText() == MixUnavailableReason

    # One more routable member and the pool can build a path.
    addMixPeer(60103, lightpush = true)
    check waku.mixReady()

  asyncTest "a Required task past its grace is attempted once mix can attempt it":
    ## The grace bounds only the wait for a mix that cannot attempt the task.
    for i in 0 ..< MinMixPoolSize - 1:
      addMixPeer(60210 + i, lightpush = true)
    check not waku.mixReady()

    let service = newService(AnonymityLevel.Required)
    let task = buildTask("held-then-usable", ZeroDuration)
    check (await service.runRound(task)) == DeliveryState.NextRoundRetry

    addMixPeer(60210 + MinMixPoolSize - 1, lightpush = true)
    check waku.mixReady()
    task.firstAdmittedTime =
      Opt.some(Moment.now() - MixUnusableGrace - chronos.seconds(1))
    let fut = service.runRound(task)
    check task.tryCount == 1 # mix attempts it
    await fut.cancelAndWait()

  asyncTest "a Required task too large for mix fails at once, also with a short pool":
    ## No pass can make the message fit, so the task does not wait for the pool.
    for i in 0 ..< MinMixPoolSize - 1:
      addMixPeer(60400 + i, lightpush = true)
    check not waku.mixReady()
    let plain = PlainSendProcessor()
    let service = newService(AnonymityLevel.Required, plain)
    let limit = mixLimit()

    # A message at the limit fits, so the short pool holds it within the grace.
    let fits = sizedTask("at-the-limit-short-pool", limit)
    fits.firstAdmittedTime = Opt.some(Moment.now())
    let fitsRound = service.runRound(fits)
    check:
      await fitsRound.withTimeout(FUTURE_TIMEOUT)
      fitsRound.read() == DeliveryState.NextRoundRetry
      fits.lastFailure == Opt.some(Trigger.MixUnavailable)

    let early = sizedTask("too-large-short-pool", limit + 1)
    let earlyRound = service.runRound(early)
    check:
      await earlyRound.withTimeout(FUTURE_TIMEOUT)
      earlyRound.read() == DeliveryState.NotPropagated
      early.errorText() ==
        MixTooLargeReason & ": the request has " & $(limit + 1) & " bytes, the limit is " &
        $limit & " bytes"

    addMixPeer(60400 + MinMixPoolSize - 1, lightpush = true)
    check waku.mixReady()
    let task = sizedTask("too-large", limit + 1)
    let taskRound = service.runRound(task)
    check:
      await taskRound.withTimeout(FUTURE_TIMEOUT)
      taskRound.read() == DeliveryState.NotPropagated
      task.errorText().startsWith(MixTooLargeReason)
      task.tryCount == 0 # no mix attempt
      not task.anonymized
      plain.calls == 0

  asyncTest "a Preferred task too large for mix takes the plain path at once":
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60410 + i, lightpush = true)
    check waku.mixReady()
    let plain = PlainSendProcessor()
    let service = newService(AnonymityLevel.Preferred, plain)

    let task = sizedTask("too-large-preferred", mixLimit() + 1)
    let taskRound = service.runRound(task)
    check:
      await taskRound.withTimeout(FUTURE_TIMEOUT)
      taskRound.read() == DeliveryState.Propagated
      plain.calls == 1
      task.tryCount == 1 # the plain attempt, and none over mix
      not task.anonymized
      not task.propagatedAnonymously
      service.mixFallback.isNone() # a size hand-over records no mix outage

  asyncTest "a Required task waits with no exit on the shard during its grace, then fails":
    ## A full pool with no lightpush member on the shard has no exit, as in a
    ## seeded pool before identify and waku-metadata fill its books.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60110 + i, lightpush = false)
    check:
      waku.mixReady()
      waku.selectMixLightpushPeer(shard).isNone()

    let plain = PlainSendProcessor()
    let service = newService(AnonymityLevel.Required, plain)

    let task = buildTask("no-exit", ZeroDuration)
    check (await service.runRound(task)) == DeliveryState.NextRoundRetry
    task.firstAdmittedTime =
      Opt.some(Moment.now() - MixUnusableGrace - chronos.seconds(1))
    check:
      (await service.runRound(task)) == DeliveryState.NotPropagated
      plain.calls == 0
      task.errorText() == MixNoExitReason

  asyncTest "a Preferred task that mix cannot attempt takes the plain path at once":
    ## No wait for the window: with no exit on the shard, a fresh `Preferred`
    ## task goes to the plain path in the same round.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60120 + i, lightpush = false)
    check waku.mixReady()

    let plain = PlainSendProcessor()
    let service = newService(AnonymityLevel.Preferred, plain)

    let fresh = buildTask("no-exit-preferred", chronos.seconds(5))
    check:
      (await service.runRound(fresh)) == DeliveryState.Propagated
      plain.calls == 1

  asyncTest "a Preferred hand-over for an unusable mix is visible, once, and so is the recovery":
    ## `mixFallback` holds the trigger that the INFO lines print.
    ## No exit hands over for `MixNoExit`, and an exit clears the trigger.
    ## The mix check comes before the mix window, so `MixNoExit` makes the hand-over.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60180 + i, lightpush = false)
    check waku.mixReady()

    let plain = PlainSendProcessor()
    let service = newService(AnonymityLevel.Preferred, plain)
    check service.mixFallback.isNone()

    let spent = buildTask("no-exit-spent", chronos.seconds(90))
    check:
      (await service.runRound(spent)) == DeliveryState.Propagated
      plain.calls == 1
      service.mixFallback == Opt.some(Trigger.MixNoExit)

    let again = buildTask("no-exit-spent-again", chronos.seconds(90))
    check:
      (await service.runRound(again)) == DeliveryState.Propagated
      plain.calls == 2
      service.mixFallback == Opt.some(Trigger.MixNoExit) # unchanged, so logged once

    addMixPeer(60184, lightpush = true)
    check waku.selectMixLightpushPeer(shard).isSome()
    let back = buildTask("exit-back", chronos.seconds(5))
    let fut = service.runRound(back)
    check:
      back.tryCount == 1 # mix attempts it
      service.mixFallback.isNone() # ... and the recovery was logged
    await fut.cancelAndWait()

  asyncTest "an expired task fails with the window text and keeps its last error":
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
      .new(
        false,
        waku,
        manager,
        SendProcessors(lightpush: ScriptedResultProcessor(trigger: Trigger.ServiceBusy)),
        retryInterval = chronos.milliseconds(10),
      )
      .expect("SendService.new")
    let task = buildTask("reaper", ZeroDuration)
    check service.enqueue(task).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeout:
      task.tryCount > 1
    check errors.len == 0
    # The delivery window of the task ends.
    task.firstAdmittedTime =
      Opt.some(Moment.now() - service.maxDeliveryTime - 1.seconds)
    checkUntilTimeout:
      errors.len == 1
    check:
      task.state == DeliveryState.NotPropagated
      task.lastReport.get().trigger == Trigger.WindowElapsed
      task.lastFailure == Opt.some(Trigger.ServiceBusy)
      task.tryCount > 1
      errors.mapIt(it.messageHash) == @[task.msgHash.to0xHex()]
      errors.mapIt(it.error) == @["Unable to send within retry time window"]

  asyncTest "a Preferred task falls back to the plain path once the window elapsed":
    ## The mix window ends the mix phase of a task that mix did not deliver. Only a
    ## usable mix shows this: with an unusable mix the reasons decide first.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60140 + i, lightpush = true)

    let plain = PlainSendProcessor()
    let service = newService(AnonymityLevel.Preferred, plain)

    # Mix had the task since admission and did not deliver it.
    let task = buildTask("preferred-late", chronos.seconds(90))
    let accepted = task.msgHash
    check:
      (await service.runRound(task)) == DeliveryState.Propagated
      plain.calls == 1
      task.tryCount == 1 # the plain attempt, and none over mix
      plain.hashes == @[accepted] # the hand-over sends the same message

  asyncTest "an RLN proof refresh starts a new Preferred mix window":
    ## The refresh clears `firstAdmittedTime`, so the new proof
    ## draws a new nonce. The window runs from that field, so the refreshed task
    ## gets a whole window again and mix attempts it.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60145 + i, lightpush = true)

    let plain = PlainSendProcessor()
    let service = newService(AnonymityLevel.Preferred, plain)

    # A backend with a refresh hook, so the task waits for the refresh.
    waku.node.rlnPlugin = Opt.some(
      RlnPlugin(
        onProofRejected: proc() {.gcsafe, raises: [].} =
          discard
      )
    )

    let task = buildTask("rln-park", chronos.seconds(90))
    task.msg.proof = @[1'u8, 2, 3] # a proof the service would have rejected

    # The refresh clears the proof and `firstAdmittedTime`, which resets the window.
    check:
      task.refreshRlnProof(waku)
      task.msg.proof.len == 0
      task.firstAdmittedTime.isNone()

    let fut = service.step(task, DeliveryState.Mix)
    check:
      task.tryCount == 1 # a whole window again, so mix attempts it
      plain.calls == 0 # no hand-over
    await fut.cancelAndWait()

  asyncTest "an RLN rejection fails the task when no backend can refresh":
    ## No RLN backend is mounted, so no refresh follows and a retry would be
    ## rejected the same way. The task fails with the rejection instead of
    ## waiting for a retry.
    let rejecting = ScriptedResultProcessor(
      trigger: Trigger.ProofRejected, desc: "rln proof rejected"
    )
    let service = serviceAt(waku, AnonymityLevel.None, nil, rejecting)
    let task = buildTask("rln-no-refresh", chronos.seconds(5))
    task.msg.proof = @[1'u8, 2, 3] # a proof the service would have rejected
    check:
      not task.refreshRlnProof(waku)
      (await service.runRound(task)) == DeliveryState.NotPropagated
      task.msg.proof.len == 3
      task.errorText() == "rln proof rejected"

  asyncTest "an RLN rejection waits for a new proof when the backend can refresh":
    waku.node.rlnPlugin = Opt.some(
      RlnPlugin(
        onProofRejected: proc() {.gcsafe, raises: [].} =
          discard
      )
    )
    let rejecting = ScriptedResultProcessor(
      trigger: Trigger.ProofRejected, desc: "rln proof rejected"
    )
    let service = serviceAt(waku, AnonymityLevel.None, nil, rejecting)
    let task = buildTask("rln-refresh", chronos.seconds(5))
    task.msg.proof = @[1'u8, 2, 3] # a proof the service would have rejected
    check:
      (await service.runRound(task)) == DeliveryState.NextRoundRetry
      task.msg.proof.len == 0
      task.firstAdmittedTime.isNone()

  asyncTest "a rejection with an empty text gives an empty error text":
    let rejecting = ScriptedResultProcessor(trigger: Trigger.Rejected, desc: "")
    let service = serviceAt(waku, AnonymityLevel.None, nil, rejecting)
    let task = buildTask("empty-refusal", chronos.seconds(5))
    check:
      (await service.runRound(task)) == DeliveryState.NotPropagated
      task.errorText() == ""

  asyncTest "a task parked for budget does not spend its mix window":
    ## The window runs from admission. A task that did not pass admission has
    ## spent none of it, however old its message is, so mix attempts it.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60150 + i, lightpush = true)

    let plain = PlainSendProcessor()
    let service = newService(AnonymityLevel.Preferred, plain)

    let task = buildTask("late-admission", chronos.seconds(90))
    task.firstAdmittedTime = Opt.none(Moment) # parked for epoch budget

    let fut = service.step(task, DeliveryState.Mix)
    check:
      task.tryCount == 1 # the window is intact, so mix attempts it
      plain.calls == 0
    await fut.cancelAndWait()

    # The same service hands over a task that has spent its window, so the
    # case above cannot pass on a window that never elapses.
    let spent = buildTask("late-admission-spent", chronos.seconds(90))
    check:
      (await service.runRound(spent)) == DeliveryState.Propagated
      plain.calls == 1

  asyncTest "a Required task waits during its grace when mix cannot encode its own hop, then fails":
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
    let service = newService(AnonymityLevel.Required, plain)

    let task = buildTask("self-hop", ZeroDuration)
    check (await service.runRound(task)) == DeliveryState.NextRoundRetry
    task.firstAdmittedTime =
      Opt.some(Moment.now() - MixUnusableGrace - chronos.seconds(1))
    check:
      (await service.runRound(task)) == DeliveryState.NotPropagated
      plain.calls == 0
      task.errorText() == MixSelfHopReason

    # An address the encoder takes, committed later, reopens the gate.
    discard waku.node.wakuMix.updateSelfHop(
      @[MultiAddress.init("/ip4/127.0.0.1/tcp/30303").tryGet()], @[]
    )
    check waku.mixReady()

  asyncTest "a Required task past its window is not attempted and never reaches the plain path":
    ## A `Required` task past its window ends with no attempt, over mix or in clear.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60200 + i, lightpush = true)
    check waku.mixReady()

    let plain = PlainSendProcessor()
    let service = newService(AnonymityLevel.Required, plain)

    let task = buildTask("required-spent-usable", chronos.minutes(10))
    check:
      (await service.runRound(task)) == DeliveryState.NotPropagated
      task.lastReport.get().trigger == Trigger.WindowElapsed
      task.tryCount == 0
      plain.calls == 0

  asyncTest "a mix attempt marks the task before it can know whether it worked":
    ## The exit publishes before it replies, so the mark must be set before any
    ## reply. The test cancels the attempt before a reply can arrive.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60170 + i, lightpush = true)

    let service = newService(AnonymityLevel.Required)
    let task = buildTask("announced-at-attempt", chronos.seconds(5))

    let fut = service.runRound(task)
    await sleepAsync(chronos.milliseconds(10))
    await fut.cancelAndWait()

    check:
      task.firstPropagatedTime.isNone() # no reply ever came
      task.anonymized # ... and it was marked anyway

  asyncTest "a usable mix is attempted, not decided against":
    ## A routable pool with an exit passes the pre-check. `tryCount` grows before
    ## the first await; the test then cancels the attempt.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60130 + i, lightpush = true)
    check:
      waku.mixReady()
      waku.selectMixLightpushPeer(shard).isSome()

    let service = newService(AnonymityLevel.Required)
    let task = buildTask("usable", chronos.seconds(5))
    let fut = service.runRound(task)
    check task.tryCount == 1 # the pre-check let the attempt start
    await fut.cancelAndWait()
    check task.state == DeliveryState.Mix

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
  writes: seq[int] ## the bytes of each `write`
  written: seq[byte] ## the bytes of the last `write`
  cancelledIo: bool ## A pending `readOnce` or `write` ended with a cancel.
  keepsOpen: bool ## The peer sends its reply and no EOF.

method readOnce(
    s: StubMixConn, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  if s.isEof:
    raise newLPStreamEOFError()
  if s.cached.len == 0:
    if s.keepsOpen and s.replyReceivedFut.finished():
      await Future[void].Raising([CancelledError]).init("no eof")
    try:
      await s.replyReceivedFut
      if s.cached.len == 0:
        s.isEof = true
        raise newLPStreamEOFError()
    except CancelledError as exc:
      s.cancelledIo = true
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
  s.writes.add(msg.len)
  s.written = msg
  if s.stallInSend:
    try:
      await s.sendStall
    except CancelledError as exc:
      s.cancelledIo = true
      raise exc

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
      raiseAssert "publishOverMix did not return, so its send would never end"
    return await publishFut

  asyncTest "the mix size check counts the bytes that the lightpush client writes":
    let conn = newStubMixConn()
    let msg = fakeWakuMessage(
      contentTopic = "/test/1/anonymity/proto", proof = newSeq[byte](300)
    )
    let shard = PubsubTopic("/waku/2/rs/3/0")

    check await waku.node
      .publishOverMix(Connection(conn), shard, msg, ReplyBudget)
      .withTimeout(FUTURE_TIMEOUT)

    let (size, limit) = mixLightpushSize(shard, msg)
    check:
      conn.writes == @[size] # one write, so one mix message
      limit == getMaxMessageSizeForCodec(WakuLightPushCodec, MixLightpushSurbs).get()

  asyncTest "a dropped reply is given up on instead of waited on forever":
    let res = await givesUpOn(stallInSend = false)
    check:
      res.isErr()
      res.error.code == LightPushErrorCode.SERVICE_NOT_AVAILABLE
      lightpushReport(res.error).trigger == Trigger.ServiceUnavailable

  proc cancelsPublishOverMix(stallInSend: bool) {.async.} =
    ## A cancel of `publishOverMix` cancels the publish, which waits in `write` or in `readOnce`.
    ## The client then closes the mix connection.
    let conn = newStubMixConn(stallInSend)
    let msg = fakeWakuMessage(contentTopic = "/test/1/anonymity/proto")
    let publishFut = waku.node.publishOverMix(
      Connection(conn), PubsubTopic("/waku/2/rs/3/0"), msg, chronos.seconds(30)
    )
    await sleepAsync(chronos.milliseconds(50))
    check:
      conn.writes.len == 1
      not publishFut.finished()
    await publishFut.cancelAndWait()
    check conn.cancelledIo
    checkUntilTimeout:
      conn.closed()

  proc answer(conn: StubMixConn, statusCode: LightPushStatusCode) =
    ## Gives the request that the client wrote on `conn` its reply.
    # The request is the written bytes after their length prefix.
    var length: uint64
    var prefix: int
    check LP.getUVarint(conn.written, prefix, length).isOk()
    let request = LightpushRequest.decode(conn.written[prefix ..^ 1]).expect("request")
    var reply = initVBuffer()
    reply.writeSeq(
      LightPushResponse(
        requestId: request.requestId,
        statusCode: statusCode,
        relayPeerCount: Opt.some(1'u32),
      ).encode()
    )
    reply.finish()
    conn.incoming.addLastNoWait(reply.buffer)

  proc keepsReply(statusCode: LightPushStatusCode) {.async.} =
    ## The cancel comes some turns after the reply, while the client still unwinds.
    ## Each case in which the client read the whole reply must end with it.
    var kept = 0
    for turns in 0 .. 12:
      let conn = newStubMixConn()
      let msg = fakeWakuMessage(contentTopic = "/test/1/anonymity/proto")
      let publishFut = waku.node.publishOverMix(
        Connection(conn), PubsubTopic("/waku/2/rs/3/0"), msg, chronos.seconds(30)
      )
      await sleepAsync(chronos.milliseconds(20))
      check conn.writes.len == 1
      conn.answer(statusCode)
      for _ in 0 ..< turns:
        await sleepAsync(ZeroDuration)
      # The client read the whole reply, and the publish did not end yet.
      let replyRead =
        conn.replyReceivedFut.finished() and conn.cached.len == 0 and
        not publishFut.finished()
      await publishFut.cancelAndWait()
      if replyRead:
        inc kept
        check publishFut.completed()
        if publishFut.completed():
          let reply = publishFut.read()
          if statusCode == LightPushSuccessCode.SUCCESS:
            check reply.isOk()
          else:
            check reply.isErr() and reply.error.code == statusCode
    check kept > 0

  asyncTest "a cancel after the reply of the exit keeps the reply":
    await keepsReply(LightPushSuccessCode.SUCCESS)

  asyncTest "a cancel after a rejection of the exit keeps the rejection":
    await keepsReply(LightPushErrorCode.PAYLOAD_TOO_LARGE)

  asyncTest "a lightpush reply is the result at once, also when the peer keeps its stream open":
    let conn = newStubMixConn()
    conn.keepsOpen = true
    let msg = fakeWakuMessage(contentTopic = "/test/1/anonymity/proto")
    let request = lightpush_client.publish(
      waku.node.wakuLightpushClient,
      Opt.some(PubsubTopic("/waku/2/rs/3/0")),
      msg,
      Connection(conn),
    )
    defer:
      await request.cancelAndWait()
    await sleepAsync(chronos.milliseconds(20))
    check conn.writes.len == 1
    conn.answer(LightPushSuccessCode.SUCCESS)
    # `withTimeout` cancels at its timeout, and a cancel ends a wait for the EOF.
    let guard = sleepAsync(FUTURE_TIMEOUT)
    discard await race(FutureBase(request), FutureBase(guard))
    await guard.cancelAndWait()
    check request.completed() and request.read().isOk()

  asyncTest "a lightpush request cancelled in its write ends with one cancel":
    ## The peer sends no EOF, so a client that waits for it after the cancel does not end.
    let conn = newStubMixConn(stallInSend = true)
    let msg = fakeWakuMessage(contentTopic = "/test/1/anonymity/proto")
    let request = lightpush_client.publish(
      waku.node.wakuLightpushClient,
      Opt.some(PubsubTopic("/waku/2/rs/3/0")),
      msg,
      Connection(conn),
    )
    await sleepAsync(chronos.milliseconds(20))
    check conn.writes.len == 1
    request.cancelSoon()
    let guard = sleepAsync(FUTURE_TIMEOUT)
    discard await race(FutureBase(request), FutureBase(guard))
    await guard.cancelAndWait()
    check request.cancelled()
    checkUntilTimeout:
      conn.closed()

  asyncTest "a cancelled publish closes the mix connection":
    await cancelsPublishOverMix(stallInSend = false)

  asyncTest "a publish cancelled in the first-hop dial closes the mix connection":
    await cancelsPublishOverMix(stallInSend = true)

  asyncTest "a stalled first-hop dial is given up on too":
    ## A stall in the send leaves the reply future pending, and the close of
    ## the connection cancels the closure that completes it.
    let res = await givesUpOn(stallInSend = true)
    check:
      res.isErr()
      res.error.code == LightPushErrorCode.SERVICE_NOT_AVAILABLE
      lightpushReport(res.error).trigger == Trigger.ServiceUnavailable

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

suite "Mix RLN coordination protection":
  test "the default Mix scope is a 32-byte identifier":
    check defaultTestWakuNodeConf().mixRlnIdentifierHex.hexToSeqByte().len == 32

  asyncTest "shared Mix refuses to start without Relay RLN":
    let node = WakuNode(ports: BoundPorts.init(), wakuMixRln: ModuleRlnProtection())
    let started = await node.startMixRln()
    check:
      started.isErr()
      started.error == "Mix RLN coordination requires Relay RLN"

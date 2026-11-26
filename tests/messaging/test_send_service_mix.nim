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
  libp2p/[peerid, multiaddress, switch, protocols/protocol],
  libp2p/stream/connection,
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_mix,
  logos_delivery/waku/waku_relay,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/api/publish,
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  logos_delivery/waku/node/waku_node/lightpush,
  logos_delivery/waku/rln/rln_plugin,
  logos_delivery/waku/rln/types as rln_types,
  logos_delivery/waku/waku_lightpush/common,
  logos_delivery/waku/waku_lightpush/client,
  logos_delivery/waku/waku_lightpush/rpc_codec,
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/[
    send_service, send_processor, mix_processor, relay_processor, lightpush_processor,
    delivery_task,
  ]
import ../testlib/[futures, testasync, wakucore, wakunodeconf]

## Tests for the anonymity levels of the send path. The first suite mounts no
## mix, so the level decides at once; the second mounts mix and fills the pool
## by hand.

type PlainSendProcessor = ref object of BaseSendProcessor
  calls: int

method isValidProcessor(self: PlainSendProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: PlainSendProcessor, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  task.tryCount.inc()
  task.firstPropagatedTime = Opt.some(Moment.now())
  task.state = DeliveryState.SuccessfullyPropagated

type PassCounter = ref object of BaseSendProcessor
  ## Gives each pass of the send service to `inner`, and counts the passes and the
  ## cancelled ones.
  inner: BaseSendProcessor
  passes: int
  cancelled: int

method process(self: PassCounter, task: DeliveryTask): Future[void] {.async.} =
  inc self.passes
  try:
    await self.inner.process(task)
  except CancelledError as exc:
    inc self.cancelled
    raise exc

type RetryingProcessor = ref object of BaseSendProcessor
  ## Leaves every task for a retry, with `reason` as the outcome's `desc`.
  reason: string

method isValidProcessor(self: RetryingProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: RetryingProcessor, task: DeliveryTask): Future[void] {.async.} =
  task.tryCount.inc()
  task.state = DeliveryState.NextRoundRetry
  task.errorDesc = self.reason

type NeverValidProcessor = ref object of BaseSendProcessor
  ## Takes no task, as a processor with no usable peer does.

method isValidProcessor(
    self: NeverValidProcessor, task: DeliveryTask
): bool {.gcsafe.} =
  return false

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

proc buildTask(
    id: string, age: Duration, contentTopic = "/test/1/anonymity/proto"
): DeliveryTask =
  ## A charged task with no RLN, so `sendUntilPropagated` does not call
  ## `admitAndProve`. Its message is `age` old, and the mix window and the grace
  ## run from its timestamp. The id is the payload, so two tasks never have one
  ## hash.
  let msg = WakuMessage(
    contentTopic: contentTopic,
    payload: id.toBytes(),
    timestamp: getNowInNanosecondTime() - age.nanoseconds,
  )
  let pubsubTopic = PubsubTopic("/waku/2/rs/3/0")
  return DeliveryTask(
    pubsubTopic: pubsubTopic,
    msg: msg,
    msgHash: computeMessageHash(pubsubTopic, msg),
    state: DeliveryState.Entry,
    firstAdmittedTime: Opt.some(Moment.now()),
  )

proc stampAgo(task: DeliveryTask, age: Duration) =
  ## Gives the message of `task` a timestamp `age` before now, with its new hash.
  task.msg.timestamp = getNowInNanosecondTime() - age.nanoseconds
  task.msgHash = computeMessageHash(task.pubsubTopic, task.msg)

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
    (await waku.node.mountMix(3'u16, keys.privateKey, @[], allowAllAddresses = true)).expect(
      "mountMix"
    )
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
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    let service = SendService
      .new(false, waku, manager, mix, retryInterval = chronos.hours(1))
      .expect("SendService.new")
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
    let refused = service.enqueue(large)
    check refused.isErr()
    check:
      refused.error.kind == SendErrorKind.TooLarge
      refused.error.desc.startsWith(MixTooLargeReason)
      large.state == DeliveryState.Entry
      large.firstAdmittedTime.isNone()
      large.msg.proof.len == 0
      large.tryCount == 0
      not large.anonymized
      draws[] == 0
      manager.sentInCurrentEpoch == 0
      errors.len == 0 # a refused message gets no event

    let fits = sizedProofTask("proven-fits", mixLimit(), proofBytes)
    let accepted = service.enqueue(fits)
    check:
      accepted.isOk()
      accepted.value == fits.msgHash
    checkUntilTimeout:
      fits.state == DeliveryState.NextRoundRetry
    check:
      draws[] == 1
      manager.sentInCurrentEpoch == 1
      fits.firstAdmittedTime.isSome()
      fits.msg.proof.len == proofBytes
      mixLightpushSize(fits.pubsubTopic, fits.msg).size == mixLimit()
      fits.errorDesc == MixPoolTooSmallReason
      errors.len == 0

  asyncTest "Required rejects one byte above the proven limit without spending budget":
    let draws = countingRln(waku, 289)
    let manager = newManager()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    let service = SendService
      .new(false, waku, manager, mix, retryInterval = chronos.hours(1))
      .expect("SendService.new")
    service.startSendService()
    defer:
      await service.stopSendService()
    let task = sizedProofTask("proven-too-large", mixLimit() + 1, 289)
    let refused = service.enqueue(task)
    check refused.isErr()
    check:
      refused.error.kind == SendErrorKind.TooLarge
      refused.error.desc.contains("the request has: " & $(mixLimit() + 1) & " bytes")
      task.state == DeliveryState.Entry
      draws[] == 0
      manager.sentInCurrentEpoch == 0
      task.firstAdmittedTime.isNone()

  asyncTest "Preferred spends one proof and one admission for its plain fallback":
    let draws = countingRln(waku, 289)
    let manager = newManager()
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )
    mix.chain(plain)
    let service = SendService
      .new(false, waku, manager, mix, retryInterval = chronos.hours(1))
      .expect("SendService.new")
    service.startSendService()
    defer:
      await service.stopSendService()
    let task = sizedProofTask("plain-fallback", mixLimit() + 1, 289)
    check (service.enqueue(task)).isOk()
    checkUntilTimeout:
      task.state == DeliveryState.SuccessfullyPropagated
    check:
      plain.calls == 1
      draws[] == 1
      manager.sentInCurrentEpoch == 1
      task.msg.proof.len == 289
      not task.anonymized
      task.tryCount == 1 # the plain attempt, and no mix attempt

  asyncTest "a supplied proof uses its actual length before admission":
    let draws = countingRln(waku, 400)
    let task = sizedProofTask("supplied-proof", mixLimit(), 289)
    task.msg.proof = newSeq[byte](289)
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    check mix.checkBeforeSend(task).isOk()
    check:
      draws[] == 0
      task.msg.proof.len == 289
      mixLightpushSize(task.pubsubTopic, task.msg).size == mixLimit()
    task.msg.proof.add(1)
    check mix.checkBeforeSend(task).isErr()
    check draws[] == 0

  asyncTest "an undeclared proof size fails Required before drawing a proof":
    let draws = countingRln(waku, 289)
    var plugin = waku.node.rlnPlugin.get()
    plugin.proofSize = Opt.none(int)
    waku.node.rlnPlugin = Opt.some(plugin)
    let manager = newManager()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    let service = SendService
      .new(false, waku, manager, mix, retryInterval = chronos.hours(1))
      .expect("SendService.new")
    service.startSendService()
    defer:
      await service.stopSendService()
    let task = sizedProofTask("unknown-proof", mixLimit(), 0)
    let refused = service.enqueue(task)
    check refused.isErr()
    check:
      refused.error.kind == SendErrorKind.TooLarge
      refused.error.desc.contains("does not declare its proof size")
      task.state == DeliveryState.Entry
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
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("required", chronos.seconds(5))
    await mix.process(task)

    check:
      plain.calls == 0 # `Required` never uses the plain path
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == MixNotMountedReason

  asyncTest "a Required task that mix cannot attempt gives its admission back":
    ## The mix processor fails the task with no attempt, so the send service
    ## gives the admission of the task back.
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 2),
        clock = proc(): uint64 {.gcsafe, raises: [].} =
          600_000'u64,
      )
      .expect("RateLimitManager.new")
    let chain = setupSendProcessorChain(waku, AnonymityLevel.Required).expect(
        "send processor chain"
      )
    let service = SendService.new(false, waku, manager, chain).expect("SendService.new")
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
    service.startSendService()
    defer:
      await service.stopSendService()

    let task = buildTask("required-refund", chronos.seconds(1))
    check:
      (service.enqueue(task)).isOk()
      manager.sentInCurrentEpoch == 1
    check await errors.waitCount(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      task.state == DeliveryState.FailedToDeliver
      task.tryCount == 0
      manager.sentInCurrentEpoch == 0 # the admission came back

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
      task.errorDesc == MixNotMountedReason

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

  asyncTest "every level gets one delivery window, and the mix window fits in it":
    ## `Preferred` spends `MixWindow` on mix and keeps the rest of the same
    ## `DeliveryWindow` for the plain path, so no level gets a longer send.
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")

    proc serviceFor(level: AnonymityLevel): SendService =
      let chain = setupSendProcessorChain(waku, level).expect("send processor chain")
      return SendService.new(false, waku, manager, chain).expect("SendService.new")

    check:
      serviceFor(AnonymityLevel.None).deliveryWindow == DeliveryWindow
      serviceFor(AnonymityLevel.Required).deliveryWindow == DeliveryWindow
      serviceFor(AnonymityLevel.Preferred).deliveryWindow == DeliveryWindow
      MixWindow < DeliveryWindow

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
    let chain = setupSendProcessorChain(waku, AnonymityLevel.Required).expect(
        "send processor chain"
      )
    let service = SendService.new(false, waku, manager, chain).expect("SendService.new")

    service.startSendService()
    defer:
      await service.stopSendService()
    let task = buildTask("failfast", chronos.seconds(1))
    check:
      (service.enqueue(task)).isOk()
      errors.value == 0 # no event inside `enqueue`
    check await errors.waitCount(1).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check not await errors.waitCount(2).withTimeout(FUTURE_TIMEOUT_SHORT)
    check:
      task.state == DeliveryState.FailedToDeliver
      errors.value == 1 # ... and exactly one later

suite "SendService - anonymity level with a mounted mix":
  ## Mix is mounted before start, as the node factory does. The tests fill the
  ## pool by hand, with or without the lightpush codec that makes a member an exit.
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")
    let mixKeys = generateKeyPair().expect("mix key pair")
    (await waku.node.mountMix(3'u16, mixKeys.privateKey, @[], allowAllAddresses = true)).isOkOr:
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

  proc addMixPeer(lightpush: bool) =
    ## Adds a pool member at an address where nothing listens.
    addMixPeer(1, lightpush)

  proc fillPoolWithNoExit() =
    for _ in 0 ..< MinMixPoolSize:
      addMixPeer(lightpush = false)
    doAssert waku.mixReady()

  proc preferredMix(): MixSendProcessor =
    return MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )

  proc addLightpushServicePeer(port: int) =
    waku.node.peerManager.addServicePeer(
      RemotePeerInfo.init(
        PeerId.init(generateSecp256k1Key()).tryGet(),
        @[MultiAddress.init("/ip4/127.0.0.1/tcp/" & $port).tryGet()],
      ),
      WakuLightPushCodec,
    )

  proc addLightpushServicePeer() =
    ## Adds a lightpush service peer at an address where nothing listens.
    addLightpushServicePeer(1)

  proc startLightpushService(handler: LPProtoHandler): Future[Switch] {.async.} =
    ## Starts a libp2p node that answers lightpush requests with `handler`.
    ## It is a lightpush service peer of the node.
    let service = newTestSwitch()
    service.mount(LPProtocol.new(@[WakuLightPushCodec], handler))
    await service.start()
    waku.node.peerManager.addServicePeer(
      RemotePeerInfo.init(service.peerInfo.peerId, service.peerInfo.addrs),
      WakuLightPushCodec,
    )
    return service

  proc replyingWith(code: LightPushStatusCode, desc: string): LPProtoHandler =
    ## Answers each lightpush request with `code` and `desc`.
    return proc(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
      try:
        let buffer = await conn.readLp(int(DefaultMaxWakuMessageSize))
        let request = LightpushRequest.decode(buffer).valueOr:
          return
        await conn.writeLp(
          LightPushResponse(
            requestId: request.requestId, statusCode: code, statusDesc: Opt.some(desc)
          ).encode()
        )
      except LPStreamError:
        discard

  proc relayReturning(outcome: WakuLightPushResult): RelaySendProcessor =
    ## A relay processor whose publish returns `outcome`.
    let publish: PushMessageHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      return outcome
    return RelaySendProcessor.new(true, publish, waku, waku.brokerCtx)

  asyncTest "a Required task waits for a short pool during its grace, then fails":
    ## A short pool is a reason mix cannot attempt the task. A `Required` task
    ## waits while its admission is within `MixUnusableGrace`, then fails with
    ## that reason.
    for i in 0 ..< MinMixPoolSize - 1:
      addMixPeer(60100 + i, lightpush = true)
    check not waku.mixReady()

    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    let task = buildTask("short-pool", ZeroDuration)
    await mix.process(task)
    check:
      task.state == DeliveryState.NextRoundRetry
      task.errorDesc == MixPoolTooSmallReason # written while it waits
    task.stampAgo(MixUnusableGrace + chronos.seconds(1))
    await mix.process(task)
    check:
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == MixPoolTooSmallReason

    # One more routable member and the pool can build a path.
    addMixPeer(60103, lightpush = true)
    check waku.mixReady()

  asyncTest "a Required task past its grace is attempted once mix can attempt it":
    ## The grace bounds only the wait for a mix that cannot attempt the task.
    for i in 0 ..< MinMixPoolSize - 1:
      addMixPeer(60210 + i, lightpush = true)
    check not waku.mixReady()

    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    let task = buildTask("held-then-usable", ZeroDuration)
    await mix.process(task)
    check task.state == DeliveryState.NextRoundRetry

    addMixPeer(60210 + MinMixPoolSize - 1, lightpush = true)
    check waku.mixReady()
    task.stampAgo(MixUnusableGrace + chronos.seconds(1))
    let fut = mix.process(task)
    check task.tryCount == 1 # mix attempts it
    await fut.cancelAndWait()

  asyncTest "a Required task too large for mix fails at once, also with a short pool":
    ## No pass can make the message fit, so the task does not wait for the pool.
    for i in 0 ..< MinMixPoolSize - 1:
      addMixPeer(60400 + i, lightpush = true)
    check not waku.mixReady()
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    mix.chain(plain)
    let limit = mixLimit()

    # A message at the limit fits, so the short pool holds it within the grace.
    let fits = sizedTask("at-the-limit-short-pool", limit)
    fits.stampAgo(ZeroDuration)
    check await mix.process(fits).withTimeout(FUTURE_TIMEOUT)
    check:
      fits.state == DeliveryState.NextRoundRetry
      fits.errorDesc == MixPoolTooSmallReason

    let early = sizedTask("too-large-short-pool", limit + 1)
    check await mix.process(early).withTimeout(FUTURE_TIMEOUT)
    check:
      early.state == DeliveryState.FailedToDeliver
      early.errorDesc ==
        MixTooLargeReason & ": the request has: " & $(limit + 1) &
        " bytes, the limit is: " & $limit & " bytes"

    addMixPeer(60400 + MinMixPoolSize - 1, lightpush = true)
    check waku.mixReady()
    let task = sizedTask("too-large", limit + 1)
    check await mix.process(task).withTimeout(FUTURE_TIMEOUT)
    check:
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc.startsWith(MixTooLargeReason)
      task.tryCount == 0 # no mix attempt
      not task.anonymized
      plain.calls == 0

  asyncTest "a Preferred task too large for mix takes the plain path at once":
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60410 + i, lightpush = true)
    check waku.mixReady()
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = sizedTask("too-large-preferred", mixLimit() + 1)
    check await mix.process(task).withTimeout(FUTURE_TIMEOUT)
    check:
      plain.calls == 1
      task.state == DeliveryState.SuccessfullyPropagated
      task.tryCount == 1 # the plain attempt, and no mix attempt
      not task.anonymized
      not task.propagatedAnonymously
      mix.fellBackFor() == MixUnusable.None # a size hand-over records no mix outage

  asyncTest "a Required task waits with no exit on the shard during its grace, then fails":
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

    let task = buildTask("no-exit", ZeroDuration)
    await mix.process(task)
    check task.state == DeliveryState.NextRoundRetry
    task.stampAgo(MixUnusableGrace + chronos.seconds(1))
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

  asyncTest "a Preferred task stays on the plain path after a lightpush attempt with no answer":
    fillPoolWithNoExit()

    proc readAndClose(
        conn: Connection, proto: string
    ) {.async: (raises: [CancelledError]).} =
      ## Takes the lightpush request and gives no answer.
      try:
        discard await conn.readLp(int(DefaultMaxWakuMessageSize))
      except LPStreamError:
        discard
      await conn.close()

    let service = await startLightpushService(readAndClose)
    defer:
      await service.stop()
    let mix = preferredMix()
    mix.chain(LightpushSendProcessor.new(waku, waku.brokerCtx))

    let task = buildTask("plain-then-exit", chronos.seconds(5))
    check await mix.process(task).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      task.tryCount == 1 # the lightpush attempt
      task.deanonymized

    addMixPeer(lightpush = true)
    check waku.selectMixLightpushPeer(shard).isSome()
    check await mix.process(task).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      task.tryCount == 2 # lightpush again
      not task.anonymized

  asyncTest "a Preferred task with deanonymized set goes to the plain path before the pool check":
    fillPoolWithNoExit()
    let mix = preferredMix()
    let task = buildTask("deanonymized-before-pool-check", chronos.seconds(5))
    task.deanonymized = true
    await mix.process(task)
    check:
      task.state == DeliveryState.NextRoundRetry
      not task.anonymized
      # The pool has no exit, so a pool check would give `NoExit`.
      mix.fellBackFor() == MixUnusable.None

  asyncTest "a Preferred task without a plain attempt retries over mix when an exit returns":
    for _ in 0 ..< MinMixPoolSize:
      addMixPeer(lightpush = false)
    check waku.mixReady()

    let plain = NeverValidProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("no-plain-then-exit", chronos.seconds(5))
    await mix.process(task)
    check not task.deanonymized

    addMixPeer(lightpush = true)
    check waku.selectMixLightpushPeer(shard).isSome()
    let fut = mix.process(task)
    check task.anonymized
    await fut.cancelAndWait()

  asyncTest "a cancelled plain attempt deanonymizes the task":
    let stalled = newFuture[WakuLightPushResult]("stalled-publish")
    let publish: PushMessageHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      return await stalled
    let relayTask = buildTask("cancelled-relay", ZeroDuration)
    let relayAttempt =
      RelaySendProcessor.new(true, publish, waku, waku.brokerCtx).process(relayTask)
    check:
      relayTask.tryCount == 1
      not relayAttempt.finished() # the attempt waits in the publish
    await relayAttempt.cancelAndWait()
    check relayTask.deanonymized

    # The lightpush service peer accepts the connection and gives no answer.
    var held: seq[StreamTransport]
    proc mute(server: StreamServer, client: StreamTransport) {.async: (raises: []).} =
      held.add(client)

    let listener = createStreamServer(initTAddress("127.0.0.1:0"), mute, {ReuseAddr})
    listener.start()
    defer:
      for client in held:
        await client.closeWait()
      listener.stop()
      await listener.closeWait()
    addLightpushServicePeer(int(listener.localAddress().port))
    let lightpushTask = buildTask("cancelled-lightpush", ZeroDuration)
    let lightpushAttempt =
      LightpushSendProcessor.new(waku, waku.brokerCtx).process(lightpushTask)
    check:
      lightpushTask.tryCount == 1
      not lightpushAttempt.finished() # the attempt waits in the dial
    await lightpushAttempt.cancelAndWait()
    check lightpushTask.deanonymized

  asyncTest "a relay attempt deanonymizes the task when it may have sent the message":
    for (id, outcome, deanonymized) in [
      ("relay-sent", lightpushSuccessResult(1), true),
      # With no relay peer, this node's filter service and archive can get the message.
      (
        "relay-no-peer",
        lighpushErrorResult(LightPushErrorCode.NO_PEERS_TO_RELAY, "no relay peer"),
        true,
      ),
      (
        "relay-refused",
        lighpushErrorResult(LightPushErrorCode.INVALID_MESSAGE, "refused"),
        false,
      ),
    ]:
      checkpoint id
      let task = buildTask(id, ZeroDuration)
      await relayReturning(outcome).process(task)
      check task.deanonymized == deanonymized

  asyncTest "a failed dial or a relay refusal keeps deanonymized from an earlier attempt":
    addLightpushServicePeer()
    let relay = relayReturning(
      lighpushErrorResult(LightPushErrorCode.NO_PEERS_TO_RELAY, "no relay peer")
    )
    relay.chain(LightpushSendProcessor.new(waku, waku.brokerCtx))

    # Relay finds no relay peer, and then the lightpush dial fails.
    let task = buildTask("no-relay-peer-then-failed-dial", ZeroDuration)
    check await relay.process(task).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      task.tryCount == 2
      task.deanonymized

    await relayReturning(
      lighpushErrorResult(LightPushErrorCode.INVALID_MESSAGE, "refused")
    )
      .process(task)
    check:
      task.tryCount == 3
      task.deanonymized

  asyncTest "a lightpush reply deanonymizes the task even with the text of a failed dial":
    let dialText = DialFailurePrefix & "the service node wrote this"
    for (id, code, desc, state) in [
      (
        "reply-no-relay-peers", LightPushErrorCode.NO_PEERS_TO_RELAY,
        "No peers for topic, skipping publish", DeliveryState.NextRoundRetry,
      ),
      (
        "reply-dial-text", LightPushErrorCode.NO_PEERS_TO_RELAY, dialText,
        DeliveryState.NextRoundRetry,
      ),
      # The refusal keeps its code, so the task fails and gets no retry.
      (
        "refusal-dial-text", LightPushErrorCode.INVALID_MESSAGE, dialText,
        DeliveryState.FailedToDeliver,
      ),
    ]:
      checkpoint id
      let service = await startLightpushService(replyingWith(code, desc))
      let task = buildTask(id, ZeroDuration)
      let attempt = LightpushSendProcessor.new(waku, waku.brokerCtx).process(task)
      check await attempt.withTimeout(FUTURE_TIMEOUT_MEDIUM)
      await service.stop()
      check:
        task.tryCount == 1
        task.deanonymized
        task.state == state

  asyncTest "an expired task reports the reason a processor left on it":
    ## A processor that leaves a task for a retry can write why in `errorDesc`.
    ## The error event of the expired task gives it in place of the generic text.
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

    # Its delivery window ends right after its first attempt, so the next tick
    # fails it with the reason that attempt left.
    let task = buildTask("reaper", ZeroDuration)
    task.msg.timestamp =
      getNowInNanosecondTime() - (DeliveryWindow - chronos.milliseconds(300)).nanoseconds
    task.msgHash = computeMessageHash(task.pubsubTopic, task.msg)
    check (service.enqueue(task)).isOk()
    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeout:
      errors.len == 1
    check:
      task.state == DeliveryState.FailedToDeliver
      errors.mapIt(it.messageHash) == @[task.msgHash.to0xHex()]
      errors.mapIt(it.kind) == @[MessageErrorKind.NotPropagated]
      errors.mapIt(it.error) == @["scripted reason"]

  asyncTest "a Preferred task falls back to the plain path once the mix window elapsed":
    ## `MixWindow` ends the mix phase of a task that mix did not deliver. Only a
    ## usable mix shows this: with an unusable mix the reasons decide first.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60140 + i, lightpush = true)

    let plain = PlainSendProcessor()
    let mix =
      MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Preferred, MixWindow)
    mix.chain(plain)

    # Within the mix window, mix attempts the task.
    let early = buildTask("preferred-within-window", MixWindow - chronos.seconds(1))
    let fut = mix.process(early)
    check:
      early.tryCount == 1
      plain.calls == 0
    await fut.cancelAndWait()

    # Mix had the task for its whole window and did not deliver it.
    let task = buildTask("preferred-late", MixWindow + chronos.seconds(1))
    await mix.process(task)

    check:
      plain.calls == 1
      task.state == DeliveryState.SuccessfullyPropagated
      task.tryCount == 1 # the plain attempt, and no mix attempt

  asyncTest "an RLN proof refresh does not start a new Preferred mix window":
    ## `parkForRlnProofRefresh` clears `firstAdmittedTime`, so the new proof
    ## takes a new charge. The window runs from the message timestamp, which a new
    ## proof does not change. So a task that spent its window goes to the plain
    ## path, which keeps the rest of the delivery window.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60145 + i, lightpush = true)

    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )
    mix.chain(plain)

    # A backend with a refresh hook, so the park waits for the refresh.
    waku.node.rlnPlugin = Opt.some(
      RlnPlugin(
        onProofRejected: proc() {.gcsafe, raises: [].} =
          discard
      )
    )

    let task = buildTask("rln-park", chronos.minutes(2))
    task.msg.proof = @[1'u8, 2, 3] # a proof the service would have rejected

    # The park clears the proof and `firstAdmittedTime`, and not the window.
    task.parkForRlnProofRefresh(waku, "rln proof rejected")
    check:
      task.state == DeliveryState.NextRoundRetry
      task.msg.proof.len == 0

    check await mix.process(task).withTimeout(FUTURE_TIMEOUT)
    check:
      task.tryCount == 1 # the plain attempt, and no mix attempt
      plain.calls == 1 # the hand-over
      task.state == DeliveryState.SuccessfullyPropagated

  asyncTest "an RLN rejection fails the task when no backend can refresh":
    ## No RLN backend is mounted, so no refresh follows and a retry would be
    ## rejected the same way. The task fails with the rejection instead of
    ## waiting for a retry.
    let task = buildTask("rln-no-refresh", chronos.minutes(2))
    task.msg.proof = @[1'u8, 2, 3] # a proof the service would have rejected

    task.parkForRlnProofRefresh(waku, "rln proof rejected")
    check:
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == "rln proof rejected"

  asyncTest "the mix window runs from the message timestamp, not the charge":
    ## A charge just now does not give an old message a new mix window.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60150 + i, lightpush = true)

    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Preferred, chronos.minutes(1)
    )
    mix.chain(plain)

    let fresh = buildTask("fresh-message", chronos.seconds(5))
    let fut = mix.process(fresh)
    check:
      fresh.tryCount == 1 # within the window, so mix attempts it
      plain.calls == 0
    await fut.cancelAndWait()

    # The same processor hands over an old message that was charged just now,
    # so the case above cannot pass on a window that never elapses.
    let old = buildTask("old-message", chronos.minutes(2))
    old.firstAdmittedTime = Opt.some(Moment.now())
    check await mix.process(old).withTimeout(FUTURE_TIMEOUT)
    check:
      old.tryCount == 1 # the plain attempt, and no mix attempt
      plain.calls == 1
      old.state == DeliveryState.SuccessfullyPropagated

  asyncTest "a Required task fails with the reason when the node has no usable Mix RLN membership":
    ## With Mix RLN the sender proves the first hop, so no attempt is made
    ## without a membership. One that arrives later reopens the gate.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60170 + i, lightpush = true)
    check waku.mixReady()
    waku.node.wakuMixRln = ModuleRlnProtection()

    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("no-membership", ZeroDuration)
    await mix.process(task)
    check task.state == DeliveryState.NextRoundRetry
    task.stampAgo(MixUnusableGrace + chronos.seconds(1))
    await mix.process(task)
    check:
      plain.calls == 0
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == MixNoMembershipReason

    waku.node.mixMembershipUsable = true
    let later = buildTask("membership-arrived", ZeroDuration)
    await mix.process(later)
    check later.errorDesc != MixNoMembershipReason
    waku.node.wakuMixRln = nil

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
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    mix.chain(plain)

    let task = buildTask("self-hop", ZeroDuration)
    await mix.process(task)
    check task.state == DeliveryState.NextRoundRetry
    task.stampAgo(MixUnusableGrace + chronos.seconds(1))
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

  asyncTest "a task makes one mix attempt in each MixRetryInterval":
    ## Mix does not run here, so each attempt fails at once.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60250 + i, lightpush = true)

    for level in [AnonymityLevel.Preferred, AnonymityLevel.Required]:
      let plain = PlainSendProcessor()
      let mix = MixSendProcessor.new(waku, waku.brokerCtx, level, MixWindow)
      mix.chain(plain)
      let task = buildTask("paced-" & $level, ZeroDuration)

      check await mix.process(task).withTimeout(FUTURE_TIMEOUT)
      check:
        task.tryCount == 1
        task.state == DeliveryState.NextRoundRetry

      # The next pass comes before the interval ends.
      check await mix.process(task).withTimeout(FUTURE_TIMEOUT)
      check:
        task.tryCount == 1
        task.state == DeliveryState.NextRoundRetry

      # The interval ends inside the mix window.
      task.stampAgo(MixRetryInterval)
      task.lastMixAttemptTime = Opt.some(Moment.now() - MixRetryInterval)
      check await mix.process(task).withTimeout(FUTURE_TIMEOUT)
      check:
        task.tryCount == 2
        task.state == DeliveryState.NextRoundRetry
        plain.calls == 0

  asyncTest "a Preferred task takes the plain path inside MixRetryInterval":
    ## The interval is for a mix attempt. A hand-over comes at the next pass.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60260 + i, lightpush = true)

    let plain = PlainSendProcessor()
    let mix =
      MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Preferred, MixWindow)
    mix.chain(plain)

    # The mix window ends after the attempt.
    let late = buildTask("paced-late", ZeroDuration)
    check await mix.process(late).withTimeout(FUTURE_TIMEOUT)
    check late.tryCount == 1
    late.stampAgo(MixWindow + chronos.seconds(1))
    check await mix.process(late).withTimeout(FUTURE_TIMEOUT)
    check:
      plain.calls == 1
      late.state == DeliveryState.SuccessfullyPropagated

    # Mix loses a node after the attempt.
    let unusable = buildTask("paced-unusable", ZeroDuration)
    check await mix.process(unusable).withTimeout(FUTURE_TIMEOUT)
    check unusable.tryCount == 1
    waku.node.peerManager.switch.peerStore.delete(
      waku.node.wakuMix.nodePool.peerIds()[0]
    )
    check not waku.mixReady()
    check await mix.process(unusable).withTimeout(FUTURE_TIMEOUT)
    check:
      plain.calls == 2
      unusable.state == DeliveryState.SuccessfullyPropagated

  asyncTest "a restart makes no mix attempt inside MixRetryInterval":
    ## The stop cancels an attempt that waits for a first hop that does not answer.
    var held: seq[StreamTransport]
    proc mute(server: StreamServer, client: StreamTransport) {.async: (raises: []).} =
      held.add(client)

    let listener = createStreamServer(initTAddress("127.0.0.1:0"), mute, {ReuseAddr})
    listener.start()
    defer:
      for client in held:
        await client.closeWait()
      listener.stop()
      await listener.closeWait()

    await waku.node.start()
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(int(listener.localAddress().port), lightpush = true)

    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )
    let counter = PassCounter(inner: mix)
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService
      .new(false, waku, manager, counter, retryInterval = chronos.milliseconds(10))
      .expect("SendService.new")
    let task = buildTask("paced-restart", ZeroDuration)
    check (service.enqueue(task)).isOk()
    service.startSendService()
    checkUntilTimeout:
      task.tryCount == 1
    await service.stopSendService()
    check counter.cancelled == 1

    service.startSendService()
    defer:
      await service.stopSendService()
    checkUntilTimeout:
      counter.passes >= 5
    check task.tryCount == 1

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

suite "Reasons of an unusable mix":
  asyncTest "a Required task tells why mix cannot send":
    let waku = (await Waku.new(testConf())).expect("Waku.new")
    defer:
      discard await waku.stop()
    let mix = MixSendProcessor.new(
      waku, waku.brokerCtx, AnonymityLevel.Required, chronos.minutes(1)
    )

    proc sendError(id: string): Future[string] {.async.} =
      let task = buildTask(id, ZeroDuration)
      await mix.process(task)
      return task.errorDesc

    let notMounted = await sendError("not-mounted")
    check "not mounted" in notMounted

    let keys = generateKeyPair().expect("mix key pair")
    (await waku.node.mountMix(3'u16, keys.privateKey, @[])).expect("mountMix")
    let tooSmall = await sendError("pool-too-small")
    check:
      "fewer than" in tooSmall
      "--mix-allow-all-addresses" notin tooSmall

    waku.node.peerManager.addPeer(
      RemotePeerInfo.init(
        PeerId.init(generateSecp256k1Key()).tryGet(),
        @[MultiAddress.init("/ip4/192.168.0.7/tcp/60104").tryGet()],
        mixPubKey = Opt.some(keys.publicKey),
      )
    )
    let excluded = await sendError("no-usable-address")
    check "--mix-allow-all-addresses" in excluded

suite "Mix send path - exit peer selection":
  ## With `exit_is_dest` the lightpush server is the last node of the sphinx
  ## path. Mix refuses a destination that has no mix public key. The selection
  ## must skip a plain lightpush peer. The selection reads the pool of the
  ## mounted mix. The test peers are on loopback, so the suite sets
  ## `mix-allow-all-addresses` in the config of the node.
  var waku {.threadvar.}: Waku

  proc mixWaku(allowAllAddresses: bool): Future[Waku] {.async.} =
    var nodeConf = defaultTestWakuNodeConf()
    nodeConf.mix = Opt.some(true)
    nodeConf.mixAllowAllAddresses = allowAllAddresses
    let conf = nodeConf.toWakuConf().valueOr:
      raiseAssert error
    return (await Waku.new(conf)).expect("Waku.new")

  asyncSetup:
    waku = await mixWaku(allowAllAddresses = true)

  asyncTeardown:
    discard await waku.stop()

  const shard = PubsubTopic("/waku/2/rs/3/0")

  proc addLightpushPeerTo(target: Waku, mixCapable: bool, address: string): PeerId =
    let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
    let keyPair = generateKeyPair().expect("mix key pair")
    let mixPubKey =
      if mixCapable:
        Opt.some(keyPair.publicKey)
      else:
        Opt.none(typeof(keyPair.publicKey))
    target.node.peerManager.addPeer(
      RemotePeerInfo.init(
        peerId,
        @[MultiAddress.init(address).tryGet()],
        protocols = @[WakuLightPushCodec],
        shards = @[0'u16],
        mixPubKey = mixPubKey,
      )
    )
    target.node.peerManager.switch.peerStore.setShardInfo(peerId, @[0'u16])
    return peerId

  proc addLightpushPeer(
      mixCapable: bool, address = "/ip4/127.0.0.1/tcp/60000"
  ): PeerId =
    waku.addLightpushPeerTo(mixCapable, address)

  asyncTest "by default a lightpush peer at a private or loopback address is not a mix exit":
    ## The exit is the last node of the path, so the node before it must dial
    ## the address of the exit. The node does not start, so it dials nothing.
    let strict = await mixWaku(allowAllAddresses = false)
    defer:
      discard await strict.stop()

    discard strict.addLightpushPeerTo(true, "/ip4/192.168.0.7/tcp/60000")
    discard strict.addLightpushPeerTo(true, "/ip4/127.0.0.1/tcp/60000")
    check strict.selectMixLightpushPeer(shard).isNone()

    let publicExit = strict.addLightpushPeerTo(true, "/ip4/8.8.8.8/tcp/60000")
    let selected = strict.selectMixLightpushPeer(shard).valueOr:
      raiseAssert "expected the exit at the public address"
    check selected.peerId == publicExit

  asyncTest "a node without mix selects no mix exit":
    let bare = (await Waku.new(testConf())).expect("Waku.new")
    defer:
      discard await bare.stop()
    discard bare.addLightpushPeerTo(true, "/ip4/8.8.8.8/tcp/60000")
    check bare.selectMixLightpushPeer(shard).isNone()

  asyncTest "a plain lightpush peer is never offered as a mix exit":
    discard addLightpushPeer(mixCapable = false)

    check:
      waku.lightpushPeerAvailable(shard) # usable for a plain send
      waku.selectMixLightpushPeer(shard).isNone() # but not as a mix exit

  asyncTest "a mix key alone does not make a peer a usable exit":
    ## Mix routes IPv4 TCP and QUIC-v1 addresses only. A peer with another
    ## address is not in the pool, whatever its mix key is.
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

## A stub for `MixEntryConnection` of `libp2p_mix`. `write` completes or stalls,
## `readOnce` waits for the reply future, and `closeImpl` ends a stalled write
## and the wait for the reply.
type StubMixConn = ref object of Connection
  incoming: AsyncQueue[seq[byte]]
  incomingFut: Future[void]
  replyReceivedFut: Future[void]
  sendStall: Future[void].Raising([CancelledError])
  stallInSend: bool
  cached: seq[byte]
  writes: seq[int] ## the bytes of each `write`

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
  s.writes.add(msg.len)
  if s.stallInSend:
    await s.sendStall

method closeImpl(s: StubMixConn): Future[void] {.async: (raises: []).} =
  if not s.sendStall.finished():
    await s.sendStall.cancelAndWait()
  if not s.incomingFut.isNil():
    await s.incomingFut.cancelAndWait()
  if not s.replyReceivedFut.finished():
    s.replyReceivedFut.complete()

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

  asyncTest "a stalled first-hop dial is given up on too":
    ## A stall in the send leaves the reply future pending. The close of the
    ## connection ends the stalled write.
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
        allowAllAddresses = true,
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

  asyncTest "a relay node's Mix refuses to start without Relay RLN":
    # Only the relay matters here, so the relay is never started.
    let node = WakuNode(
      ports: BoundPorts.init(),
      wakuMixRln: ModuleRlnProtection(),
      wakuRelay: WakuRelay(),
    )
    let started = await node.startMixRln()
    check:
      started.isErr()
      started.error == "Mix RLN coordination requires Relay RLN"

suite "Lightpush publish results":
  test "isDialFailure needs both the error code and the text of a failed dial":
    let dialFailed =
      (LightPushErrorCode.NO_PEERS_TO_RELAY, Opt.some(DialFailurePrefix & "the peer"))
    # A reply of the service node and an error with another code are not failed dials.
    let noRelayPeer = (
      LightPushErrorCode.NO_PEERS_TO_RELAY,
      Opt.some("No peers for topic, skipping publish"),
    )
    let unavailable = (
      LightPushErrorCode.SERVICE_NOT_AVAILABLE, Opt.some(DialFailurePrefix & "the peer")
    )
    check:
      dialFailed.isDialFailure()
      not noRelayPeer.isDialFailure()
      not unavailable.isDialFailure()

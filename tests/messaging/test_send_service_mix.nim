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
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_mix,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/api/publish,
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  logos_delivery/waku/node/waku_node/lightpush,
  logos_delivery/waku/rln/rln_plugin,
  logos_delivery/waku/rln/types as rln_types,
  logos_delivery/waku/waku_lightpush/common,
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service, send_processor, mix_processor, relay_processor, delivery_task]
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
  task.state = DeliveryState.SuccessfullyPropagated
  task.firstPropagatedTime = Opt.some(Moment.now())

type HasPeerProcessor = ref object of BaseSendProcessor
  ## Has a peer and hands each task to the next processor of the chain.

method isValidProcessor(self: HasPeerProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: HasPeerProcessor, task: DeliveryTask): Future[void] {.async.} =
  task.state = DeliveryState.Fallback

type NoPeerProcessor = ref object of BaseSendProcessor
  ## A plain processor with no peer to send through.

method hasSendPeer(
    self: NoPeerProcessor, task: DeliveryTask
): bool {.gcsafe, raises: [].} =
  return false

type FailingProcessor = ref object of BaseSendProcessor
  ## Fails each task, with `reason` in `errorDesc`.
  reason: string

method isValidProcessor(self: FailingProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: FailingProcessor, task: DeliveryTask): Future[void] {.async.} =
  task.errorDesc = self.reason
  task.state = DeliveryState.FailedToDeliver

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

proc buildTask(id: string, contentTopic = "/test/1/anonymity/proto"): DeliveryTask =
  ## A task with no RLN.
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
    state: DeliveryState.Entry,
  )

proc sizedTask(id: string, size: int): DeliveryTask =
  ## A task whose lightpush request over mix has `size` bytes.
  let task = buildTask(id)
  for n in 0 .. size:
    task.msg.payload = newSeq[byte](n)
    if mixLightpushSize(task.pubsubTopic, task.msg).size == size:
      task.msgHash = computeMessageHash(task.pubsubTopic, task.msg)
      return task
  raiseAssert "no payload gives a request of " & $size & " bytes"

proc mixLimit(): int =
  let task = buildTask("probe")
  return mixLightpushSize(task.pubsubTopic, task.msg).limit

proc sizedProofTask(id: string, size, proofBytes: int): DeliveryTask =
  let task = buildTask(id)
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

suite "SendService - mix size at send":
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

  proc requiredService(manager: RateLimitManager): SendService =
    ## A service that runs.
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Required)
    let service = SendService.new(false, waku, manager, mix).expect("SendService.new")
    service.startSendService()
    return service

  asyncTest "proof overhead refuses a Required send, and a task that fits with its proof passes":
    const proofBytes = 289
    let draws = countingRln(waku, proofBytes)
    let manager = newManager()
    let service = requiredService(manager)
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
    if refused.isErr():
      check:
        refused.error.kind == SendErrorKind.TooLarge
        refused.error.desc.startsWith(MixTooLargeReason)
    check:
      large.msg.proof.len == 0
      large.tryCount == 0
      not large.anonymized
      draws[] == 0
      manager.sentInCurrentEpoch == 0

    # A task that fits with its proof passes the size check.
    # Mix has no pool, so the send is refused for that reason.
    let fits = sizedProofTask("proven-fits", mixLimit(), proofBytes)
    let noPool = service.enqueue(fits)
    check noPool.isErr()
    if noPool.isErr():
      check:
        noPool.error.kind == SendErrorKind.NotConnected
        noPool.error.desc == MixUnavailableReason
    check:
      draws[] == 0
      manager.sentInCurrentEpoch == 0
      errors.len == 0 # a refused send gets no event

  asyncTest "Required refuses one byte above the proven limit without spending budget":
    let draws = countingRln(waku, 289)
    let manager = newManager()
    let service = requiredService(manager)
    let task = sizedProofTask("proven-too-large", mixLimit() + 1, 289)
    let refused = service.enqueue(task)
    check refused.isErr()
    if refused.isErr():
      check:
        refused.error.kind == SendErrorKind.TooLarge
        refused.error.desc.contains("the request has " & $(mixLimit() + 1) & " bytes")
    check:
      draws[] == 0
      manager.sentInCurrentEpoch == 0

  asyncTest "Preferred spends one proof and one admission for its plain fallback":
    let draws = countingRln(waku, 289)
    let manager = newManager()
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Preferred)
    mix.chain(plain)
    let service = SendService.new(false, waku, manager, mix).expect("SendService.new")
    service.startSendService()
    defer:
      await service.stopSendService()
    let task = sizedProofTask("plain-fallback", mixLimit() + 1, 289)
    check service.enqueue(task).isOk()
    checkUntilTimeout:
      task.state == DeliveryState.SuccessfullyPropagated
    check:
      plain.calls == 1
      draws[] == 1
      manager.sentInCurrentEpoch == 1
      task.msg.proof.len == 289
      not task.anonymized
      task.tryCount == 0

  asyncTest "a supplied proof uses its actual length at send":
    let draws = countingRln(waku, 400)
    let task = sizedProofTask("supplied-proof", mixLimit(), 289)
    task.msg.proof = newSeq[byte](289)
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Required)
    check mix.checkBeforeAdmission(task).isOk()
    check:
      draws[] == 0
      task.msg.proof.len == 289
      mixLightpushSize(task.pubsubTopic, task.msg).size == mixLimit()
    task.msg.proof.add(1)
    check mix.checkBeforeAdmission(task).error.kind == SendErrorKind.TooLarge
    check draws[] == 0

  asyncTest "an undeclared proof size refuses a Required send before drawing a proof":
    let draws = countingRln(waku, 289)
    var plugin = waku.node.rlnPlugin.get()
    plugin.proofSize = Opt.none(int)
    waku.node.rlnPlugin = Opt.some(plugin)
    let manager = newManager()
    let service = requiredService(manager)
    let task = sizedProofTask("unknown-proof", mixLimit(), 0)
    let refused = service.enqueue(task)
    check refused.isErr()
    if refused.isErr():
      check:
        refused.error.kind == SendErrorKind.Other
        refused.error.desc.contains("does not declare its proof size")
    check:
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
    ## `Required` has no second path, so the task fails with the reason.
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Required)
    mix.chain(plain)

    let task = buildTask("required")
    await mix.process(task)

    check:
      plain.calls == 0 # `Required` never uses the plain path
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == MixUnavailableReason

  asyncTest "a Preferred task takes the plain path at once when mix cannot deliver":
    ## No wait can mount mix, so the task goes to the plain path at once. The
    ## mounted suite covers a mounted mix that cannot attempt the send.
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Preferred)
    mix.chain(plain)

    let task = buildTask("preferred-early")
    await mix.process(task)

    check:
      plain.calls == 1
      task.state == DeliveryState.SuccessfullyPropagated

  asyncTest "enqueue emits no event, and the service emits the outcome later":
    ## `enqueue` sends nothing, so the error comes one time, later.
    ## The error event has the reason that the processor gave.
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
      .new(false, waku, manager, FailingProcessor(reason: "scripted reason"))
      .expect("SendService.new")

    service.startSendService()
    defer:
      await service.stopSendService()
    let task = buildTask("failfast")
    check:
      service.enqueue(task).isOk()
      errors.len == 0 # no event inside `enqueue`
    checkUntilTimeout:
      errors.len == 1
    await sleepAsync(FUTURE_TIMEOUT_SHORT)
    check:
      task.state == DeliveryState.FailedToDeliver
      errors.mapIt(it.messageHash) == @[task.msgHash.to0xHex()]
      errors.mapIt(it.kind) == @[MessageErrorKind.NotPropagated]
      errors.mapIt(it.error) == @["scripted reason"]

  asyncTest "a Required send is refused when mix cannot attempt it":
    ## `Required` has no second path.
    ## So an app must learn at once that the node cannot send, with the reason.
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

    let refused = service.enqueue(buildTask("required-no-mix"))
    check refused.isErr()
    if refused.isErr():
      check:
        refused.error.kind == SendErrorKind.NotConnected
        refused.error.desc == MixUnavailableReason
    check:
      manager.sentInCurrentEpoch == 0
      not await errors.waitCount(1).withTimeout(FUTURE_TIMEOUT_SHORT)

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

  asyncTest "a Required task fails with a short pool":
    ## A short pool is a reason that mix cannot attempt the task.
    for i in 0 ..< MinMixPoolSize - 1:
      addMixPeer(60100 + i, lightpush = true)
    check not waku.mixReady()

    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Required)
    let task = buildTask("short-pool")
    check not mix.hasSendPeer(task)
    await mix.process(task)
    check:
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == MixUnavailableReason

    # One more routable member and the pool can build a path.
    addMixPeer(60103, lightpush = true)
    check:
      waku.mixReady()
      mix.hasSendPeer(task)

  asyncTest "a Required task too large for mix fails for its size, also with a short pool":
    for i in 0 ..< MinMixPoolSize - 1:
      addMixPeer(60400 + i, lightpush = true)
    check not waku.mixReady()
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Required)
    mix.chain(plain)
    let limit = mixLimit()

    # A message at the limit fits, so it fails for the short pool.
    let fits = sizedTask("at-the-limit-short-pool", limit)
    check await mix.process(fits).withTimeout(FUTURE_TIMEOUT)
    check:
      fits.state == DeliveryState.FailedToDeliver
      fits.errorDesc == MixUnavailableReason

    let early = sizedTask("too-large-short-pool", limit + 1)
    check await mix.process(early).withTimeout(FUTURE_TIMEOUT)
    check:
      mix.checkBeforeAdmission(early).error.kind == SendErrorKind.TooLarge
      early.state == DeliveryState.FailedToDeliver
      early.errorDesc ==
        MixTooLargeReason & ": the request has " & $(limit + 1) & " bytes, the limit is " &
        $limit & " bytes"

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
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Preferred)
    mix.chain(plain)

    let task = sizedTask("too-large-preferred", mixLimit() + 1)
    check await mix.process(task).withTimeout(FUTURE_TIMEOUT)
    check:
      plain.calls == 1
      task.state == DeliveryState.SuccessfullyPropagated
      task.tryCount == 0
      not task.anonymized
      not task.propagatedAnonymously
      mix.fellBackFor() == MixUnusable.None # a size hand-over records no mix outage

  asyncTest "a Required task fails with no exit on the shard":
    ## A full pool with no lightpush member on the shard has no exit, as in a
    ## seeded pool before identify and waku-metadata fill its books.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60110 + i, lightpush = false)
    check:
      waku.mixReady()
      waku.selectMixLightpushPeer(shard).isNone()

    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Required)
    mix.chain(plain)

    let task = buildTask("no-exit")
    await mix.process(task)
    check:
      plain.calls == 0
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == MixNoExitReason

  asyncTest "a Preferred task that mix cannot attempt takes the plain path at once":
    ## With no exit on the shard, a `Preferred` task goes to the plain path.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60120 + i, lightpush = false)
    check waku.mixReady()

    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Preferred)
    mix.chain(plain)

    let fresh = buildTask("no-exit-preferred")
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
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Preferred)
    mix.chain(plain)
    check mix.fellBackFor() == MixUnusable.None

    let spent = buildTask("no-exit-spent")
    await mix.process(spent)
    check:
      plain.calls == 1
      spent.state == DeliveryState.SuccessfullyPropagated
      spent.errorDesc.len == 0 # the plain path reports its own outcome
      mix.fellBackFor() == MixUnusable.NoExit

    let again = buildTask("no-exit-spent-again")
    await mix.process(again)
    check:
      plain.calls == 2
      mix.fellBackFor() == MixUnusable.NoExit # unchanged, so logged once

    addMixPeer(60184, lightpush = true)
    check waku.selectMixLightpushPeer(shard).isSome()
    let back = buildTask("exit-back")
    let fut = mix.process(back)
    check:
      back.tryCount == 1 # mix attempts it
      mix.fellBackFor() == MixUnusable.None # ... and the recovery was logged
    await fut.cancelAndWait()

  asyncTest "a Preferred send needs a usable mix or a peer of the plain path":
    ## With no usable mix, a `Preferred` send goes to the plain path at once.
    ## So `send` must refuse it when the plain path has no peer.
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Preferred)
    mix.chain(NoPeerProcessor())
    let service = SendService.new(false, waku, manager, mix).expect("SendService.new")
    service.startSendService()
    defer:
      await service.stopSendService()

    check not waku.mixReady()
    check service.enqueue(buildTask("no-mix-no-peer")).error.kind ==
      SendErrorKind.NotConnected

    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60190 + i, lightpush = true)
    check waku.mixReady()
    check service.enqueue(buildTask("mix-usable")).isOk()

  asyncTest "a Preferred task that mix attempted does not go to the plain path":
    ## The exit can publish the message and its reply can get lost.
    ## A plain send after that shows the sender of a message that is on the network.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60220 + i, lightpush = true)
    check waku.mixReady()

    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Preferred)
    mix.chain(plain)

    # No pool member answers, so the mix attempt fails.
    let task = buildTask("mix-attempt-fails")
    check await mix.process(task).withTimeout(MixReplyTimeout + chronos.seconds(10))
    check:
      task.anonymized # mix attempted it
      task.tryCount == 1
      plain.calls == 0
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc.len > 0

  asyncTest "an RLN rejection fails the task and starts the refresh of the backend":
    ## The refresh is for the next `send`.
    ## The task gets no new proof.
    let refreshes = new int
    waku.node.rlnPlugin = Opt.some(
      RlnPlugin(
        onProofRejected: proc() {.gcsafe, raises: [].} =
          refreshes[].inc()
      )
    )

    let task = buildTask("rln-rejected")
    task.msg.proof = @[1'u8, 2, 3] # a proof that the service rejected

    task.failRlnRejected(waku, "rln proof rejected")
    check:
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == "rln proof rejected"
      refreshes[] == 1

  asyncTest "a send that a service refuses for its RLN proof fails with one event, and it is not sent again":
    let refreshes = new int
    proc generate(
        message: WakuMessage
    ): Future[Result[seq[byte], rln_types.RlnError]] {.async.} =
      return ok(@[1'u8, 2, 3])

    waku.node.rlnPlugin = Opt.some(
      RlnPlugin(
        generateProof: generate,
        onProofRejected: proc() {.gcsafe, raises: [].} =
          refreshes[].inc(),
      )
    )
    let publishes = new int
    proc refuse(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      publishes[].inc()
      return lighpushErrorResult(LightPushErrorCode.OUT_OF_RLN_PROOF, "no valid proof")

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

    let chain = HasPeerProcessor()
    chain.chain(RelaySendProcessor.new(false, refuse, waku, waku.brokerCtx))
    let manager =
      RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
    let service = SendService.new(false, waku, manager, chain).expect("SendService.new")
    service.startSendService()
    defer:
      await service.stopSendService()

    let task = buildTask("rln-refused")
    task.msg.timestamp = getNowInNanosecondTime()
    task.msgHash = computeMessageHash(task.pubsubTopic, task.msg)
    check service.enqueue(task).isOk()
    checkUntilTimeout:
      errors.len == 1
    await sleepAsync(FUTURE_TIMEOUT_SHORT)
    check:
      publishes[] == 1
      refreshes[] == 1
      errors.mapIt(it.messageHash) == @[task.msgHash.to0xHex()]
      errors.mapIt(it.kind) == @[MessageErrorKind.NotPropagated]
      errors.mapIt(it.error) == @["no valid proof"]

  asyncTest "an RLN rejection fails the task when no backend can refresh":
    ## No RLN backend is mounted.
    let task = buildTask("rln-no-refresh")
    task.msg.proof = @[1'u8, 2, 3] # a proof that the service rejected

    task.failRlnRejected(waku, "rln proof rejected")
    check:
      task.state == DeliveryState.FailedToDeliver
      task.errorDesc == "rln proof rejected"

  asyncTest "a Required task fails when mix cannot encode its own hop":
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
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Required)
    mix.chain(plain)

    let task = buildTask("self-hop")
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

  asyncTest "a mix attempt marks the task before it can know whether it worked":
    ## The exit publishes before it replies, so the mark must be set before any
    ## reply. The test cancels the attempt before a reply can arrive.
    for i in 0 ..< MinMixPoolSize:
      addMixPeer(60170 + i, lightpush = true)

    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Required)
    let task = buildTask("announced-at-attempt")

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

    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Required)
    let task = buildTask("usable")
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

suite "Mix RLN coordination protection":
  test "the default Mix scope is a 32-byte identifier":
    check defaultTestWakuNodeConf().mixRlnIdentifierHex.hexToSeqByte().len == 32

  asyncTest "shared Mix refuses to start without Relay RLN":
    let node = WakuNode(ports: BoundPorts.init(), wakuMixRln: ModuleRlnProtection())
    let started = await node.startMixRln()
    check:
      started.isErr()
      started.error == "Mix RLN coordination requires Relay RLN"

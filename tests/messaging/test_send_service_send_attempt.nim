{.used.}

import std/[importutils, sequtils, tables]
import chronos, testutils/unittests, results, stew/byteutils, libp2p/peerid

import
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/rln/[rln_api, rln_plugin],
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service {.all.}, transports, delivery_task]
import ../testlib/[fake_transport, futures, testasync, wakucore, wakunodeconf]

privateAccess(SendService) # the tests read `deliveryTasks`

## Tests of `sendAttempt`, which makes one attempt of a message over one transport.

const LongInterval = chronos.minutes(1)
  ## The timeout of an attempt that must not time out.

const ShortInterval = chronos.milliseconds(20)

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

type FakeRln = ref object
  proofs: int ## The proofs that the backend made.
  refreshes: int ## The calls of `onProofRejected`.

suite "SendService - sendAttempt":
  var waku {.threadvar.}: Waku
  var manager {.threadvar.}: RateLimitManager
  var sendEvents {.threadvar.}: EventCounter
  var started {.threadvar.}: seq[SendService]

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")
    manager = RateLimitManager
      .new(RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 5))
      .expect("RateLimitManager.new")
    started = @[]
    sendEvents = EventCounter()
    let events = sendEvents
    discard MessagePropagatedEvent
      .listen(
        waku.brokerCtx,
        proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
          events.inc(),
      )
      .expect("listen propagated")
    discard MessageSentEvent
      .listen(
        waku.brokerCtx,
        proc(event: MessageSentEvent) {.async: (raises: []).} =
          events.inc(),
      )
      .expect("listen sent")
    discard MessageErrorEvent
      .listen(
        waku.brokerCtx,
        proc(event: MessageErrorEvent) {.async: (raises: []).} =
          events.inc(),
      )
      .expect("listen error")

  asyncTeardown:
    for service in started:
      await service.stopSendService()
    await MessagePropagatedEvent.dropAllListeners(waku.brokerCtx)
    await MessageSentEvent.dropAllListeners(waku.brokerCtx)
    await MessageErrorEvent.dropAllListeners(waku.brokerCtx)
    discard await waku.stop()

  const Shard = PubsubTopic("/waku/2/rs/3/0")

  proc buildTask(
      id: string, timestamp: Timestamp = getNowInNanosecondTime()
  ): DeliveryTask =
    ## The payload is `id`, so each id gives its own message hash.
    let msg = WakuMessage(
      contentTopic: "/test/1/send-attempt/proto",
      payload: id.toBytes(),
      timestamp: timestamp,
    )
    return DeliveryTask(
      pubsubTopic: Shard,
      msg: msg,
      msgHash: computeMessageHash(Shard, msg),
      state: DeliveryState.Entry,
    )

  proc newService(
      transports: Transports,
      reliability = false,
      attemptInterval = SendAttemptInterval,
      maxValidationAge = StoreValidationWindow,
      maxSendsInFlight = MaxSendsInFlight,
  ): SendService =
    ## A service that runs.
    let service = SendService
      .new(
        reliability,
        waku,
        manager,
        transports,
        attemptInterval = attemptInterval,
        maxValidationAge = maxValidationAge,
        storeValidationInterval = chronos.milliseconds(10),
        maxSendsInFlight = maxSendsInFlight,
      )
      .expect("SendService.new")
    service.startSendService()
    started.add(service)
    return service

  proc mountRln(refreshes = true): FakeRln =
    ## Mounts an RLN backend that gives each proof its own bytes.
    let rln = FakeRln()
    proc generate(message: WakuMessage): Future[Result[seq[byte], RlnError]] {.async.} =
      rln.proofs.inc()
      return ok(@[byte(rln.proofs), 2, 3])

    var plugin = RlnPlugin(name: "fake", generateProof: generate)
    if refreshes:
      plugin.onProofRejected = proc() {.gcsafe, raises: [].} =
        rln.refreshes.inc()
    waku.node.rlnPlugin = Opt.some(plugin)
    return rln

  proc attempt(
      service: SendService,
      task: DeliveryTask,
      transport: Transport,
      timeout = LongInterval,
      lightpushPeers: seq[RemotePeerInfo] = @[],
  ): Future[SendAttempt] {.async.} =
    ## One attempt of `task`. The service accepts the task first, as `enqueue` does.
    if task.msgHash notin service.deliveryTasks:
      service.accept(task).expect("accept")
    return await service.sendAttempt(task, transport, timeout, lightpushPeers)

  proc unreachablePeer(): RemotePeerInfo =
    return RemotePeerInfo.init(
      PeerId.init(generateSecp256k1Key()).tryGet(),
      @[MultiAddress.init("/ip4/127.0.0.1/tcp/1").tryGet()],
    )

  asyncTest "an attempt uses only the transport of the call, and gives no event":
    ## `send` makes its events from the result.
    let relay = FakeTransport.new()
    let lightpush = FakeTransport.new()
    let service = newService(
      transportsOf((Transport.Relay, relay), (Transport.Lightpush, lightpush))
    )
    let task = buildTask("one-transport")

    let res = await service.attempt(task, Transport.Lightpush)
    check:
      res.msgHash == task.msgHash
      res.outcome == AttemptOutcome.Propagated
      lightpush.calls == @["one-transport"]
      relay.calls.len == 0
      relay.checks == 0
    check not await sendEvents.waitCount(1).withTimeout(FUTURE_TIMEOUT_SHORT)

  asyncTest "an attempt that does not propagate gives its reason, and makes no second attempt":
    let lightpush =
      FakeTransport.new(results = @[AttemptResult.notPropagated("scripted")])
    let relay = FakeTransport.new()
    let service = newService(
      transportsOf((Transport.Relay, relay), (Transport.Lightpush, lightpush))
    )

    let res = await service.attempt(buildTask("one-attempt"), Transport.Lightpush)
    check:
      res.outcome == AttemptOutcome.NotPropagated
      res.desc == "scripted"
      res.confirmation == Confirmation.NotConfirmed
    check not await lightpush.attempts.waitCount(2).withTimeout(FUTURE_TIMEOUT_SHORT)
    check relay.calls.len == 0

  asyncTest "a later attempt of a message uses the same proof and gets no new charge":
    ## A new proof for the same message draws one more RLN message id.
    let rln = mountRln()
    let lightpush = FakeTransport.new(
      results = @[AttemptResult.notPropagated("scripted"), AttemptResult.propagated()]
    )
    let service = newService(transportsOf((Transport.Lightpush, lightpush)))
    let task = buildTask("same-proof")

    let first = await service.attempt(task, Transport.Lightpush)
    let second = await service.attempt(task, Transport.Lightpush)
    check:
      first.outcome == AttemptOutcome.NotPropagated
      second.outcome == AttemptOutcome.Propagated
      rln.proofs == 1
      manager.sentInCurrentEpoch == 1'u64
      lightpush.messages.len == 2
    if lightpush.messages.len == 2:
      check:
        lightpush.messages[0].proof.len > 0
        lightpush.messages[0].proof == lightpush.messages[1].proof

  asyncTest "an attempt over another transport uses the same proof":
    let rln = mountRln()
    let relay = FakeTransport.new(results = @[AttemptResult.notPropagated("scripted")])
    let lightpush = FakeTransport.new()
    let service = newService(
      transportsOf((Transport.Relay, relay), (Transport.Lightpush, lightpush))
    )
    let task = buildTask("two-transports")

    discard await service.attempt(task, Transport.Relay)
    discard await service.attempt(task, Transport.Lightpush)
    check:
      rln.proofs == 1
      manager.sentInCurrentEpoch == 1'u64
      relay.messages.len == 1 and lightpush.messages.len == 1
    if relay.messages.len == 1 and lightpush.messages.len == 1:
      check relay.messages[0].proof == lightpush.messages[0].proof

  asyncTest "an attempt with no answer ends at its timeout":
    let relay = FakeTransport.new(stalled = @["no-answer"])
    let service = newService(transportsOf((Transport.Relay, relay)))

    let running = service.attempt(
      buildTask("no-answer"), Transport.Relay, timeout = chronos.milliseconds(50)
    )
    check await running.withTimeout(FUTURE_TIMEOUT_MEDIUM)
    if not running.completed():
      return
    check:
      running.read().outcome == AttemptOutcome.NotPropagated
      relay.cancelled == @["no-answer"]

  asyncTest "an attempt over a transport that the node does not have is Invalid":
    let relay = FakeTransport.new()
    let service = newService(transportsOf((Transport.Relay, relay)))

    let res = await service.attempt(buildTask("no-transport"), Transport.Lightpush)
    check:
      res.outcome == AttemptOutcome.Invalid
      relay.calls.len == 0

  asyncTest "the lightpush peers of an attempt go to the transport":
    let lightpush = FakeTransport.new()
    let service = newService(transportsOf((Transport.Lightpush, lightpush)))
    let peer = unreachablePeer()

    discard await service.attempt(
      buildTask("given-peer"), Transport.Lightpush, lightpushPeers = @[peer]
    )
    check lightpush.peers.len == 1
    if lightpush.peers.len == 1:
      check lightpush.peers[0].mapIt(it.peerId) == @[peer.peerId]

  asyncTest "a transport that cannot take the message now gives no proof and no transmission":
    let rln = mountRln()
    let lightpush =
      FakeTransport.new(checkResult = Opt.some(AttemptResult.notPropagated()))
    let service = newService(transportsOf((Transport.Lightpush, lightpush)))

    let res = await service.attempt(buildTask("no-peer"), Transport.Lightpush)
    check:
      res.outcome == AttemptOutcome.NotPropagated
      lightpush.calls.len == 0
      rln.proofs == 0

  asyncTest "a relay attempt after a refused proof validates the message again":
    ## The relay of the node validated the old proof, and the message has a new one.
    discard mountRln()
    let relay = FakeTransport.new(
      results = @[
        AttemptResult(outcome: AttemptOutcome.NotPropagated, validated: true),
        AttemptResult(outcome: AttemptOutcome.NotPropagated, proofRefused: true),
        AttemptResult(outcome: AttemptOutcome.NotPropagated, validated: true),
      ]
    )
    let service = newService(transportsOf((Transport.Relay, relay)))
    let task = buildTask("validated-again")

    for _ in 0 ..< 4:
      discard await service.attempt(task, Transport.Relay)
    check relay.validated == @[false, true, false, true]

  asyncTest "after a refused RLN proof, the next attempt makes a new proof with a new charge":
    ## A node refuses the proof when the RLN state of this node is old.
    ## The backend then refreshes that state, and a new proof draws a new message id.
    let rln = mountRln()
    let lightpush = FakeTransport.new(
      results = @[
        AttemptResult(
          outcome: AttemptOutcome.NotPropagated, desc: "bad proof", proofRefused: true
        ),
        AttemptResult.propagated(),
      ]
    )
    let service = newService(transportsOf((Transport.Lightpush, lightpush)))
    let task = buildTask("proof-refused")

    let first = await service.attempt(task, Transport.Lightpush)
    check:
      first.outcome == AttemptOutcome.NotPropagated
      rln.refreshes == 1
      rln.proofs == 1
      manager.sentInCurrentEpoch == 1'u64

    let second = await service.attempt(task, Transport.Lightpush)
    check:
      second.outcome == AttemptOutcome.Propagated
      rln.proofs == 2
      manager.sentInCurrentEpoch == 2'u64
      lightpush.messages.len == 2
    if lightpush.messages.len == 2:
      check lightpush.messages[0].proof != lightpush.messages[1].proof

  asyncTest "a refused RLN proof is Invalid when the backend cannot refresh":
    discard mountRln(refreshes = false)
    let lightpush = FakeTransport.new(
      results = @[
        AttemptResult(
          outcome: AttemptOutcome.NotPropagated, desc: "bad proof", proofRefused: true
        )
      ]
    )
    let service = newService(transportsOf((Transport.Lightpush, lightpush)))

    let res = await service.attempt(buildTask("no-refresh"), Transport.Lightpush)
    check:
      res.outcome == AttemptOutcome.Invalid
      res.desc == "bad proof"

  asyncTest "a new proof after a refused proof needs budget":
    discard mountRln()
    manager = RateLimitManager
      .new(RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1))
      .expect("RateLimitManager.new")
    let lightpush = FakeTransport.new(
      results = @[
        AttemptResult(
          outcome: AttemptOutcome.NotPropagated, desc: "bad proof", proofRefused: true
        )
      ]
    )
    let service = newService(transportsOf((Transport.Lightpush, lightpush)))
    let task = buildTask("no-budget")

    discard await service.attempt(task, Transport.Lightpush)
    let second = await service.attempt(task, Transport.Lightpush)
    check:
      second.outcome == AttemptOutcome.Invalid
      second.desc == NoBudgetForNewProofReason
      lightpush.calls.len == 1

  asyncTest "with reliability off a propagated attempt has nothing to confirm":
    let relay = FakeTransport.new()
    let service = newService(transportsOf((Transport.Relay, relay)))

    let res = await service.attempt(buildTask("no-reliability"), Transport.Relay)
    check:
      res.outcome == AttemptOutcome.Propagated
      res.confirmation == Confirmation.NotExpected

  asyncTest "an ephemeral message has nothing to confirm, over mix or not":
    ## A Store node does not keep an ephemeral message.
    let service = newService(
      transportsOf(
        (Transport.Relay, FakeTransport.new()),
        (Transport.Lightpush, FakeTransport.new()),
        (Transport.Mix, FakeTransport.new()),
      ),
      reliability = true,
    )

    proc checkNotExpected(id: string, transport: Transport) {.async.} =
      let task = buildTask(id)
      task.msg.ephemeral = true
      let res = await service.attempt(task, transport)
      check:
        res.outcome == AttemptOutcome.Propagated
        res.confirmation == Confirmation.NotExpected

    await checkNotExpected("ephemeral-relay", Transport.Relay)
    await checkNotExpected("ephemeral-mix", Transport.Mix)

  asyncTest "a mix attempt that propagates is Confirmed, with no Store query":
    ## A Store query would name the message from the address of this node.
    let mix = FakeTransport.new()
    let service = newService(
      transportsOf((Transport.Mix, mix), (Transport.Lightpush, FakeTransport.new())),
      reliability = true,
    )
    let task = buildTask("over-mix")

    let res = await service.attempt(task, Transport.Mix)
    check:
      res.confirmation == Confirmation.Confirmed
      task.anonymized
      not task.awaitsStore()

  asyncTest "a propagated attempt with no Store answer is NotConfirmed at its timeout, and nothing of it runs after":
    let relay = FakeTransport.new()
    let service = newService(transportsOf((Transport.Relay, relay)), reliability = true)
    let task = buildTask("no-store")
    const Timeout = chronos.milliseconds(100)

    let started = Moment.now()
    let res = await service.attempt(task, Transport.Relay, timeout = Timeout)
    check:
      res.outcome == AttemptOutcome.Propagated
      res.confirmation == Confirmation.NotConfirmed
      Moment.now() - started >= Timeout - chronos.milliseconds(5)
      not task.awaitsStore()

  asyncTest "a propagated attempt returns Confirmed as soon as a Store node reports the message":
    let relay = FakeTransport.new()
    let service = newService(transportsOf((Transport.Relay, relay)), reliability = true)
    let task = buildTask("store-answers")

    let running = service.attempt(task, Transport.Relay)
    checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, chronos.milliseconds(5)):
      task.awaitsStore()
    # The Store validation loop does this when a Store node reports the message.
    task.confirmed = true
    task.storeAnswer.complete()

    check await running.withTimeout(FUTURE_TIMEOUT_MEDIUM)
    if not running.completed():
      return
    check running.read().confirmation == Confirmation.Confirmed

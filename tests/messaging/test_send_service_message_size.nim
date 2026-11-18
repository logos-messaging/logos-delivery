{.used.}

import std/strutils
import chronos, testutils/unittests, results

import
  libp2p_mix/curve25519,
  logos_delivery/waku/waku,
  logos_delivery/waku/api/publish,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_relay,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/rln/rln_plugin,
  logos_delivery/waku/rln/types as rln_types,
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service, send_processor, mix_processor, delivery_task]
import ../testlib/[testasync, wakunodeconf]

const
  ProofBytes = 289 ## The proof size of the RLN backend of these tests.
  Limit = 1000 ## The `--max-msg-size` of the test node, in bytes.
  RelayRefusal = "Message size exceeded maximum of " & $Limit & " bytes"
    ## The error of relay validation for a message above `Limit`.

type PublishingProcessor = ref object of BaseSendProcessor
  calls: int

method attempt(
    self: PublishingProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  inc self.calls
  return StepReport.init(Trigger.Published)

type ErrorLog = ref object ## The texts of the `MessageErrorEvent`s of one test.
  texts: seq[string]
  listener: MessageErrorEventListener

proc testConf(): WakuConf =
  var nodeConf = defaultTestWakuNodeConf()
  nodeConf.maxMessageSize = $Limit & " B"
  return nodeConf.toWakuConf().valueOr:
    raiseAssert error

proc sizedTask(id: string, size: int): DeliveryTask =
  ## A task whose message encodes to `size` bytes with a proof of `ProofBytes` bytes.
  ## The id in the content topic gives each task its own hash.
  let pubsubTopic = PubsubTopic("/waku/2/rs/3/0")
  var msg = WakuMessage(
    contentTopic: "/message-size/1/" & id & "/proto",
    timestamp: getNowInNanosecondTime(),
    proof: newSeq[byte](ProofBytes),
  )
  for n in 0 .. size:
    msg.payload = newSeq[byte](n)
    if msg.encode().len == size:
      msg.proof = @[]
      return DeliveryTask(
        pubsubTopic: pubsubTopic,
        msg: msg,
        msgHash: computeMessageHash(pubsubTopic, msg),
        state: DeliveryState.Initial,
      )
  raiseAssert "no payload gives a message of " & $size & " bytes"

func withProof(msg: WakuMessage): WakuMessage =
  var proven = msg
  proven.proof = newSeq[byte](ProofBytes)
  return proven

proc countingRln(waku: Waku): ref int =
  ## Mounts an RLN backend that counts the proofs that it makes.
  let draws = new int
  proc generate(
      message: WakuMessage
  ): Future[Result[seq[byte], rln_types.RlnError]] {.async.} =
    draws[].inc()
    return ok(newSeq[byte](ProofBytes))

  waku.node.rlnPlugin =
    Opt.some(RlnPlugin(generateProof: generate, proofSize: Opt.some(ProofBytes)))
  return draws

suite "SendService - message size at send":
  var waku {.threadvar.}: Waku
  var draws {.threadvar.}: ref int
  var errors {.threadvar.}: ErrorLog
  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")
    draws = countingRln(waku)
    errors = ErrorLog()
    let log = errors
    log.listener = MessageErrorEvent
      .listen(
        waku.brokerCtx,
        proc(event: MessageErrorEvent) {.async: (raises: []).} =
          log.texts.add(event.error),
      )
      .expect("listen")
  asyncTeardown:
    await MessageErrorEvent.dropListener(waku.brokerCtx, errors.listener)
    discard await waku.stop()

  proc newManager(messagesPerEpoch = 1'u64): RateLimitManager =
    RateLimitManager
      .new(
        RateLimitConfig(
          enabled: true, epochPeriodSec: 600, messagesPerEpoch: messagesPerEpoch
        )
      )
      .expect("RateLimitManager.new")

  proc startedService(
      processors: SendProcessors,
      manager: RateLimitManager,
      anonymityLevel = AnonymityLevel.None,
      maxSendsInFlight = MaxSendsInFlight,
  ): SendService =
    let service = SendService
      .new(
        false,
        waku,
        manager,
        processors,
        anonymityLevel,
        maxSendsInFlight = maxSendsInFlight,
      )
      .expect("SendService.new")
    service.startSendService()
    return service

  proc mountedMix(): Future[MixSendProcessor] {.async.} =
    let keys = generateKeyPair().expect("mix key pair")
    (await waku.node.mountMix(3'u16, keys.privateKey, @[])).expect("mountMix")
    return MixSendProcessor.new(waku, waku.brokerCtx)

  proc checkTooLarge(refused: Result[void, SendError], size: int) =
    check refused.isErr()
    if refused.isErr():
      check:
        refused.error.kind == SendErrorKind.TooLarge
        refused.error.desc == messageTooLargeDesc(size, Limit)
        refused.error.desc.startsWith(MessageTooLargeReason)

  asyncTest "a message at the limit sends and one byte more is refused with no proof":
    let manager = newManager(messagesPerEpoch = 2)
    let relay = PublishingProcessor()
    let service = startedService(SendProcessors(relay: relay), manager)
    defer:
      await service.stopSendService()

    let fits = sizedTask("fits", Limit)
    check service.enqueue(fits).isOk()
    checkUntilTimeout:
      fits.state == DeliveryState.Propagated
    check:
      fits.msg.proof.len == ProofBytes
      draws[] == 1
      manager.sentInCurrentEpoch == 1
      relay.calls == 1
    check (await waku.node.wakuRelay.validateMessage(fits.pubsubTopic, fits.msg)).isOk()

    # The budget has room for one more message, so only the size refuses it.
    let tooLarge = sizedTask("too-large", Limit + 1)
    checkTooLarge(service.enqueue(tooLarge), Limit + 1)
    check:
      tooLarge.state == DeliveryState.Initial
      tooLarge.firstAdmittedTime.isNone()
      tooLarge.msg.proof.len == 0
      draws[] == 1
      manager.sentInCurrentEpoch == 1
      relay.calls == 1
      errors.texts.len == 0 # the refused send gets no event
    let relayCheck = await waku.node.wakuRelay.validateMessage(
      tooLarge.pubsubTopic, tooLarge.msg.withProof()
    )
    check:
      relayCheck.isErr()
      relayCheck.error == RelayRefusal

  asyncTest "a message above the limit is TooLarge also when the budget is spent":
    ## An app must learn at once that the message can never go out.
    let manager = newManager()
    let service = startedService(SendProcessors(relay: PublishingProcessor()), manager)
    defer:
      await service.stopSendService()

    check service.enqueue(sizedTask("spends-the-budget", Limit)).isOk()
    check manager.quotaState() == QuotaState.Exhausted
    checkTooLarge(
      service.enqueue(sizedTask("too-large-no-budget", Limit + 1)), Limit + 1
    )

  asyncTest "a message above the limit is TooLarge also when the service is full":
    ## `QueueFull` asks the app to send again, and no later send of this message can pass.
    let service = startedService(
      SendProcessors(relay: PublishingProcessor()),
      newManager(messagesPerEpoch = 2),
      maxSendsInFlight = 1,
    )
    defer:
      await service.stopSendService()

    check service.enqueue(sizedTask("fills-the-queue", Limit)).isOk()
    check service.isFull()
    checkTooLarge(
      service.enqueue(sizedTask("too-large-when-full", Limit + 1)), Limit + 1
    )

  asyncTest "with no stated proof size, the check counts the message without its proof":
    ## A backend can state no proof size, and `send` then cannot count the proof.
    var plugin = waku.node.rlnPlugin.get()
    plugin.proofSize = Opt.none(int)
    waku.node.rlnPlugin = Opt.some(plugin)
    let service = startedService(
      SendProcessors(relay: PublishingProcessor()), newManager(messagesPerEpoch = 2)
    )
    defer:
      await service.stopSendService()

    # The message has `Limit + 1` bytes only with its proof.
    check service.enqueue(sizedTask("no-size-fits", Limit + 1)).isOk()

    let tooLarge = sizedTask("no-size-too-large", Limit + ProofBytes + 100)
    let size = tooLarge.msg.encode().len
    check size > Limit # also without its proof
    checkTooLarge(service.enqueue(tooLarge), size)

  asyncTest "a Preferred message above the limit is refused":
    let manager = newManager()
    let plain = PublishingProcessor()
    let mix = await mountedMix()
    let service = startedService(
      SendProcessors(mix: mix, relay: plain), manager, AnonymityLevel.Preferred
    )
    defer:
      await service.stopSendService()

    checkTooLarge(
      service.enqueue(sizedTask("preferred-too-large", Limit + 1)), Limit + 1
    )
    check:
      draws[] == 0
      manager.sentInCurrentEpoch == 0
      plain.calls == 0

  asyncTest "a Required message that mix can carry is still refused above the limit":
    let manager = newManager()
    let mix = await mountedMix()
    let service =
      startedService(SendProcessors(mix: mix), manager, AnonymityLevel.Required)
    defer:
      await service.stopSendService()

    let task = sizedTask("required-too-large", Limit + 1)
    let (mixSize, mixLimit) =
      waku.mixLightpushSize(task.pubsubTopic, task.msg.withProof())
    check mixSize <= mixLimit # one mix message carries it
    checkTooLarge(service.enqueue(task), Limit + 1)
    check:
      draws[] == 0
      manager.sentInCurrentEpoch == 0

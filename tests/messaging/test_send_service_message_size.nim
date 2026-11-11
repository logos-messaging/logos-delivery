{.used.}

import chronos, testutils/unittests, results

import
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_relay,
  logos_delivery/waku/rln/rln_plugin,
  logos_delivery/waku/rln/types as rln_types,
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
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

type PlainSendProcessor = ref object of BaseSendProcessor
  ## A fake plain send that propagates each task.
  calls: int

method isValidProcessor(self: PlainSendProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

method sendImpl(self: PlainSendProcessor, task: DeliveryTask): Future[void] {.async.} =
  inc self.calls
  task.state = DeliveryState.SuccessfullyPropagated
  task.firstPropagatedTime = Opt.some(Moment.now())

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
        state: DeliveryState.Entry,
      )
  raiseAssert "no payload gives a message of " & $size & " bytes"

func withProof(msg: WakuMessage): WakuMessage =
  ## `msg` with a proof of `ProofBytes` bytes.
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

suite "SendService message size at send":
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

  proc newManager(): RateLimitManager =
    RateLimitManager
      .new(RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1))
      .expect("RateLimitManager.new")

  proc startedService(
      chain: BaseSendProcessor, manager: RateLimitManager
  ): SendService =
    let service = SendService.new(false, waku, manager, chain).expect("SendService.new")
    service.startSendService()
    return service

  proc checkTooLarge(refused: Result[void, SendError], size: int) =
    check refused.isErr()
    if refused.isErr():
      check:
        refused.error.kind == SendErrorKind.TooLarge
        refused.error.desc ==
          MessageTooLargeReason & ": the message has " & $size & " bytes"

  asyncTest "a message at the limit sends and one byte more is refused with no proof":
    let manager = RateLimitManager
      .new(RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 2))
      .expect("RateLimitManager.new")
    let plain = PlainSendProcessor()
    let service = startedService(plain, manager)
    defer:
      await service.stopSendService()

    let fits = sizedTask("fits", Limit)
    check service.enqueue(fits).isOk()
    checkUntilTimeout:
      fits.state == DeliveryState.SuccessfullyPropagated
    check:
      fits.msg.proof.len == ProofBytes
      draws[] == 1
      manager.sentInCurrentEpoch == 1
      plain.calls == 1
    check (await waku.node.wakuRelay.validateMessage(fits.pubsubTopic, fits.msg)).isOk()

    # The budget has room for one more message, so only the size refuses it.
    let tooLarge = sizedTask("too-large", Limit + 1)
    checkTooLarge(service.enqueue(tooLarge), Limit + 1)
    check:
      tooLarge.msg.proof.len == 0
      draws[] == 1
      manager.sentInCurrentEpoch == 1
      plain.calls == 1
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
    let service = startedService(PlainSendProcessor(), manager)
    defer:
      await service.stopSendService()

    check service.enqueue(sizedTask("spends-the-budget", Limit)).isOk()
    check manager.quotaState() == QuotaState.Exhausted
    checkTooLarge(
      service.enqueue(sizedTask("too-large-no-budget", Limit + 1)), Limit + 1
    )

  asyncTest "a Preferred message above the limit is refused":
    let manager = newManager()
    let plain = PlainSendProcessor()
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Preferred)
    mix.chain(plain)
    let service = startedService(mix, manager)
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
    let mix = MixSendProcessor.new(waku, waku.brokerCtx, AnonymityLevel.Required)
    let service = startedService(mix, manager)
    defer:
      await service.stopSendService()

    let task = sizedTask("required-too-large", Limit + 1)
    check mix.checkBeforeAdmission(task).isOk() # one mix message carries it
    checkTooLarge(service.enqueue(task), Limit + 1)
    check:
      draws[] == 0
      manager.sentInCurrentEpoch == 0

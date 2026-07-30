{.used.}

import std/net
import chronos, chronicles, testutils/unittests, results, stew/byteutils

import
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service, send_processor, delivery_task]
import ../testlib/testasync

## Scheduler-level coverage for the send service's rate-limit seam: a task is
## charged exactly once however many rounds it takes, and an over-budget task
## is parked then released when the epoch rolls. A fake processor scripts the
## delivery outcome so the loop runs without network or sleeps.

type FakeSendProcessor = ref object of BaseSendProcessor
  calls: int
  script: seq[DeliveryState]
    ## State to stamp on the task per invocation; the last entry repeats.

method process(self: FakeSendProcessor, task: DeliveryTask): Future[void] {.async.} =
  let outcome = self.script[min(self.calls, self.script.high)]
  inc self.calls
  task.state = outcome
  if outcome == DeliveryState.SuccessfullyPropagated and
      task.firstPropagatedTime.isNone():
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

proc fixedEpochQuota(epoch: ptr uint64, userMessageLimit: uint64): QuotaProvider =
  ## Quota pinned to whatever `epoch` holds, so a test rolls the epoch by
  ## writing through the pointer.
  return proc(): Opt[EpochQuota] {.gcsafe, raises: [].} =
    return Opt.some(EpochQuota(epochIndex: epoch[], userMessageLimit: userMessageLimit))

suite "SendService - rate-limit scheduling":
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")

  asyncTeardown:
    ## The node is never started, so stop is best-effort cleanup.
    discard await waku.stop()

  proc buildTask(id, payload: string): DeliveryTask =
    ## Built directly rather than via `DeliveryTask.new`, which needs a broker
    ## provider only registered once the node starts.
    let msg = WakuMessage(
      contentTopic: "/test/1/scheduler/proto",
      payload: payload.toBytes(),
      timestamp: 1_700_000_000_000_000_000,
    )
    let pubsubTopic = PubsubTopic("/waku/2/rs/3/0")
    return DeliveryTask(
      requestId: RequestId(id),
      pubsubTopic: pubsubTopic,
      msg: msg,
      msgHash: computeMessageHash(pubsubTopic, msg),
      state: DeliveryState.Entry,
    )

  asyncTest "a task is charged once even when delivery takes several rounds":
    ## First round fails to propagate, second succeeds. The retry must not draw a
    ## second slot: `firstAdmittedTime` guards re-admission.
    var epoch = 5'u64
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 3),
        fixedEpochQuota(addr epoch, userMessageLimit = 100),
      )
      .expect("RateLimitManager.new")
    let processor = FakeSendProcessor(
      script: @[DeliveryState.NextRoundRetry, DeliveryState.SuccessfullyPropagated]
    )
    let service =
      SendService.new(false, waku, manager, processor).expect("SendService.new")

    let task = buildTask("charge-once", "hi")
    await service.send(task)
    check:
      manager.sentInCurrentEpoch == 1'u64
      task.firstAdmittedTime.isSome()
      task.state == DeliveryState.NextRoundRetry

    await service.trySendMessages()
    check:
      manager.sentInCurrentEpoch == 1'u64 # not re-charged on retry
      processor.calls == 2
      task.state == DeliveryState.SuccessfullyPropagated

  asyncTest "an over-budget task is parked, then released when the epoch rolls":
    ## Budget of one per epoch. The second send is parked until the epoch rolls,
    ## then admitted and delivered.
    var epoch = 1'u64
    let manager = RateLimitManager
      .new(
        RateLimitConfig(enabled: true, epochPeriodSec: 600, messagesPerEpoch: 1),
        fixedEpochQuota(addr epoch, userMessageLimit = 100),
      )
      .expect("RateLimitManager.new")
    let processor = FakeSendProcessor(script: @[DeliveryState.SuccessfullyPropagated])
    let service =
      SendService.new(false, waku, manager, processor).expect("SendService.new")

    let first = buildTask("in-budget", "one")
    await service.send(first)
    check:
      first.state == DeliveryState.SuccessfullyPropagated
      manager.sentInCurrentEpoch == 1'u64

    let second = buildTask("over-budget", "two")
    await service.send(second)
    check:
      second.state == DeliveryState.NextRoundRetry # parked
      second.firstAdmittedTime.isNone() # never admitted
    let callsWhenParked = processor.calls

    # Same epoch: still over budget, so the parked task is not handed to the
    # processor.
    await service.trySendMessages()
    check:
      second.state == DeliveryState.NextRoundRetry
      second.firstAdmittedTime.isNone()
      processor.calls == callsWhenParked

    # Epoch rolls: budget refills, the parked task is admitted and delivered.
    epoch = 2'u64
    await service.trySendMessages()
    check:
      second.firstAdmittedTime.isSome()
      second.state == DeliveryState.SuccessfullyPropagated

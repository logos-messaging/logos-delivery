{.used.}

import chronos, chronicles, testutils/unittests, results, stew/byteutils

import
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_relay,
  logos_delivery/waku/waku_lightpush/common,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/messaging/delivery_service/send_service/
    [send_processor, relay_processor, delivery_task]
import ../testlib/[futures, testasync, wakunodeconf]

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

proc newTask(id: string): DeliveryTask =
  let pubsubTopic = PubsubTopic("/waku/2/rs/3/0")
  let msg = WakuMessage(
    contentTopic: "/test/1/send-processors/proto",
    payload: id.toBytes(),
    timestamp: getNowInNanosecondTime(),
  )
  return DeliveryTask(
    pubsubTopic: pubsubTopic,
    msg: msg,
    msgHash: computeMessageHash(pubsubTopic, msg),
    state: DeliveryState.Entry,
  )

suite "Send processors - a message that the relay has":
  var waku {.threadvar.}: Waku

  asyncSetup:
    waku = (await Waku.new(testConf())).expect("Waku.new")

  asyncTeardown:
    discard await waku.stop()

  asyncTest "a relay attempt that gets a duplicate answer propagates the task":
    proc duplicatePublish(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      return mapPubishingErrorToPushResult(
        PublishOutcome.DuplicateMessage, int(DefaultMaxWakuMessageSize)
      )

    let processor =
      RelaySendProcessor.new(false, duplicatePublish, waku, waku.brokerCtx)
    let plain = newTask("plain")
    let anonymized = newTask("anonymized")
    anonymized.anonymized = true
    for task in [plain, anonymized]:
      check await processor.process(task).withTimeout(FUTURE_TIMEOUT_MEDIUM)
    check:
      plain.state == DeliveryState.SuccessfullyPropagated
      plain.firstPropagatedTime.isSome()
      not plain.propagatedAnonymously
      anonymized.state == DeliveryState.SuccessfullyPropagated
      anonymized.propagatedAnonymously

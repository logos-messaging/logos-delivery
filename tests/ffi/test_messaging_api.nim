{.used.}

import chronos, results, testutils/unittests
import brokers/broker_context
import
  logos_delivery,
  library/logos_delivery_api/messaging_api,
  ../testlib/[wakucore, wakunodeconf, nim_main_stub]

suite "logosdelivery_subscribe":
  asyncTest "the subscribe event carries the start time and 0 means none":
    ## A C caller cannot leave out a parameter.
    var conf = defaultTestWakuNodeConf()
    conf.quicSupport = false # the close of its transport takes 300 ms
    var delivery: LogosDelivery
    lockNewGlobalBrokerContext:
      delivery =
        (await LogosDelivery.new(testNodeConf(conf))).expect("LogosDelivery.new")
      (await delivery.start()).expect("start")
    defer:
      (await delivery.stop()).expect("stop")
    var startTimes: seq[Opt[Timestamp]]
    let onSubscribed = proc(
        event: ContentTopicSubscribedEvent
    ): Future[void] {.async: (raises: []), gcsafe.} =
      startTimes.add(event.startTime)
    let listener = ContentTopicSubscribedEvent
      .listen(delivery.waku.brokerCtx, onSubscribed)
      .expect("listen")
    defer:
      await ContentTopicSubscribedEvent.dropListener(delivery.waku.brokerCtx, listener)

    let
      hourAgo = now() - chronos.hours(1).nanos
      withZero = await delivery.logosdelivery_subscribe("/ffi/1/zero/proto", 0)
      withTime = await delivery.logosdelivery_subscribe("/ffi/1/time/proto", hourAgo)
    check:
      withZero.isOk()
      withTime.isOk()
      startTimes == @[Opt.none(Timestamp), Opt.some(hourAgo)]

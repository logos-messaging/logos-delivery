{.used.}

import results, chronos, testutils/unittests

import
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_archive/archive,
  logos_delivery/waku/rln/rln_evm/constants,
  logos_delivery/messaging/delivery_service/send_service/[delivery_task, send_service]

const
  Window = chronos.seconds(20)
  SecondNs = 1_000_000_000'i64

proc taskWith(secondsOld: int64, propagated = Opt.none(Moment)): DeliveryTask =
  ## A task whose message has a timestamp `secondsOld` seconds before the clock.
  ## A negative value gives a timestamp ahead of the clock.
  return DeliveryTask(
    msg: WakuMessage(timestamp: getNowInNanosecondTime() - secondsOld * SecondNs),
    firstPropagatedTime: propagated,
  )

suite "DeliveryTask - delivery window":
  test "the delivery window is the timestamp bound of Store and of the RLN validator":
    check:
      DeliveryWindow == chronos.nanoseconds(MaxMessageTimestampVariance)
      DeliveryWindow.seconds == int64(MaxClockGapSeconds)
      MixShare + MixShare == DeliveryWindow

  test "a message that never propagated times out after the window":
    check taskWith(21).isDeliveryTimedOut(Window)

  test "a message within the window does not time out":
    check not taskWith(19).isDeliveryTimedOut(Window)

  test "a propagated message does not time out, because the Store wait owns it":
    check not taskWith(120, Opt.some(Moment.now())).isDeliveryTimedOut(Window)

  test "a timestamp ahead of the clock also counts":
    ## A validator refuses a timestamp that is too far from its clock, on each side.
    check:
      taskWith(-21).isDeliveryTimedOut(Window)
      not taskWith(-19).isDeliveryTimedOut(Window)
      taskWith(-21).age() > Window

{.used.}

import results, chronos, testutils/unittests

import
  logos_delivery/waku/waku_core/time,
  logos_delivery/waku/waku_core/message/message,
  logos_delivery/messaging/delivery_service/send_service/delivery_task

const Window = chronos.seconds(15)

proc taskWith(age: Duration, propagated: Opt[Moment]): DeliveryTask =
  ## Builds a DeliveryTask directly (bypassing `new`, which needs a broker), with
  ## a message stamped `age` ago.
  let timestamp = getNowInNanosecondTime() - age.nanoseconds()
  return DeliveryTask(
    msg: WakuMessage(timestamp: timestamp),
    firstAdmittedTime: Opt.some(Moment.now()),
    firstPropagatedTime: propagated,
  )

suite "DeliveryTask - delivery-timeout reaping":
  test "a never-propagated message older than the window times out":
    let task = taskWith(chronos.seconds(20), Opt.none(Moment))
    check task.isDeliveryTimedOut(Window)

  test "a message still within the window does not time out":
    let task = taskWith(chronos.seconds(1), Opt.none(Moment))
    check not task.isDeliveryTimedOut(Window)

  test "a propagated task is never timed out here (store validation owns it)":
    let task = taskWith(chronos.seconds(20), Opt.some(Moment.now()))
    check not task.isDeliveryTimedOut(Window)

  test "a timestamp ahead of the clock also counts":
    ## A step back of the wall clock puts the timestamp ahead of the clock.
    check:
      taskWith(chronos.seconds(-20), Opt.none(Moment)).isDeliveryTimedOut(Window)
      not taskWith(chronos.seconds(-1), Opt.none(Moment)).isDeliveryTimedOut(Window)

  test "the window runs from the message timestamp, not the admission":
    ## A charge just now does not give an old message a fresh window: Store and
    ## RLN validators judge the message by its timestamp.
    let task = taskWith(chronos.seconds(20), Opt.none(Moment))
    check task.admissionAge() < Window
    check task.isDeliveryTimedOut(Window)

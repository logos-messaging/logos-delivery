{.used.}

import results, chronos, testutils/unittests

import logos_delivery/messaging/delivery_service/send_service/delivery_task

const MaxTime = chronos.minutes(1)

proc taskWith(admitted, propagated: Opt[Moment]): DeliveryTask =
  ## Builds a DeliveryTask directly (bypassing `new`, which needs a broker).
  return DeliveryTask(firstAdmittedTime: admitted, firstPropagatedTime: propagated)

suite "DeliveryTask - delivery-timeout reaping":
  test "a task parked for budget (never admitted) is exempt, however old":
    ## Budget-parked tasks must survive to the epoch roll, not be aged out.
    let task = taskWith(Opt.none(Moment), Opt.none(Moment))
    check not task.isDeliveryTimedOut(MaxTime)

  test "an admitted, never-propagated task past the window times out":
    let task = taskWith(Opt.some(Moment.now() - chronos.minutes(2)), Opt.none(Moment))
    check task.isDeliveryTimedOut(MaxTime)

  test "an admitted task still within the window does not time out":
    let task = taskWith(Opt.some(Moment.now()), Opt.none(Moment))
    check not task.isDeliveryTimedOut(MaxTime)

  test "a propagated task is never timed out here (store validation owns it)":
    let task =
      taskWith(Opt.some(Moment.now() - chronos.minutes(2)), Opt.some(Moment.now()))
    check not task.isDeliveryTimedOut(MaxTime)

  test "the timeout clock runs from admission, not message creation":
    ## A just-admitted task has a fresh clock, even after a long budget wait.
    let task = taskWith(Opt.some(Moment.now()), Opt.none(Moment))
    check task.admissionAge() < MaxTime
    check not task.isDeliveryTimedOut(MaxTime)

{.used.}

import results, chronos, testutils/unittests

import logos_delivery/messaging/delivery_service/send_service/delivery_task

const MaxTime = chronos.minutes(1)

proc taskWith(admitted, propagated: Opt[Moment]): DeliveryTask =
  ## Builds a DeliveryTask directly (bypassing `new`, which needs a broker) with
  ## only the fields the reaping predicate reads.
  DeliveryTask(firstAdmittedTime: admitted, firstPropagatedTime: propagated)

suite "DeliveryTask - delivery-timeout reaping":
  test "a task parked for budget (never admitted) is exempt, however old":
    ## The #4049 fix: budget-parked tasks must survive to the epoch roll instead
    ## of being aged out with a misleading failure.
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
    ## A task that waited a long time for budget then just got admitted has a
    ## fresh clock — it is not reaped immediately on admission.
    let task = taskWith(Opt.some(Moment.now()), Opt.none(Moment))
    check task.admissionAge() < MaxTime
    check not task.isDeliveryTimedOut(MaxTime)

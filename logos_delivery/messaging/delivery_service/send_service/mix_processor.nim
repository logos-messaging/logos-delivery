import chronicles, chronos, results, brokers/broker_context
import logos_delivery/waku/waku_core, logos_delivery/waku/waku
import logos_delivery/waku/api/[health, publish]
import logos_delivery/api/conf/modes

import ./[delivery_task, send_processor]

export mix_readiness

logScope:
  topics = "send service mix processor"

const MixTooLargeReason* = "message too large for mix"
  ## One mix message carries much less than the plain path.

const MixRetryInterval* = chronos.seconds(5)
  ## The least time between the starts of two mix attempts of a task. With Mix RLN,
  ## each attempt makes a proof, also one that fails at once, for example because
  ## the first hop refuses the dial. The value is that of `MixReplyTimeout`, the
  ## limit of an attempt with no reply.

const MixUnusableGrace* = chronos.seconds(3)
  ## How long after its message timestamp a `Required` task waits for a mounted
  ## mix that cannot attempt it. Retries come `RetryInterval` apart.

type MixSendProcessor* = ref object of BaseSendProcessor
  waku: Waku
  fallbackAllowed: bool
  mixWindow: timer.Duration
  fellBackReason: MixUnusable
    ## Why mix could not carry a `Preferred` task at the last `mixUnusable` check.
    ## It is `None` once mix can carry a task again, and INFO logs each change.

proc fellBackFor*(self: MixSendProcessor): MixUnusable =
  ## Why mix could not carry a `Preferred` task at the last `mixUnusable` check.
  ## It is `None` once mix can carry a task again.
  self.fellBackReason

proc new*(
    T: typedesc[MixSendProcessor],
    waku: Waku,
    brokerCtx: BrokerContext,
    anonymityLevel: AnonymityLevel,
    mixWindow: timer.Duration,
): T =
  return T(
    waku: waku,
    brokerCtx: brokerCtx,
    fallbackAllowed: anonymityLevel == AnonymityLevel.Preferred,
    mixWindow: mixWindow,
  )

method isValidProcessor*(self: MixSendProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

proc mixWindowElapsed(self: MixSendProcessor, task: DeliveryTask): bool =
  ## True once `task` has spent its whole mix window, which bounds failed mix
  ## attempts at either level. The window runs from the message timestamp, as
  ## the delivery window does, so a new RLN proof does not start it again.
  return task.messageAge() > self.mixWindow

proc mixAttemptDue(task: DeliveryTask): bool =
  ## True when no mix attempt of `task` started in the last `MixRetryInterval`.
  return
    task.lastMixAttemptTime.isNone() or
    Moment.now() - task.lastMixAttemptTime.get() >= MixRetryInterval

proc mixUnusable(self: MixSendProcessor, task: DeliveryTask): MixUnusable =
  ## Why mix cannot attempt `task` now, with no network call. The exit must serve
  ## the shard of the message, so `lightpushPublishToAny(mixify = true)` looks for
  ## it in the same way.
  let unusable = self.waku.mixUnusable()
  if unusable != MixUnusable.None:
    return unusable
  if self.waku.selectMixLightpushPeer(task.pubsubTopic).isNone():
    return MixUnusable.NoExit
  return MixUnusable.None

proc decideWithoutMix(
    self: MixSendProcessor, task: DeliveryTask, unusable: MixUnusable
) =
  ## Hands a `Preferred` task to the plain path at once. Fails a `Required` task
  ## with the reason, once its message is older than `MixUnusableGrace` while
  ## mix is mounted.
  if not self.fallbackAllowed:
    if unusable != MixUnusable.NotMounted and task.messageAge() <= MixUnusableGrace:
      task.errorDesc = unusable.reason()
      task.state = DeliveryState.NextRoundRetry
      return
    debug "Mix cannot attempt the task, and the Required anonymity level allows no send without mix",
      msgHash = task.msgHash.to0xHex(), reason = unusable.reason()
    task.state = DeliveryState.FailedToDeliver
    task.errorDesc = unusable.reason()
    return

  if self.fellBackReason != unusable:
    self.fellBackReason = unusable
    info "Mix cannot carry messages, sending them over the plain path instead",
      reason = unusable.reason()
  debug "Mix cannot attempt the task, handing it to the plain send path",
    msgHash = task.msgHash.to0xHex(), reason = unusable.reason()
  task.errorDesc = "" # the plain path reports its own outcome
  task.state = DeliveryState.FallbackRetry

proc decideTooLarge(self: MixSendProcessor, task: DeliveryTask, size, limit: int) =
  ## Fails a `Required` task at once, because no later pass can make the message
  ## fit. Hands a `Preferred` task to the plain path at once.
  if not self.fallbackAllowed:
    debug "Message too large for mix, failing the task",
      msgHash = task.msgHash.to0xHex(), size, limit
    task.state = DeliveryState.FailedToDeliver
    task.errorDesc =
      MixTooLargeReason & ": the request has: " & $size & " bytes, the limit is: " &
      $limit & " bytes"
    return
  debug "Message too large for mix, handing it to the plain send path",
    msgHash = task.msgHash.to0xHex(), size, limit
  task.errorDesc = "" # the plain path reports its own outcome
  task.state = DeliveryState.FallbackRetry

method checkBeforeSend*(
    self: MixSendProcessor, task: DeliveryTask
): Result[void, SendError] {.gcsafe, raises: [].} =
  ## Refuses a `Required` message that one mix message cannot hold.
  if self.fallbackAllowed:
    return ok()
  let message = self.waku.messageForSizeCheck(task.msg).valueOr:
    return err(
      SendError.init(
        SendErrorKind.TooLarge, "failed to determine the RLN proof size: " & $error
      )
    )
  let (size, limit) = self.waku.mixLightpushSize(task.pubsubTopic, message)
  if size > limit:
    return err(
      SendError.init(
        SendErrorKind.TooLarge,
        MixTooLargeReason & ": the request has: " & $size & " bytes, the limit is: " &
          $limit & " bytes",
      )
    )
  return ok()

method sendImpl*(self: MixSendProcessor, task: DeliveryTask): Future[void] {.async.} =
  if self.fallbackAllowed and task.deanonymized:
    debug "A plain attempt may have sent the message, so the task stays on the plain send path",
      msgHash = task.msgHash.to0xHex()
    task.errorDesc = ""
    task.state = DeliveryState.FallbackRetry
    return

  # No wait can make the message fit, so check the size before the reasons that
  # a wait can clear. A task that is too large has no mix attempt, so it must not
  # get the `anonymized` mark.
  let (size, limit) = self.waku.mixLightpushSize(task.pubsubTopic, task.msg)
  if size > limit:
    self.decideTooLarge(task, size, limit)
    return

  # Check the reasons before the window, so that the hand-over of a task that
  # mix cannot attempt logs its reason at INFO.
  let unusable = self.mixUnusable(task)
  if unusable != MixUnusable.None:
    self.decideWithoutMix(task, unusable)
    return

  if self.fellBackReason != MixUnusable.None:
    self.fellBackReason = MixUnusable.None
    info "Mix can carry messages again"

  if self.fallbackAllowed and self.mixWindowElapsed(task):
    debug "Mix window elapsed, handing the task to the plain send path",
      msgHash = task.msgHash.to0xHex(), messageAge = task.messageAge()
    task.errorDesc = ""
    task.state = DeliveryState.FallbackRetry
    return

  if not task.mixAttemptDue():
    task.state = DeliveryState.NextRoundRetry
    return
  task.lastMixAttemptTime = Opt.some(Moment.now())

  # Mark before the attempt: the exit publishes before it replies, so a message
  # whose reply is lost is still on the network. From here on, the send service
  # logs no hash for this task at INFO or ERROR.
  task.anonymized = true

  task.errorDesc = "" # the attempt reports its own outcome
  task.tryCount.inc()
  debug "Trying message delivery via Mix",
    msgHash = task.msgHash.to0xHex(), tryCount = task.tryCount

  let numLightpushServers = (
    await self.waku.lightpushPublishToAny(task.pubsubTopic, task.msg, mixify = true)
  ).valueOr:
    debug "MixSendProcessor.sendImpl failed", error = error.desc.get($error.code)

    if error.isRlnRejection():
      task.parkForRlnProofRefresh(self.waku, error)
      return

    case error.code
    of LightPushErrorCode.NO_PEERS_TO_RELAY, LightPushErrorCode.TOO_MANY_REQUESTS,
        LightPushErrorCode.OUT_OF_RLN_PROOF, LightPushErrorCode.SERVICE_NOT_AVAILABLE,
        LightPushErrorCode.INTERNAL_SERVER_ERROR:
      task.state = DeliveryState.NextRoundRetry
    else:
      task.state = DeliveryState.FailedToDeliver
      task.errorDesc = error.desc.get($error.code)
    return

  if numLightpushServers > 0:
    debug "Message propagated via Mix", msgHash = task.msgHash.to0xHex()
    task.state = DeliveryState.SuccessfullyPropagated
    task.propagatedAnonymously = true
    if task.firstPropagatedTime.isNone():
      task.firstPropagatedTime = Opt.some(Moment.now())
  else:
    debug "Mix publish returned zero peers, the task waits for a retry",
      msgHash = task.loggedHash()
    task.state = DeliveryState.NextRoundRetry

  return

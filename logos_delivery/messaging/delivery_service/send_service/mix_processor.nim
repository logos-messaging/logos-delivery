import chronicles, chronos, results, brokers/broker_context
import logos_delivery/waku/waku_core, logos_delivery/waku/waku
import logos_delivery/waku/api/publish
import logos_delivery/waku/waku_mix
import logos_delivery/api/conf/modes

import ./[delivery_task, send_processor]

logScope:
  topics = "send service mix processor"

const MixUnavailableReason* = "mix not mounted or pool below: " & $MinMixPoolSize
  ## The pool counts only members with an address that mix routes.

const MixSelfHopReason* = "own address cannot carry mix replies"
  ## An IPv6-only or name-only announcement, or a NAT mapping not yet arrived.

const MixNoExitReason* = "no mix exit serves the shard"
  ## No pool member serves lightpush on the message's shard.

const MixUnusableRetries* = 2
  ## Service passes a `Required` task waits for a mounted mix before it fails.

type
  MixUnusable* {.pure.} = enum
    ## Why mix cannot attempt a task now.
    None
    Unavailable
    SelfHop
    NoExit

  MixSendProcessor* = ref object of BaseSendProcessor
    waku: Waku
    fallbackAllowed: bool
    mixWindow: timer.Duration
    fellBackReason: MixUnusable
      ## Why the last task went to the plain path; `None` once mix can attempt
      ## a task again. INFO logs each change.

proc reason*(unusable: MixUnusable): string =
  ## The text written to `errorDesc` and the log lines.
  case unusable
  of MixUnusable.None: ""
  of MixUnusable.Unavailable: MixUnavailableReason
  of MixUnusable.SelfHop: MixSelfHopReason
  of MixUnusable.NoExit: MixNoExitReason

proc fellBackFor*(self: MixSendProcessor): MixUnusable =
  ## Why the last task went to the plain path, or `None` once mix can attempt a
  ## task again.
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
  ## attempts at either level.
  return task.admissionAge() > self.mixWindow

proc mixUnusable(self: MixSendProcessor, task: DeliveryTask): MixUnusable =
  ## Why mix cannot attempt `task` now, with no network call. It splits
  ## `mixReady()` into the self hop and the pool, then checks the exit with
  ## `selectMixLightpushPeer`, as `lightpushPublishToAny(mixify = true)` does.
  if not self.waku.mixReady():
    if self.waku.mixMounted() and not self.waku.mixSelfHopUsable():
      return MixUnusable.SelfHop
    return MixUnusable.Unavailable
  if self.waku.selectMixLightpushPeer(task.pubsubTopic).isNone():
    return MixUnusable.NoExit
  return MixUnusable.None

proc decideWithoutMix(
    self: MixSendProcessor, task: DeliveryTask, unusable: MixUnusable
) =
  ## Hands a `Preferred` task to the plain path at once. Fails a `Required` task
  ## with the reason, after `MixUnusableRetries` more passes while mix is mounted.
  if not self.fallbackAllowed:
    if self.waku.mixMounted() and task.heldRounds < MixUnusableRetries:
      inc task.heldRounds
      task.errorDesc = unusable.reason()
      task.state = DeliveryState.NextRoundRetry
      return
    debug "Mix cannot attempt the task, and the level has no other send path",
      requestId = task.requestId,
      msgHash = task.msgHash.to0xHex(),
      reason = unusable.reason()
    task.state = DeliveryState.FailedToDeliver
    task.errorDesc = unusable.reason()
    task.deliveryTime = Moment.now()
    return

  if self.fellBackReason != unusable:
    self.fellBackReason = unusable
    info "Mix cannot carry messages, sending them over the plain path instead",
      reason = unusable.reason()
  debug "Mix cannot attempt the task, handing it to the plain send path",
    requestId = task.requestId,
    msgHash = task.msgHash.to0xHex(),
    reason = unusable.reason()
  task.errorDesc = "" # the plain path reports its own outcome
  task.state = DeliveryState.FallbackRetry

method sendImpl*(self: MixSendProcessor, task: DeliveryTask): Future[void] {.async.} =
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
    debug "Mix window elapsed",
      requestId = task.requestId,
      msgHash = task.msgHash.to0xHex(),
      admissionAge = task.admissionAge()
    task.errorDesc = ""
    task.state = DeliveryState.FallbackRetry
    return

  # Mark before the attempt: the exit publishes before it replies, so a message
  # whose reply is lost is still on the network. From here on, the send service
  # logs no hash for this task at INFO or ERROR.
  task.anonymized = true

  task.errorDesc = "" # the attempt reports its own outcome
  task.heldRounds = 0
  task.tryCount.inc()
  debug "Trying message delivery via Mix",
    requestId = task.requestId,
    msgHash = task.msgHash.to0xHex(),
    tryCount = task.tryCount

  let numLightpushServers = (
    await self.waku.lightpushPublishToAny(task.pubsubTopic, task.msg, mixify = true)
  ).valueOr:
    debug "MixSendProcessor.sendImpl failed", error = error.desc.get($error.code)

    if error.isRlnRejection():
      task.parkForRlnProofRefresh(self.waku)
      return

    case error.code
    of LightPushErrorCode.NO_PEERS_TO_RELAY, LightPushErrorCode.TOO_MANY_REQUESTS,
        LightPushErrorCode.OUT_OF_RLN_PROOF, LightPushErrorCode.SERVICE_NOT_AVAILABLE,
        LightPushErrorCode.INTERNAL_SERVER_ERROR:
      task.state = DeliveryState.NextRoundRetry
    else:
      task.state = DeliveryState.FailedToDeliver
      task.errorDesc = error.desc.get($error.code)
      task.deliveryTime = Moment.now()
    return

  if numLightpushServers > 0:
    debug "Message propagated via Mix",
      requestId = task.requestId, msgHash = task.msgHash.to0xHex()
    task.state = DeliveryState.SuccessfullyPropagated
    task.propagatedAnonymously = true
    task.deliveryTime = Moment.now()
    if task.firstPropagatedTime.isNone():
      task.firstPropagatedTime = Opt.some(Moment.now())
  else:
    debug "Mix publish returned zero peers, request pushed back for next round",
      requestId = task.requestId
    task.state = DeliveryState.NextRoundRetry

  return

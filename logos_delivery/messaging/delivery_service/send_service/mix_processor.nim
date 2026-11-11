import chronicles, chronos, results, brokers/broker_context
import logos_delivery/waku/waku_core, logos_delivery/waku/waku
import logos_delivery/waku/api/publish
import logos_delivery/waku/waku_mix
import logos_delivery/api/conf/modes
import logos_delivery/api/types

import ./[delivery_task, send_processor]

logScope:
  topics = "send service mix processor"

const MixUnavailableReason* =
  "mix is not mounted or knows fewer than " & $MinMixPoolSize & " usable mix nodes"
  ## The pool counts only members with an address that mix routes.

const MixSelfHopReason* = "this node has no address that mix can use for replies"
  ## An IPv6-only or name-only announcement, or a NAT mapping not yet arrived.

const MixNoExitReason* = "no mix node serves lightpush on the shard of the message"
  ## No pool member serves lightpush on the message's shard.

const MixTooLargeReason* = "message too large for mix"
  ## One mix message carries much less than the plain path.

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
): T =
  return T(
    waku: waku,
    brokerCtx: brokerCtx,
    fallbackAllowed: anonymityLevel == AnonymityLevel.Preferred,
  )

method isValidProcessor*(self: MixSendProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

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

method hasSendPeer*(
    self: MixSendProcessor, task: DeliveryTask
): bool {.gcsafe, raises: [].} =
  return self.mixUnusable(task) == MixUnusable.None

method noSendPeerReason*(
    self: MixSendProcessor, task: DeliveryTask
): string {.gcsafe, raises: [].} =
  if self.fallbackAllowed:
    return ""
  return self.mixUnusable(task).reason()

proc decideWithoutMix(
    self: MixSendProcessor, task: DeliveryTask, unusable: MixUnusable
) =
  if not self.fallbackAllowed:
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
  task.state = DeliveryState.Fallback

func tooLargeDesc(size, limit: int): string =
  return
    MixTooLargeReason & ": the request has " & $size & " bytes, the limit is " & $limit &
    " bytes"

proc decideTooLarge(self: MixSendProcessor, task: DeliveryTask, size, limit: int) =
  if not self.fallbackAllowed:
    debug "Message too large for mix, failing the task",
      msgHash = task.msgHash.to0xHex(), size, limit
    task.state = DeliveryState.FailedToDeliver
    task.errorDesc = tooLargeDesc(size, limit)
    return
  debug "Message too large for mix, handing it to the plain send path",
    msgHash = task.msgHash.to0xHex(), size, limit
  task.state = DeliveryState.Fallback

method checkBeforeAdmission*(
    self: MixSendProcessor, task: DeliveryTask
): Result[void, SendError] {.gcsafe, raises: [].} =
  ## Refuses a `Required` task that is too large for mix.
  ## A `Preferred` task that is too large goes to the plain path.
  if self.fallbackAllowed:
    return ok()
  let message = self.waku.messageForSizeCheck(task.msg).valueOr:
    return err(
      SendError.init(
        SendErrorKind.Other, "Failed to determine RLN proof size: " & $error
      )
    )
  let (size, limit) = self.waku.mixLightpushSize(task.pubsubTopic, message)
  if size > limit:
    return err(SendError.init(SendErrorKind.TooLarge, tooLargeDesc(size, limit)))
  return ok()

method sendImpl*(self: MixSendProcessor, task: DeliveryTask): Future[void] {.async.} =
  # A task that is too large has no mix attempt.
  # So it must not get the `anonymized` mark.
  let (size, limit) = self.waku.mixLightpushSize(task.pubsubTopic, task.msg)
  if size > limit:
    self.decideTooLarge(task, size, limit)
    return

  let unusable = self.mixUnusable(task)
  if unusable != MixUnusable.None:
    self.decideWithoutMix(task, unusable)
    return

  if self.fellBackReason != MixUnusable.None:
    self.fellBackReason = MixUnusable.None
    info "Mix can carry messages again"

  # Mark before the attempt: the exit publishes before it replies, so a message
  # whose reply is lost is still on the network. From here on, the send service
  # logs no hash for this task at INFO or ERROR.
  task.anonymized = true

  task.tryCount.inc()
  debug "Trying message delivery via Mix",
    msgHash = task.msgHash.to0xHex(), tryCount = task.tryCount

  let numLightpushServers = (
    await self.waku.lightpushPublishToAny(task.pubsubTopic, task.msg, mixify = true)
  ).valueOr:
    debug "MixSendProcessor.sendImpl failed", error = error.sendErrorDesc()

    if error.isRlnRejection():
      task.failRlnRejected(self.waku, error.sendErrorDesc())
      return

    # The exit can publish the message and its reply can get lost.
    # So the task does not go to the plain path after a mix attempt.
    task.state = DeliveryState.FailedToDeliver
    task.errorDesc = error.sendErrorDesc()
    return

  if numLightpushServers > 0:
    debug "Message propagated via Mix", msgHash = task.msgHash.to0xHex()
    task.state = DeliveryState.SuccessfullyPropagated
    task.propagatedAnonymously = true
    task.firstPropagatedTime = Opt.some(Moment.now())
  else:
    debug "Mix publish returned zero peers", msgHash = task.msgHash.to0xHex()
    task.state = DeliveryState.FailedToDeliver
    task.errorDesc = NoSendPeerReason

  return

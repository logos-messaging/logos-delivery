import chronicles, chronos, results, brokers/broker_context
import logos_delivery/waku/waku_core, logos_delivery/waku/waku
import logos_delivery/waku/api/publish
import logos_delivery/waku/waku_mix

import ./[delivery_task, delivery_plan, send_processor]

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

const MixUnusableGrace* = chronos.seconds(3)
  ## How long after its admission a `Required` task waits for a mounted mix that
  ## cannot attempt it. Retries come `RetryInterval` apart.

type MixSendProcessor* = ref object of BaseSendProcessor
  waku: Waku

proc new*(T: typedesc[MixSendProcessor], waku: Waku, brokerCtx: BrokerContext): T =
  return T(waku: waku, brokerCtx: brokerCtx)

func sizeDesc(size, limit: int): string =
  "the request has " & $size & " bytes, the limit is " & $limit & " bytes"

proc checkSize(
    self: MixSendProcessor, task: DeliveryTask, message: WakuMessage
): Result[void, StepReport] =
  let (size, limit) = self.waku.mixLightpushSize(task.pubsubTopic, message)
  if size <= limit:
    return ok()
  debug "Message too large for mix",
    requestId = task.requestId, msgHash = task.msgHash.to0xHex(), size, limit
  return err(StepReport.init(Trigger.TooLargeForMix, sizeDesc(size, limit)))

proc checkUsable(self: MixSendProcessor, task: DeliveryTask): Result[void, StepReport] =
  ## Refuses a mix that cannot attempt `task` now, with no network call. It splits
  ## `mixReady()` into the self hop and the pool, then checks the exit with
  ## `selectMixLightpushPeer`, as `lightpushPublishToAny(mixify = true)` does.
  if not self.waku.mixMounted():
    return err(StepReport.init(Trigger.MixNotMounted))
  if not self.waku.mixReady():
    if not self.waku.mixSelfHopUsable():
      return err(StepReport.init(Trigger.MixSelfHop))
    return err(StepReport.init(Trigger.MixUnavailable))
  if self.waku.selectMixLightpushPeer(task.pubsubTopic).isNone():
    return err(StepReport.init(Trigger.MixNoExit))
  return ok()

func mixUnusableText*(trigger: Trigger): string =
  ## The text of a trigger for a mix that cannot attempt a task.
  case trigger
  of Trigger.MixSelfHop: MixSelfHopReason
  of Trigger.MixNoExit: MixNoExitReason
  else: MixUnavailableReason

method checkBeforeAdmission*(
    self: MixSendProcessor, task: DeliveryTask
): Result[void, StepReport] {.gcsafe, raises: [].} =
  let message = self.waku.messageForSizeCheck(task.msg).valueOr:
    return err(StepReport.init(Trigger.ProofSizeUnknown, $error))
  return self.checkSize(task, message)

method checkBeforeAttempt*(
    self: MixSendProcessor, task: DeliveryTask
): Result[void, StepReport] {.gcsafe.} =
  # No wait can make the message fit, so the size check comes first.
  ?self.checkSize(task, task.msg)
  return self.checkUsable(task)

method attempt*(
    self: MixSendProcessor, task: DeliveryTask
): Future[StepReport] {.async.} =
  debug "Trying message delivery via Mix",
    requestId = task.requestId,
    msgHash = task.msgHash.to0xHex(),
    tryCount = task.tryCount

  let numLightpushServers = (
    await self.waku.lightpushPublishToAny(task.pubsubTopic, task.msg, mixify = true)
  ).valueOr:
    let failure = lightpushReport(error)
    debug "Mix publish failed",
      requestId = task.requestId, trigger = failure.trigger, error = failure.desc
    return failure

  if numLightpushServers > 0:
    debug "Message propagated via Mix",
      requestId = task.requestId, msgHash = task.msgHash.to0xHex()
  return publishReport(numLightpushServers)

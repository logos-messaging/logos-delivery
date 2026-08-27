import chronicles, chronos, results, brokers/broker_context
import logos_delivery/waku/waku_core, logos_delivery/waku/waku
import logos_delivery/waku/api/publish
import logos_delivery/api/conf/modes

import ./[delivery_task, send_processor]

logScope:
  topics = "send service mix processor"

type MixSendProcessor* = ref object of BaseSendProcessor
  waku: Waku
  fallbackAllowed: bool
  mixWindow: timer.Duration

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
    fallbackAllowed: anonymityLevel == AnonymityLevel.BestEffort,
    mixWindow: mixWindow,
  )

method isValidProcessor*(self: MixSendProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

proc mixWindowElapsed(self: MixSendProcessor, task: DeliveryTask): bool =
  return self.fallbackAllowed and task.mixAge() > self.mixWindow

method sendImpl*(self: MixSendProcessor, task: DeliveryTask): Future[void] {.async.} =
  # Starts the mix window on the first round that reaches this processor, whether
  # or not mix can publish yet: a task that never finds a path must still fall
  # back under `BestEffort`. Never reset afterwards, so a task cycling through
  # RLN proof refreshes cannot keep restarting its own window.
  if task.firstMixTriedTime.isNone():
    task.firstMixTriedTime = Opt.some(Moment.now())

  if self.mixWindowElapsed(task):
    debug "Mix window elapsed, handing the task to the plain send path",
      requestId = task.requestId,
      msgHash = task.msgHash.to0xHex(),
      mixAge = task.mixAge()
    task.state = DeliveryState.FallbackRetry
    return

  if not self.waku.mixReady():
    debug "Mix cannot publish yet (not enough nodes for a path), retrying next round",
      requestId = task.requestId, msgHash = task.msgHash.to0xHex()
    task.state = DeliveryState.NextRoundRetry
    return

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
    task.deliveryTime = Moment.now()
    if task.firstPropagatedTime.isNone():
      task.firstPropagatedTime = Opt.some(Moment.now())
  else:
    debug "Mix publish returned zero peers, request pushed back for next round",
      requestId = task.requestId
    task.state = DeliveryState.NextRoundRetry

  return

import chronicles, chronos, results, brokers/broker_context
import logos_delivery/waku/waku_core, logos_delivery/waku/waku
import logos_delivery/waku/api/publish

import ./[delivery_task, send_processor]

logScope:
  topics = "send service lightpush processor"

type LightpushSendProcessor* = ref object of BaseSendProcessor
  waku: Waku

proc new*(
    T: typedesc[LightpushSendProcessor], waku: Waku, brokerCtx: BrokerContext
): T =
  return T(waku: waku, brokerCtx: brokerCtx)

method isValidProcessor*(
    self: LightpushSendProcessor, task: DeliveryTask
): bool {.gcsafe.} =
  return self.waku.lightpushPeerAvailable(task.pubsubTopic)

method hasSendPeer*(
    self: LightpushSendProcessor, task: DeliveryTask
): bool {.gcsafe, raises: [].} =
  return self.waku.lightpushPeerAvailable(task.pubsubTopic)

method sendImpl*(
    self: LightpushSendProcessor, task: DeliveryTask
): Future[void] {.async.} =
  task.tryCount.inc()
  debug "Trying message delivery via Lightpush",
    msgHash = task.msgHash.to0xHex(), tryCount = task.tryCount

  let numLightpushServers = (
    await self.waku.lightpushPublishToAny(task.pubsubTopic, task.msg)
  ).valueOr:
    error "LightpushSendProcessor.sendImpl failed",
      msgHash = task.msgHash.to0xHex(), error = error.sendErrorDesc()

    if error.isRlnRejection():
      task.failRlnRejected(self.waku, error.sendErrorDesc())
      return

    task.state = DeliveryState.FailedToDeliver
    task.errorDesc = error.sendErrorDesc()
    return

  if numLightpushServers > 0:
    debug "Message propagated via Lightpush", msgHash = task.msgHash.to0xHex()
    task.state = DeliveryState.SuccessfullyPropagated
    task.firstPropagatedTime = Opt.some(Moment.now())
  else:
    # Controversial state, publish says ok but no peer. It should not happen.
    debug "Lightpush publish returned zero peers", msgHash = task.msgHash.to0xHex()
    task.state = DeliveryState.FailedToDeliver
    task.errorDesc = NoSendPeerReason

  return

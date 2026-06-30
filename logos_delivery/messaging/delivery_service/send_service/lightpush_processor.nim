import logos_delivery/waku/compat/option_valueor
import chronicles, chronos, results
import std/options
import brokers/broker_context
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

method sendImpl*(
    self: LightpushSendProcessor, task: DeliveryTask
): Future[void] {.async.} =
  task.tryCount.inc()
  info "Trying message delivery via Lightpush",
    requestId = task.requestId,
    msgHash = task.msgHash.to0xHex(),
    tryCount = task.tryCount

  let numLightpushServers = (
    await self.waku.lightpushPublishToAny(task.pubsubTopic, task.msg)
  ).valueOr:
    error "LightpushSendProcessor.sendImpl failed", error = error.desc.get($error.code)
    case error.code
    of LightPushErrorCode.NO_PEERS_TO_RELAY, LightPushErrorCode.TOO_MANY_REQUESTS,
        LightPushErrorCode.OUT_OF_RLN_PROOF, LightPushErrorCode.SERVICE_NOT_AVAILABLE,
        LightPushErrorCode.INTERNAL_SERVER_ERROR:
      task.state = DeliveryState.NextRoundRetry
    else:
      # the message is malformed, send error
      task.state = DeliveryState.FailedToDeliver
      task.errorDesc = error.desc.get($error.code)
      task.deliveryTime = Moment.now()
    return

  if numLightpushServers > 0:
    info "Message propagated via Lightpush",
      requestId = task.requestId, msgHash = task.msgHash.to0xHex()
    task.state = DeliveryState.SuccessfullyPropagated
    task.deliveryTime = Moment.now()
    if task.firstPropagatedTime.isNone():
      task.firstPropagatedTime = some(Moment.now())
    # TODO: with a simple retry processor it might be more accurate to say `Sent`
  else:
    # Controversial state, publish says ok but no peer. It should not happen.
    debug "Lightpush publish returned zero peers, request pushed back for next round",
      requestId = task.requestId
    task.state = DeliveryState.NextRoundRetry

  return

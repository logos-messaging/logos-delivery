import chronos, chronicles
import std/options
import waku/[waku_node, waku_core], waku/waku_lightpush/[common, callbacks, rpc]
import waku/requests/health_request
import waku/api/types
import ./[delivery_task, send_processor]

logScope:
  topics = "send service relay processor"

type RelaySendProcessor* = ref object of BaseSendProcessor
  publishProc: PushMessageHandler
  fallbackStateToSet: DeliveryState

proc new*(
    T: type RelaySendProcessor,
    lightpushAvailable: bool,
    publishProc: PushMessageHandler,
): RelaySendProcessor =
  let fallbackStateToSet =
    if lightpushAvailable:
      DeliveryState.FallbackRetry
    else:
      DeliveryState.FailedToDeliver

  return
    RelaySendProcessor(publishProc: publishProc, fallbackStateToSet: fallbackStateToSet)

proc isTopicHealthy(topic: PubsubTopic): Future[bool] {.async.} =
  let healthReport = (await RequestRelayTopicsHealth.request(@[topic])).valueOr:
    return false

  if healthReport.topicHealth.len() < 1:
    return false
  let health = healthReport.topicHealth[0].health
  return health == MINIMALLY_HEALTHY or health == SUFFICIENTLY_HEALTHY

method isValidProcessor*(
    self: RelaySendProcessor, task: DeliveryTask
): Future[bool] {.async.} =
  return await isTopicHealthy(task.pubsubTopic)

method sendImpl*(self: RelaySendProcessor, task: DeliveryTask): Future[void] {.async.} =
  task.tryCount.inc()
  info "Trying message delivery via Relay",
    requestId = task.requestId, msgHash = task.msgHash, tryCount = task.tryCount

  let pushResult = await self.publishProc(task.pubsubTopic, task.msg)
  if pushResult.isErr():
    let errorMessage = pushResult.error.desc.get($pushResult.error.code)
    error "Failed to publish message with relay",
      request = task.requestId, msgHash = task.msgHash, error = errorMessage
    if pushResult.error.code != LightPushErrorCode.NO_PEERS_TO_RELAY:
      task.state = DeliveryState.FailedToDeliver
      task.errorDesc = errorMessage
    else:
      task.state = self.fallbackStateToSet
    return

  if pushResult.isOk and pushResult.get() > 0:
    info "Message propagated via Relay",
      requestId = task.requestId, msgHash = task.msgHash
    task.state = DeliveryState.SuccessfullyPropagated
    task.deliveryTime = Moment.now()
  else:
    # It shall not happen, but still covering it
    task.state = self.fallbackStateToSet

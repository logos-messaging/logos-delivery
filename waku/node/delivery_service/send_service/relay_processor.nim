import chronos, chronicles
import std/options
import waku/[waku_core], waku/waku_lightpush/[common, rpc]
import waku/requests/health_request
import waku/common/broker/broker_context
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
    brokerCtx: BrokerContext,
): RelaySendProcessor =
  let fallbackStateToSet =
    if lightpushAvailable:
      DeliveryState.FallbackRetry
    else:
      DeliveryState.FailedToDeliver

  return RelaySendProcessor(
    publishProc: publishProc,
    fallbackStateToSet: fallbackStateToSet,
    brokerCtx: brokerCtx,
  )

proc isTopicHealthy(self: RelaySendProcessor, topic: PubsubTopic): bool {.gcsafe.} =
  let healthReport = RequestRelayTopicsHealth.request(self.brokerCtx, @[topic]).valueOr:
    error "isTopicHealthy: failed to get health report", topic = topic, error = error
    return false

  if healthReport.topicHealth.len() < 1:
    warn "isTopicHealthy: no topic health entries", topic = topic
    return false
  let health = healthReport.topicHealth[0].health
  debug "isTopicHealthy: topic health is ", topic = topic, health = health
  return health == MINIMALLY_HEALTHY or health == SUFFICIENTLY_HEALTHY

method isValidProcessor*(
    self: RelaySendProcessor, task: DeliveryTask
): bool {.gcsafe.} =
  # Topic health query is not reliable enough after a fresh subscribe...
  # return self.isTopicHealthy(task.pubsubTopic)
  return true

method sendImpl*(self: RelaySendProcessor, task: DeliveryTask): Future[void] {.async.} =
  task.tryCount.inc()
  info "Trying message delivery via Relay",
    requestId = task.requestId,
    msgHash = task.msgHash.to0xHex(),
    tryCount = task.tryCount

  let noOfPublishedPeers = (await self.publishProc(task.pubsubTopic, task.msg)).valueOr:
    let errorMessage = error.desc.get($error.code)
    error "Failed to publish message with relay",
      request = task.requestId, msgHash = task.msgHash.to0xHex(), error = errorMessage
    if error.code != LightPushErrorCode.NO_PEERS_TO_RELAY:
      task.state = DeliveryState.FailedToDeliver
      task.errorDesc = errorMessage
    else:
      task.state = self.fallbackStateToSet
    return

  if noOfPublishedPeers > 0:
    info "Message propagated via Relay",
      requestId = task.requestId, msgHash = task.msgHash
    task.state = DeliveryState.SuccessfullyPropagated
    task.deliveryTime = Moment.now()
  else:
    # It shall not happen, but still covering it
    task.state = self.fallbackStateToSet

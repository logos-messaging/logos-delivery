import chronicles, chronos, results

import waku/factory/waku
import waku/[requests/health_request, waku_core, waku_node]
import waku/node/delivery_service/send_service
import waku/node/delivery_service/subscription_service
import ./[api_conf, types]

logScope:
  topics = "api"

# TODO: Specs says it should return a `WakuNode`. As `send` and other APIs are defined, we can align.
proc createNode*(config: NodeConfig): Future[Result[Waku, string]] {.async.} =
  let wakuConf = toWakuConf(config).valueOr:
    return err("Failed to handle the configuration: " & error)

  ## We are not defining app callbacks at node creation
  let wakuRes = (await Waku.new(wakuConf)).valueOr:
    error "waku initialization failed", error = error
    return err("Failed setting up Waku: " & $error)

  return ok(wakuRes)

proc checkApiAvailability(w: Waku): Result[void, string] =
  if w.isNil():
    return err("Waku node is not initialized")

  # check if health is satisfactory
  # If Node is not healthy, return err("Waku node is not healthy")
  let healthStatus = RequestNodeHealth.request(w.brokerCtx)

  if healthStatus.isErr():
    warn "Failed to get Waku node health status: ", error = healthStatus.error
    # Let's suppose the node is hesalthy enough, go ahead
  else:
    if healthStatus.get().healthStatus == NodeHealth.Unhealthy:
      return err("Waku node is not healthy, has got no connections.")

  return ok()

proc subscribe*(
    w: Waku, contentTopic: ContentTopic
): Future[Result[void, string]] {.async.} =
  ?checkApiAvailability(w)

  return w.deliveryService.subscriptionService.subscribe(contentTopic)

proc unsubscribe*(w: Waku, contentTopic: ContentTopic): Result[void, string] =
  ?checkApiAvailability(w)

  return w.deliveryService.subscriptionService.unsubscribe(contentTopic)

proc send*(
    w: Waku, envelope: MessageEnvelope
): Future[Result[RequestId, string]] {.async.} =
  ?checkApiAvailability(w)

  let requestId = RequestId.new(w.rng)

  let deliveryTask = DeliveryTask.create(requestId, envelope, w.brokerCtx).valueOr:
    return err("API send: Failed to create delivery task: " & error)

  info "API send: scheduling delivery task",
    requestId = $requestId,
    pubsubTopic = deliveryTask.pubsubTopic,
    contentTopic = deliveryTask.msg.contentTopic,
    msgHash = deliveryTask.msgHash.shortLog()

  asyncSpawn w.deliveryService.sendService.send(deliveryTask)

  return ok(requestId)

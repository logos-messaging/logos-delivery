import chronicles, chronos, results

import waku/factory/waku
import waku/[requests/health_request, waku_core, waku_node]
import waku/node/delivery_service/send_service
import ./[api_conf, types], ./subscribe/subscribe

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
  let healthStatus = waitFor RequestNodeHealth.request()

  if healthStatus.isErr():
    warn "Failed to get Waku node health status: ", error = healthStatus.error
    # Let's suppose the node is hesalthy enough, go ahead
  else:
    if healthStatus.get().healthStatus != NodeHealth.Unhealthy:
      return err("Waku node is not healthy, has got no connections.")

  return ok()

proc subscribe*(
    w: Waku, contentTopic: ContentTopic
): Future[Result[RequestId, string]] {.async.} =
  ?checkApiAvailability(w)

  let requestId = newRequestId(w.rng)

  asyncSpawn w.subscribeImpl(requestId, contentTopic)

  return ok(requestId)

proc send*(
    w: Waku, envelope: MessageEnvelope
): Future[Result[RequestId, string]] {.async.} =
  ?checkApiAvailability(w)

  let requestId = newRequestId(w.rng)

  let deliveryTask = DeliveryTask.create(requestId, envelope).valueOr:
    return err("Failed to create delivery task: " & error)

  asyncSpawn w.deliveryService.sendService.send(deliveryTask)

  return ok(requestId)

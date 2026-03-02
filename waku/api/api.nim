import chronicles, chronos, results, std/strutils

import waku/factory/waku
import waku/[requests/health_requests, waku_core, waku_node]
import waku/node/delivery_service/send_service
import waku/node/delivery_service/subscription_manager
import libp2p/peerid
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

  # TODO: Conciliate request-bouncing health checks here with unit testing.
  #       (For now, better to just allow all sends and rely on retries.)

  return ok()

proc subscribe*(
    w: Waku, contentTopic: ContentTopic
): Future[Result[void, string]] {.async.} =
  ?checkApiAvailability(w)

  return w.deliveryService.subscriptionManager.subscribe(contentTopic)

proc unsubscribe*(w: Waku, contentTopic: ContentTopic): Result[void, string] =
  ?checkApiAvailability(w)

  return w.deliveryService.subscriptionManager.unsubscribe(contentTopic)

proc send*(
    w: Waku, envelope: MessageEnvelope
): Future[Result[RequestId, string]] {.async.} =
  ?checkApiAvailability(w)

  let isSubbed = w.deliveryService.subscriptionManager
    .isSubscribed(envelope.contentTopic)
    .valueOr(false)
  if not isSubbed:
    info "Auto-subscribing to topic on send", contentTopic = envelope.contentTopic
    w.deliveryService.subscriptionManager.subscribe(envelope.contentTopic).isOkOr:
      warn "Failed to auto-subscribe", error = error
      return err("Failed to auto-subscribe before sending: " & error)

  let requestId = RequestId.new(w.rng)

  let deliveryTask = DeliveryTask.new(requestId, envelope, w.brokerCtx).valueOr:
    return err("API send: Failed to create delivery task: " & error)

  info "API send: scheduling delivery task",
    requestId = $requestId,
    pubsubTopic = deliveryTask.pubsubTopic,
    contentTopic = deliveryTask.msg.contentTopic,
    msgHash = deliveryTask.msgHash.to0xHex(),
    myPeerId = w.node.peerId()

  asyncSpawn w.deliveryService.sendService.send(deliveryTask)

  return ok(requestId)

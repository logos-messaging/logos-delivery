import chronicles, chronos, results

import waku/factory/waku
import messaging/messaging_client
import waku/[requests/health_requests, waku_core, waku_node]
import messaging/delivery_service/send_service
import waku/node/subscription_manager
import libp2p/peerid
import ../../tools/confutils/cli_args
import ./[api_conf, types]

export cli_args

logScope:
  topics = "api"

proc createNode*(conf: WakuNodeConf): Future[Result[Waku, string]] {.async.} =
  let wakuConf = conf.toWakuConf().valueOr:
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

  return w.node.subscriptionManager.subscribe(contentTopic)

proc unsubscribe*(w: Waku, contentTopic: ContentTopic): Result[void, string] =
  ?checkApiAvailability(w)

  return w.node.subscriptionManager.unsubscribe(contentTopic)

proc send*(
    w: Waku, envelope: MessageEnvelope
): Future[Result[RequestId, string]] {.async.} =
  ?checkApiAvailability(w)
  return await w.messagingClient.send(envelope)

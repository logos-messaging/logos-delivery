import std/[net, options]

import chronicles, chronos, libp2p/peerid, results

import waku/factory/waku
import waku/messaging_client
import waku/[requests/health_requests, waku_core, waku_node]
import waku/node/delivery_service/send_service
import waku/node/subscription_manager
import ../../tools/confutils/cli_args
import ../../tools/confutils/messaging_conf
import ./[api_conf, types]

export cli_args, messaging_conf

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

proc seedDeveloperProfile(conf: var WakuNodeConf) =
  # TODO: Remember to add QUIC port here as well when that is added.
  var devPorts = WakuNodeConfOverlay.init()
  devPorts.tcpPort = some(Port(0))
  devPorts.discv5UdpPort = some(Port(0))
  devPorts.websocketPort = some(Port(0))
  applyAsOverride(conf, devPorts)

proc createNode*(
    preset = "",
    mode = cli_args.WakuMode.Core,
    overrides = WakuNodeConfOverlay.init(),
    additions = WakuNodeConfOverlay.init(),
): Future[Result[Waku, string]] {.async.} =
  ## Create a Waku node from messaging-API parameters.
  var conf = defaultWakuNodeConf().valueOr:
    return err("Failed creating default conf: " & error)
  conf.mode = mode
  conf.preset = preset
  seedDeveloperProfile(conf)
  applyAsOverride(conf, overrides)
  applyAsAddition(conf, additions)
  return await createNode(conf)

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

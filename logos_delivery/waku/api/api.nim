import logos_delivery/waku/compat/option_valueor
import std/[net, options]

import chronicles, chronos, libp2p/peerid, results

import logos_delivery/waku/factory/waku
import logos_delivery/messaging/messaging_client
import logos_delivery/channels/reliable_channel_manager
import
  logos_delivery/api/messaging_client_interface
    # brings the interface `send` method into scope: the impl's `method send` in the
    # BrokerImplement block is not exported, so the call below dispatches through the
    # MessagingClientInterface method instead.
import logos_delivery/waku/[requests/health_requests, waku_core, waku_node]
import logos_delivery/messaging/delivery_service/send_service
import logos_delivery/waku/node/subscription_manager
import libp2p/peerid
import tools/confutils/cli_args
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

# TODO workaround for legacy use. It will be removed as soon all usage goes through LogosDelivery.
proc mountMessagingClient*(w: Waku): Result[void, string] =
  ## Construct and attach a `MessagingClient` to the node, wiring its brokers
  ## under the node's own `brokerCtx` so emitted events (MessageSent/Error/
  ## Propagated) reach listeners registered on that same context.
  if w.isNil() or w.node.isNil():
    return err("Waku node is not initialized")
  if not w.messagingClient.isNil():
    return ok()

  w.messagingClient = ?newMessagingClient(w.brokerCtx, w.conf.p2pReliability, w.node)
  return ok()

# TODO workaround for legacy use. It will be removed as soon all usage goes through LogosDelivery.
proc mountReliableChannelManager*(w: Waku): Result[void, string] =
  ## Construct and attach a `ReliableChannelManager` to the node, wiring its
  ## brokers under the node's own `brokerCtx` (matching `mountMessagingClient`)
  ## so channel events reach listeners on that same context. Requires the
  ## messaging client to be mounted first.
  if w.isNil() or w.node.isNil():
    return err("Waku node is not initialized")
  if w.messagingClient.isNil():
    return err("messaging client must be mounted before reliable channel manager")
  if not w.reliableChannelManager.isNil():
    return ok()

  w.reliableChannelManager = ReliableChannelManager.createUnderContext(
    w.brokerCtx, MessagingClientInterface(w.messagingClient)
  )
  return ok()

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

## `LogosDelivery` is the project entry point. It is a pure concentrator: it
## owns exactly one instance of each API layer
##
##   Waku  <-  MessagingClient  <-  ReliableChannelManager
##
## and chains them together (each layer drives the one below it). Every layer
## keeps its own, separate public API — `LogosDelivery` only wires them up and
## drives the shared `new` / `start` / `stop` lifecycle.

{.push raises: [].}

import results, chronos, chronicles

import logos_delivery/api/logos_delivery_api
export logos_delivery_api

# Each layer has a core module (type + new/start/stop) and an api/ folder whose
# modules each implement a differentiated set of operations, plus an events
# surface. The concentrator re-exports them so library consumers get the full
# surface from `import logos_delivery`. (The per-layer `events` modules share a
# stem, so they are imported under aliases.)

# Waku layer
import logos_delivery/waku/waku
export waku
import
  logos_delivery/waku/api/[
    topics, relay, filter, lightpush, store, peer_manager, discovery, debug, health,
    ping,
  ]
export
  topics, relay, filter, lightpush, store, peer_manager, discovery, debug, health, ping
# `MessageSeenEvent` is surfaced via `export waku` (Kernel interface); the
# remaining waku health events live here.
import logos_delivery/waku/api/events/health_events
export health_events

# Messaging layer
import logos_delivery/messaging/messaging_client
export messaging_client
import logos_delivery/messaging/api/[subscription, send]
export subscription, send
# Message* events are surfaced via `export messaging_client` (messaging interface).

# Reliable Channel layer
import logos_delivery/channels/reliable_channel_manager
export reliable_channel_manager
import logos_delivery/channels/api/channel_lifecycle
export channel_lifecycle
import logos_delivery/channels/api/send as channel_send
export channel_send
# ChannelMessage* events are surfaced via `export reliable_channel_manager`.

import logos_delivery/waku/factory/waku_conf
import logos_delivery/waku/factory/app_callbacks
import tools/confutils/cli_args
import logos_delivery/waku/node/health_monitor/online_monitor

logScope:
  topics = "logosdelivery"

type
  LogosDeliveryConf* = object
    ## Aggregates the per-layer config objects. For now
    ## the sub-configs are derived from `WakuConf`; richer per-layer configuration
    ## (and how it is sourced) lands in a follow-up PR.
    waku*: WakuConf
    messaging*: MessagingClientConf
    reliableChannel*: ReliableChannelManagerConf

  LogosDelivery* = ref object of ILogosDelivery
    ## Entry point. Holds one instance of each API layer.
    waku*: Waku
    messagingClient*: MessagingClient
    reliableChannelManager*: ReliableChannelManager

proc init*(T: type LogosDeliveryConf, wakuConf: WakuConf): LogosDeliveryConf =
  ## Builds the aggregated config from a `WakuConf`. The messaging / reliable
  ## channel layers carry trivial config today; this is the seam where their
  ## dedicated config will be threaded through later.
  LogosDeliveryConf(
    waku: wakuConf,
    messaging: MessagingClientConf(useP2PReliability: wakuConf.p2pReliability),
    reliableChannel: ReliableChannelManagerConf(),
  )

proc new*(
    T: type LogosDelivery, conf: WakuNodeConf, appCallbacks: AppCallbacks = nil
): Future[Result[LogosDelivery, string]] {.async.} =
  ## Single entry point, from the CLI configuration type. Derives the aggregated
  ## per-layer config, then creates the full stack bottom-up so each layer can
  ## chain onto the one below.
  let wakuConf = conf.toWakuConf().valueOr:
    return err("failed to handle the configuration: " & error)
  let layerConf = LogosDeliveryConf.init(wakuConf)

  let waku = (await Waku.new(layerConf.waku, appCallbacks)).valueOr:
    return err("failed to create Waku: " & error)

  let messagingClient = MessagingClient.new(layerConf.messaging, waku).valueOr:
    return err("failed to create MessagingClient: " & error)

  let reliableChannelManager = ReliableChannelManager.new(
    layerConf.reliableChannel, messagingClient, waku.brokerCtx
  ).valueOr:
    return err("failed to create ReliableChannelManager: " & error)

  return ok(
    T(
      waku: waku,
      messagingClient: messagingClient,
      reliableChannelManager: reliableChannelManager,
    )
  )

method start*(self: LogosDelivery): Future[Result[void, string]] {.async.} =
  ## Starts each layer bottom-up: transport first, then messaging, then channels.
  if self.waku.isNil():
    return err("Waku node is not initialized")
  if self.messagingClient.isNil():
    return err("MessagingClient is not initialized")
  if self.reliableChannelManager.isNil():
    return err("ReliableChannelManager is not initialized")

  (await self.waku.start()).isOkOr:
    return err("failed to start Waku: " & error)

  self.messagingClient.start().isOkOr:
    return err("failed to start MessagingClient: " & error)

  self.reliableChannelManager.start().isOkOr:
    return err("failed to start ReliableChannelManager: " & error)

  return ok()

method stop*(self: LogosDelivery): Future[Result[void, string]] {.async.} =
  ## Stops in reverse order so higher layers drain before their dependencies.
  await self.reliableChannelManager.stop()
  await self.messagingClient.stop()

  (await self.waku.stop()).isOkOr:
    return err("failed to stop Waku: " & error)

  return ok()

method isOnline*(self: LogosDelivery): Future[Result[bool, string]] {.async.} =
  if self.waku.isNil():
    return err("Waku node is not initialized")
  return ok(self.waku.healthMonitor.onlineMonitor.amIOnline())

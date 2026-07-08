## `LogosDelivery` is the project entry point. It is a pure concentrator: it
## owns exactly one instance of each API layer
##
##   Waku  <-  MessagingClient  <-  ReliableChannelManager
##
## and chains them together (each layer drives the one below it). Every layer
## keeps its own, separate public API — `LogosDelivery` only wires them up and
## drives the shared `new` / `start` / `stop` lifecycle.

{.push raises: [].}

import std/options
import results, chronos, chronicles

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
    topics, relay, subscriptions, filter, lightpush, store, peer_manager, discovery,
    debug, health, ping,
  ]
export
  topics, relay, subscriptions, filter, lightpush, store, peer_manager, discovery,
  debug, health, ping
# Kernel event surface (`MessageSeenEvent`) plus the remaining waku health events.
import logos_delivery/api/events/kernel_events
export kernel_events
import logos_delivery/waku/api/events/health_events
export health_events

# Messaging layer
import logos_delivery/messaging/[messaging_client, messaging_client_lifecycle]
export messaging_client
import logos_delivery/messaging/api/[subscription, send]
export subscription, send
import logos_delivery/api/events/messaging_client_events
export messaging_client_events
import logos_delivery/api/messaging_conf
export messaging_conf

# Reliable Channel layer
import logos_delivery/channels/reliable_channel_manager
export reliable_channel_manager
import logos_delivery/channels/api/channel_lifecycle
export channel_lifecycle
import logos_delivery/channels/api/send as channel_send
export channel_send
import logos_delivery/api/events/reliable_channel_manager_events
export reliable_channel_manager_events

import logos_delivery/api/logos_delivery_api
export logos_delivery_api
import logos_delivery/waku/factory/waku_conf
import logos_delivery/waku/factory/app_callbacks
import tools/confutils/cli_args
import logos_delivery/waku/node/health_monitor/online_monitor
import logos_delivery/api/logos_delivery_conf
export logos_delivery_conf

logScope:
  topics = "logosdelivery"

type LogosDelivery* = ref object ## Entry point. Holds one instance of each API layer.
  waku*: Waku
  messagingClient*: MessagingClient
  reliableChannelManager*: ReliableChannelManager

proc new*(
    T: type LogosDelivery, conf: LogosDeliveryConf, appCallbacks: AppCallbacks = nil
): Future[Result[LogosDelivery, string]] {.async.} =
  ## Builds the stack bottom-up from a resolved per-layer config.
  let wakuConf = conf.kernelConf.toWakuConf().valueOr:
    return err("failed to handle the configuration: " & error)
  let waku = (await Waku.new(wakuConf, appCallbacks)).valueOr:
    return err("failed to create Waku: " & error)

  let messagingClient = MessagingClient.new(conf.messagingConf, waku).valueOr:
    return err("failed to create MessagingClient: " & error)

  let reliableChannelManager = ReliableChannelManager.new(
    conf.channelsConf, waku.brokerCtx
  ).valueOr:
    return err("failed to create ReliableChannelManager: " & error)

  return ok(
    LogosDelivery(
      waku: waku,
      messagingClient: messagingClient,
      reliableChannelManager: reliableChannelManager,
    )
  )

proc new*(
    T: type LogosDelivery, conf: WakuNodeConf, appCallbacks: AppCallbacks = nil
): Future[Result[LogosDelivery, string]] {.async.} =
  ## Builds the full stack from a kernel `WakuNodeConf`.
  return await LogosDelivery.new(
    LogosDeliveryConf(
      kernelConf: conf,
      messagingConf: MessagingClientConf(),
      channelsConf: ReliableChannelManagerConf(),
    ),
    appCallbacks,
  )

proc new*(
    T: type LogosDelivery,
    mode: WakuMode = WakuMode.Core,
    preset: string = "",
    messagingOverrides: MessagingClientConf = MessagingClientConf(),
    channelsOverrides: ReliableChannelManagerConf = ReliableChannelManagerConf(),
    appCallbacks: AppCallbacks = nil,
): Future[Result[LogosDelivery, string]] {.async.} =
  ## Messaging entry point (app dev). Builds the full stack from preset, mode and overrides.
  let conf = LogosDeliveryConf.init(mode, preset, messagingOverrides, channelsOverrides).valueOr:
    return err("failed to synthesize configuration: " & error)
  return await LogosDelivery.new(conf, appCallbacks)

proc start*(self: LogosDelivery): Future[Result[void, string]] {.async.} =
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

proc stop*(self: LogosDelivery): Future[Result[void, string]] {.async.} =
  ## Stops in reverse order so higher layers drain before their dependencies.
  if not self.reliableChannelManager.isNil():
    await self.reliableChannelManager.stop()
  if not self.messagingClient.isNil():
    await self.messagingClient.stop()
  if not self.waku.isNil():
    (await self.waku.stop()).isOkOr:
      return err("failed to stop Waku: " & error)

  return ok()

proc isOnline*(self: LogosDelivery): Future[Result[bool, string]] {.async.} =
  if self.waku.isNil():
    return err("Waku node is not initialized")
  return await self.waku.isOnline()

# Compile-time check that each concrete type satisfies its API concept.
static:
  doAssert Waku is KernelApi
  doAssert MessagingClient is MessagingApi
  doAssert ReliableChannelManager is ReliableChannelApi
  doAssert LogosDelivery is LogosDeliveryApi

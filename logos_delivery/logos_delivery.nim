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

import logos_delivery/waku/api
export api
import logos_delivery/waku/factory/waku
export waku
import logos_delivery/messaging/messaging_client
export messaging_client
import logos_delivery/channels/reliable_channel_manager
export reliable_channel_manager

import logos_delivery/waku/factory/waku_conf
import logos_delivery/waku/factory/app_callbacks
import logos_delivery/waku/api/[api_conf, types]

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

  LogosDelivery* = ref object ## Entry point. Holds one instance of each API layer.
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

  let messagingClient = MessagingClient.new(layerConf.messaging, waku.node).valueOr:
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

proc start*(self: LogosDelivery): Future[Result[void, string]] {.async.} =
  ## Starts each layer bottom-up: transport first, then messaging, then channels.
  (await self.waku.start()).isOkOr:
    return err("failed to start Waku: " & error)

  self.messagingClient.start().isOkOr:
    return err("failed to start MessagingClient: " & error)

  self.reliableChannelManager.start().isOkOr:
    return err("failed to start ReliableChannelManager: " & error)

  return ok()

proc stop*(self: LogosDelivery): Future[Result[void, string]] {.async.} =
  ## Stops in reverse order so higher layers drain before their dependencies.
  await self.reliableChannelManager.stop()
  await self.messagingClient.stop()

  (await self.waku.stop()).isOkOr:
    return err("failed to stop Waku: " & error)

  return ok()

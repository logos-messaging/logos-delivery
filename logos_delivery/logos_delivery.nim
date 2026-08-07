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
import logos_delivery/messaging/rest_api/handlers as messaging_rest_api
export messaging_rest_api
import logos_delivery/api/events/messaging_client_events
export messaging_client_events
import logos_delivery/api/conf/messaging_conf
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
import logos_delivery/api/conf/logos_delivery_conf
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
  ## Builds the stack bottom-up from a resolved per-layer config; each layer is
  ## mounted iff its config is present.
  let wakuConf = WakuNodeConf(conf.kernelConf).toWakuConf().valueOr:
      return err("failed to handle the configuration: " & error)
  let waku = (await Waku.new(wakuConf, appCallbacks)).valueOr:
    return err("failed to create Waku: " & error)

  let messagingClient =
    if conf.messagingConf.isSome():
      MessagingClient.new(conf.messagingConf.get(), waku).valueOr:
        return err("failed to create MessagingClient: " & error)
    else:
      nil

  let reliableChannelManager =
    if conf.channelsConf.isSome():
      ReliableChannelManager.new(conf.channelsConf.get(), waku.brokerCtx).valueOr:
        return err("failed to create ReliableChannelManager: " & error)
    else:
      nil

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
  ## Builds the stack from a kernel `WakuNodeConf`, selecting which API layers to
  ## instantiate by `conf.entryLayer`:
  ##   kernel    -> transport only; `conf.mode` is ignored and the config is used as-is
  ##   messaging -> kernel + messaging client
  ##   channels  -> kernel + messaging + reliable channels
  ## For `messaging`/`channels`, `conf.mode` (Edge/Core) sets the kernel protocol
  ## flags first (messaging-level concern); for `kernel` it is skipped.
  var kernelConf = conf
  if conf.entryLayer != EntryLayer.kernel:
    applyMode(kernelConf, conf.mode).isOkOr:
      return err("failed to apply mode: " & error)

  let ldConf = LogosDeliveryConf(
    kernelConf: KernelConf(kernelConf),
    messagingConf:
      if conf.entryLayer == EntryLayer.kernel:
        Opt.none(MessagingClientConf)
      else:
        Opt.some(MessagingClientConf()),
    channelsConf:
      if conf.entryLayer == EntryLayer.channels:
        Opt.some(ReliableChannelManagerConf())
      else:
        Opt.none(ReliableChannelManagerConf),
  )
  return await LogosDelivery.new(ldConf, appCallbacks)

proc new*(
    T: type LogosDelivery, kernelConf: KernelConf, appCallbacks: AppCallbacks = nil
): Future[Result[LogosDelivery, string]] {.async.} =
  ## Kernel entry layer: mounts the kernel only from a raw `KernelConf`; no
  ## messaging client, no channel manager.
  return await LogosDelivery.new(LogosDeliveryConf.init(kernelConf), appCallbacks)

proc new*(
    T: type LogosDelivery,
    kernelConf: KernelConf,
    messagingOverrides: MessagingClientConf,
    channelsOverrides: ReliableChannelManagerConf,
    appCallbacks: AppCallbacks = nil,
): Future[Result[LogosDelivery, string]] {.async.} =
  ## Full stack: kernel + messaging + channels. Messaging is never skipped; a
  ## kernel-only node uses `new(kernelConf)` instead.
  return await LogosDelivery.new(
    LogosDeliveryConf(
      kernelConf: kernelConf,
      messagingConf: Opt.some(messagingOverrides),
      channelsConf: Opt.some(channelsOverrides),
    ),
    appCallbacks,
  )

proc new*(
    T: type LogosDelivery,
    entryLayer: EntryLayer = EntryLayer.channels,
    mode: LogosDeliveryMode = LogosDeliveryMode.Core,
    preset: string = "",
    messagingOverrides: MessagingClientConf = MessagingClientConf(),
    channelsOverrides: ReliableChannelManagerConf = ReliableChannelManagerConf(),
    appCallbacks: AppCallbacks = nil,
): Future[Result[LogosDelivery, string]] {.async.} =
  ## Messaging entry point (app dev). Builds the stack from preset, mode and
  ## overrides; `entryLayer` selects messaging vs channels (use `new(kernelConf)`
  ## for a kernel-only node).
  let conf = LogosDeliveryConf.init(
    entryLayer = entryLayer,
    mode = mode,
    preset = preset,
    messagingOverrides = messagingOverrides,
    channelsOverrides = channelsOverrides,
  ).valueOr:
    return err("failed to synthesize configuration: " & error)
  return await LogosDelivery.new(conf, appCallbacks)

proc start*(self: LogosDelivery): Future[Result[void, string]] {.async.} =
  ## Starts each present layer bottom-up: transport, then messaging, then channels.
  if self.waku.isNil():
    return err("Waku node is not initialized")

  (await self.waku.start()).isOkOr:
    return err("failed to start Waku: " & error)

  if not self.messagingClient.isNil():
    self.messagingClient.start().isOkOr:
      return err("failed to start MessagingClient: " & error)
    # Mount the messaging REST endpoints onto the kernel's REST router (no-op if
    # REST is disabled). Done here rather than in MessagingClient.start so the
    # core messaging module need not depend on the REST layer above it.
    self.messagingClient.mountRestApi()

  if not self.reliableChannelManager.isNil():
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

func isRunning*(self: LogosDelivery): bool =
  ## True while a layer still holds what `stop` releases; the channel manager
  ## needs no test, its `stop` is already a no-op when empty.
  let transportUp =
    not self.waku.isNil() and not self.waku.node.isNil() and self.waku.node.started
  let messagingUp = not self.messagingClient.isNil() and self.messagingClient.started
  transportUp or messagingUp

proc isOnline*(self: LogosDelivery): Future[Result[bool, string]] {.async.} =
  if self.waku.isNil():
    return err("Waku node is not initialized")
  return await self.waku.isOnline()

proc ensureMessaging*(self: LogosDelivery): Result[void, string] =
  ## Fails if the node has no messaging client (a kernel-only node).
  if self.isNil() or self.messagingClient.isNil():
    return err("node has no messaging client (kernel-only node)")
  ok()

proc ensureChannels*(self: LogosDelivery): Result[void, string] =
  ## Fails if the node has no reliable channel manager (a kernel-only node).
  if self.isNil() or self.reliableChannelManager.isNil():
    return err("node has no reliable channel manager (kernel-only node)")
  ok()

# Compile-time check that each concrete type satisfies its API concept.
static:
  doAssert Waku is KernelApi
  doAssert MessagingClient is MessagingApi
  doAssert ReliableChannelManager is ReliableChannelApi
  doAssert LogosDelivery is LogosDeliveryApi

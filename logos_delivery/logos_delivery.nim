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

type
  LifecycleState* {.pure.} = enum
    Stopped
    Starting
    Running
    Stopping

  LogosDelivery* = ref object ## Entry point. Holds one instance of each API layer.
    waku*: Waku
    messagingClient*: MessagingClient
    reliableChannelManager*: ReliableChannelManager
    state: LifecycleState
    lifecycleLock: AsyncLock
      ## Held for the whole of `start` and `stop`, so that a stop waits for a
      ## start in progress.

proc buildLogosDeliveryStack(
    wakuConf: WakuConf,
    messagingConf: Opt[MessagingClientConf],
    channelsConf: Opt[ReliableChannelManagerConf],
    appCallbacks: AppCallbacks,
): Future[Result[LogosDelivery, string]] {.async.} =
  ## Mounts each layer iff its config object is given.
  let waku = (await Waku.new(wakuConf, appCallbacks)).valueOr:
    return err("failed to create Waku: " & error)

  let messagingClient =
    if messagingConf.isSome():
      MessagingClient.new(messagingConf.get(), waku).valueOr:
        return err("failed to create MessagingClient: " & error)
    else:
      nil

  let reliableChannelManager =
    if channelsConf.isSome():
      ReliableChannelManager.new(channelsConf.get(), waku.brokerCtx).valueOr:
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

proc resolveCliConf*(
    conf: LogosDeliveryNodeConf
): Result[
    tuple[
      kernelConf: KernelConf,
      messagingConf: Opt[MessagingClientConf],
      channelsConf: Opt[ReliableChannelManagerConf],
    ],
    string,
] =
  ## CLI translation: `conf.entryLayer` selects which layers are mounted.
  var messagingConf = Opt.none(MessagingClientConf)
  var ldNodeConf = conf

  if ldNodeConf.entryLayer == EntryLayer.kernel:
    # User has given a mode but the kernel entry layer takes no mode.
    # That's inconsistent, so fail.
    if ldNodeConf.mode.isSome():
      return err("mode requires the 'messaging' or 'channels' entry layer")
    if ldNodeConf.messaging.isSet():
      return
        err("the Messaging API flags require the 'messaging' or 'channels' entry layer")
  else:
    applyMode(ldNodeConf.kernel, ldNodeConf.mode.get(LogosDeliveryMode.Core))
    # `LogosDeliveryConf.init` mounts mix for an anonymity level above `None`,
    # for every config path.
    let ldConf = ?LogosDeliveryConf.init(
      KernelConf(ldNodeConf.kernel),
      ?MessagingClientConf.init(ldNodeConf.messaging, ldNodeConf.kernel.preset),
      Opt.none(ReliableChannelManagerConf),
    )
    ldNodeConf.kernel = WakuNodeConf(ldConf.kernelConf)
    messagingConf = ldConf.messagingConf
  applyModeFlags(ldNodeConf.kernel, DefaultKernelModeFlags)

  return ok(
    (
      kernelConf: KernelConf(ldNodeConf.kernel),
      messagingConf: messagingConf,
      channelsConf:
        if ldNodeConf.entryLayer == EntryLayer.channels:
          Opt.some(ReliableChannelManagerConf())
        else:
          Opt.none(ReliableChannelManagerConf),
    )
  )

proc new*(
    T: type LogosDelivery, conf: LogosDeliveryNodeConf, appCallbacks: AppCallbacks = nil
): Future[Result[LogosDelivery, string]] {.async.} =
  ## CLI adapter: translates the logosdeliverynode config and builds the stack.
  let resolved = resolveCliConf(conf).valueOr:
    return err("failed to translate the configuration: " & error)
  let wakuConf = WakuNodeConf(resolved.kernelConf).toWakuConf().valueOr:
      return err("failed to translate the configuration: " & error)
  return await buildLogosDeliveryStack(
    wakuConf, resolved.messagingConf, resolved.channelsConf, appCallbacks
  )

proc new*(
    T: type LogosDelivery, conf: LogosDeliveryConf, appCallbacks: AppCallbacks = nil
): Future[Result[LogosDelivery, string]] {.async.} =
  ## Builds the stack from a resolved per-layer config; each layer is
  ## mounted iff its config is present.
  let wakuConf = WakuNodeConf(conf.kernelConf).toWakuConf().valueOr:
      return err("failed to handle the configuration: " & error)
  return await buildLogosDeliveryStack(
    wakuConf, conf.messagingConf, conf.channelsConf, appCallbacks
  )

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
  let conf = LogosDeliveryConf.init(
    kernelConf, messagingOverrides, Opt.some(channelsOverrides)
  ).valueOr:
    return err("failed to build the node config: " & error)
  return await LogosDelivery.new(conf, appCallbacks)

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
  ## overrides; `entryLayer` selects how far up the stack to go. `kernel` mounts
  ## no upper layers but still applies mode/preset.
  let conf = LogosDeliveryConf.init(
    entryLayer = entryLayer,
    mode = mode,
    preset = preset,
    messagingOverrides = messagingOverrides,
    channelsOverrides = channelsOverrides,
  ).valueOr:
    return err("failed to synthesize configuration: " & error)
  return await LogosDelivery.new(conf, appCallbacks)

func lifecycleState*(self: LogosDelivery): LifecycleState =
  self.state

proc lifecycle(self: LogosDelivery): AsyncLock =
  ## Made on first use, so that a zero-initialised `LogosDelivery` is valid.
  if self.lifecycleLock.isNil():
    self.lifecycleLock = newAsyncLock()
  self.lifecycleLock

func isRunning*(self: LogosDelivery): bool =
  ## True while a layer still holds what `stop` releases; the channel manager
  ## needs no test, its `stop` is already a no-op when empty.
  let transportUp =
    not self.waku.isNil() and not self.waku.node.isNil() and self.waku.node.started
  let messagingUp = not self.messagingClient.isNil() and self.messagingClient.started
  transportUp or messagingUp

proc start*(self: LogosDelivery): Future[Result[void, string]] {.async.} =
  ## Starts each present layer bottom-up: transport, then messaging, then channels.
  ## Only a stopped node starts. A start on a running node is a no-op. A start
  ## during a start or a stop returns an error. A start that fails stops the
  ## transport and messaging layers. The channel layer cannot fail, and its
  ## `stop` closes the channels made before `start`, so the rollback does not
  ## stop it. After a failed stop, a start returns an error while the messaging
  ## layer is down. A start on a stopped node with a layer still up returns an
  ## error too.
  if self.waku.isNil():
    return err("Waku node is not initialized")

  case self.state
  of LifecycleState.Running:
    # A failed stop keeps `Running` with the messaging layer already stopped.
    if not self.messagingClient.isNil() and not self.messagingClient.started:
      return err("cannot start a node with one layer already up")
    return ok()
  of LifecycleState.Starting:
    return err("cannot start while a start is in progress")
  of LifecycleState.Stopping:
    return err("cannot start while a stop is in progress")
  of LifecycleState.Stopped:
    # A layer can be up on a `Stopped` node: after a failed rollback, or when
    # the layer was started on its own.
    if self.isRunning():
      return err("cannot start a node with one layer already up")

  # A start does not wait for the lock. On a stopped node, only a stop that
  # waits to run holds it.
  if not self.lifecycle.tryAcquire():
    return err("cannot start while a stop is in progress")
  self.state = LifecycleState.Starting

  var startSucceeded = false
  defer:
    self.state = if startSucceeded: LifecycleState.Running else: LifecycleState.Stopped
    self.lifecycle.release2()

  # Waku.start stops the node when it fails after the node started.
  (await self.waku.start()).isOkOr:
    return err("failed to start Waku: " & error)

  defer:
    if not startSucceeded:
      # noCancel: a cancelled rollback leaves the node half stopped.
      if not self.messagingClient.isNil():
        await noCancel self.messagingClient.stop()
      (await noCancel self.waku.stop()).isOkOr:
        error "Failed to stop after a failed start", error = error

  if not self.messagingClient.isNil():
    self.messagingClient.start().isOkOr:
      return err("failed to start MessagingClient: " & error)

  if not self.reliableChannelManager.isNil():
    self.reliableChannelManager.start().isOkOr:
      return err("failed to start ReliableChannelManager: " & error)

  startSucceeded = true
  return ok()

proc stop*(self: LogosDelivery): Future[Result[void, string]] {.async.} =
  ## Stops in reverse order so higher layers drain before their dependencies.
  ## A stop during a start waits for the start to end, then stops. The layers
  ## below the channels are stopped only when one of them runs.
  await self.lifecycle.acquire()
  self.state = LifecycleState.Stopping
  var stopSucceeded = false
  defer:
    # After a failed stop the transport can still be up, so the next stop
    # retries. `start` refuses the node while its messaging layer is down.
    self.state = if stopSucceeded: LifecycleState.Stopped else: LifecycleState.Running
    self.lifecycle.release2()

  if not self.reliableChannelManager.isNil():
    await self.reliableChannelManager.stop()
  # A stop of a stopped transport logs libp2p warnings.
  if self.isRunning():
    if not self.messagingClient.isNil():
      await self.messagingClient.stop()
    if not self.waku.isNil():
      (await self.waku.stop()).isOkOr:
        return err("failed to stop Waku: " & error)

  stopSucceeded = true
  return ok()

proc isOnline*(self: LogosDelivery): Future[Result[bool, string]] {.async.} =
  if self.waku.isNil():
    return err("Waku node is not initialized")
  return await self.waku.isOnline()

proc getConnectionStatus*(
    self: LogosDelivery
): Future[Result[ConnectionStatus, string]] {.async.} =
  if self.waku.isNil():
    return err("Waku node is not initialized")
  return await self.waku.getConnectionStatus()

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

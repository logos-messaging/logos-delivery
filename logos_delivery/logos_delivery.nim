## LogosDelivery — the LogosDeliveryInterface facade implementation.
##
## Owns a `Waku` (node + messagingClient + reliableChannelManager) and exposes
## the three sub-interfaces through cached getters. Mirrors the persistence
## example's `PersistenceImpl` (nim-brokers/examples/persistence/nimlib): a
## `ref object of <iface>` with `BrokerImplement`, sub-instances built on a
## `newInstanceCtx(self.brokerCtx)`, plus a `provideFactory`.
##
## Scope (decided): `initializeRequest(configPath)` creates + mounts the node but
## does NOT start it. `kernel()` is a stub until a KernelImpl exists.

import results, chronos
import std/options # some()/Option for WakuNodeConf.mode
import std/json # newJArray/newJObject/%*/pretty in getAvailableConfigs
import std/strutils

import brokers/broker_context, brokers/broker_interface, brokers/broker_implement
import logos_delivery/api/logos_delivery_interface as logosdelivery_iface
import logos_delivery/api/types as api_types
import logos_delivery/api/kernel_interface as kernel_iface

import
  logos_delivery/waku/factory/waku,
  logos_delivery/waku/factory/waku_state_info,
  logos_delivery/messaging/messaging_client,
  logos_delivery/channels/reliable_channel_manager
    # Waku, getNodeInfoItem, mountMessagingClient, mountReliableChannelManager, stop
import tools/confutils/[cli_args, config_option_meta] # WakuNodeConf (+ .load)

type LogosDelivery* = ref object of LogosDeliveryInterface
  waku: Waku ## the owned node facade (built in initializeRequest)
  messagingClient: MessagingClient
  reliableChannelManager: ReliableChannelManager

proc loadConf(configPath: string): Result[WakuNodeConf, string] =
  ## Delegates to cli_args' concrete loader so confutils' `load` macro expands in
  ## cli_args' full scope (avoids leaking undeclared identifiers / WakuMode clash here).
  loadWakuNodeConfFromFile(configPath)

proc createNode(conf: WakuNodeConf): Future[Result[Waku, string]] {.async.} =
  let wakuConf = conf.toWakuConf().valueOr:
    return err("Failed to handle the configuration: " & error)

  ## We are not defining app callbacks at node creation
  let wakuRes = (await Waku.createUnderContext(globalBrokerContext(), wakuConf)).valueOr:
    error "waku initialization failed", error = error
    return err("Failed setting up Waku: " & $error)

  return ok(wakuRes)

proc initMessagingClient(self: LogosDelivery): Result[MessagingClient, string] =
  newMessagingClient(
    globalBrokerContext(), self.waku.conf.p2pReliability, self.waku.node
  )

proc initReliableChannelManager(
    self: LogosDelivery
): Result[ReliableChannelManager, string] =
  return ok(
    ReliableChannelManager.createUnderContext(
      globalBrokerContext(), self.messagingClient
    )
  )

BrokerImplement LogosDelivery of LogosDeliveryInterface:
  method kernel(
      self: LogosDelivery
  ): Future[Result[KernelInterface, string]] {.async.} =
    if self.waku.isNil():
      return err("not initialized; call startAsClient first")

    return ok(KernelInterface(self.waku))

  method messaging(
      self: LogosDelivery
  ): Future[Result[MessagingClientInterface, string]] {.async.} =
    if self.waku.isNil():
      return err("not initialized; call startAsClient first")
    if self.messagingClient.isNil():
      return err("messaging client not mounted")
    return ok(MessagingClientInterface(self.messagingClient))

  method channels(
      self: LogosDelivery
  ): Future[Result[ReliableChannelManagerInterface, string]] {.async.} =
    if self.waku.isNil():
      return err("not initialized; call startAsClient first")
    if self.messagingClient.isNil():
      return err("not initialized; call startAsClient first")

    if self.reliableChannelManager.isNil():
      self.reliableChannelManager = initReliableChannelManager(self).valueOr:
        return err("failed to initialize ReliableChannelManager: " & error)
      self.reliableChannelManager.start().isOkOr:
        return err("failed to start ReliableChannelManager: " & error)

    return ok(ReliableChannelManagerInterface(self.reliableChannelManager))

  method startAsNode(
      self: LogosDelivery, config: string
  ): Future[Result[void, string]] {.async.} =
    if not self.waku.isNil():
      return err("already initialized")
    let conf = loadConf(config).valueOr:
      return err("failed to load config: " & error)
    # The restamp forces {.async: (raises: []).}, but createNode can raise.
    try:
      self.waku = (await createNode(conf)).valueOr:
        return err("failed to create node: " & error)

      (await self.waku.start()).isOkOr:
        return err("failed to start node: " & $error)

      return ok()
    except CatchableError as e:
      return err("initialize failed: " & e.msg)

  method startAsClient(
      self: LogosDelivery, mode: api_types.WakuMode, preset: string
  ): Future[Result[MessagingClientInterface, string]] {.async.} =
    if not self.messagingClient.isNil():
      return err("already initialized")
    if not self.waku.isNil():
      return err(
        "already started as node; cannot start as client, but you can use as client"
      )

    try:
      var conf: WakuNodeConf = ?defaultWakuNodeConf()
      conf.mode = some(mode)
      conf.preset = preset

      self.waku = (await createNode(conf)).valueOr:
        return err("failed to create node: " & error)

      self.messagingClient = initMessagingClient(self).valueOr:
        return err("failed to mount messaging client: " & error)

      (await self.waku.start()).isOkOr:
        return err("failed to start node: " & $error)
      self.messagingClient.start().isOkOr:
        return err("failed to start messaging client: " & $error)

      return ok(MessagingClientInterface(self.messagingClient))
    except CatchableError as e:
      return err("initialize failed: " & e.msg)

  method stop(self: LogosDelivery): Future[Result[void, string]] {.async.} =
    var errs: seq[string]

    if not self.reliableChannelManager.isNil():
      try:
        await self.reliableChannelManager.stop()
        self.reliableChannelManager.close()
      except CatchableError as e:
        errs.add("ReliableChannelManager stop failed: " & e.msg)
      self.reliableChannelManager = nil

    if not self.messagingClient.isNil():
      try:
        await self.messagingClient.stop()
        self.messagingClient.close()
      except CatchableError as e:
        errs.add("MessagingClient stop failed: " & e.msg)
      self.messagingClient = nil

    if not self.waku.isNil():
      try:
        # `Waku` is a plain ref object (not a BrokerImplement) — `stop()` is its
        # only teardown; there is no `close()`.
        (await self.waku.stop()).isOkOr:
          errs.add("Node stop failed: " & $error)
      except CatchableError as e:
        errs.add("Node stop failed: " & e.msg)
      self.waku = nil

    if errs.len > 0:
      return err(errs.join("; "))
    return ok()

  method shutdown(self: LogosDelivery): Future[Result[void, string]] {.async.} =
    return await self.stop()

  method getNodeInfo(
      self: LogosDelivery, id: NodeInfoId
  ): Future[Result[string, string]] {.async.} =
    if self.waku.isNil():
      return err("not initialized; call startAsNode or startAsClient first")
    return ok(self.waku.stateInfo.getNodeInfoItem(id))

  method getAvailableConfigs(
      self: LogosDelivery
  ): Future[Result[string, string]] {.async.} =
    let optionMetas: seq[ConfigOptionMeta] = extractConfigOptionMeta(WakuNodeConf)
    var configOptionDetails = newJArray()

    for meta in optionMetas:
      configOptionDetails.add(
        %*{
          meta.fieldName: meta.typeName & "(" & meta.defaultValue & ")",
          "desc": meta.desc,
        }
      )

    var jsonNode = newJObject()
    jsonNode["configOptions"] = configOptionDetails
    let asString = pretty(jsonNode)
    return ok(pretty(jsonNode))

# DI factory registration: non ffi - nim lib users needs it.
LogosDeliveryInterface.provideFactory(
  proc(): Result[LogosDeliveryInterface, string] {.gcsafe.} =
    ok(LogosDeliveryInterface(LogosDelivery.createUnderContext(globalBrokerContext())))
)

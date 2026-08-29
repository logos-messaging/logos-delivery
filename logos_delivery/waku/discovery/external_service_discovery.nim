{.push raises: [].}

## IPeerDiscovery backed by an external service-discovery plugin (today:
## logos-libp2p-module, driven by glue in logos-delivery-module).
##
## Shape-wise this is the twin of the internal `ServiceDiscovery` backend:
## fully async verbs plus periodic lookup loops. The difference is only where
## the work happens — every plugin call is dispatched to the discovery worker
## thread through `(mt)` request brokers, so a 30 s DHT bootstrap blocks that
## thread and never the node's event loop.
##
## This module has no libp2p dependency at all.

import std/sequtils
import chronos, chronicles, results
import brokers/broker_implement
import
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/discovery/plugin/service_discovery_accessor,
  logos_delivery/waku/discovery/plugin/service_discovery_worker

export peer_discovery_interface, service_discovery_accessor

logScope:
  topics = "waku discovery external"

const
  ExternalBackendId* = "service-ext"
  DefaultServiceLookupInterval* = chronos.seconds(60)
  DefaultRandomLookupInterval* = chronos.seconds(60)

type ExternalServiceDiscovery* = ref object of IPeerDiscovery
  running: bool
  nodeCtx: BrokerContext
  interests: seq[string]
  serviceLookupInterval: Duration
  randomLookupInterval: Duration
  serviceLookupLoop: Future[void]
  randomLookupLoop: Future[void]

proc readyPlugin(): Result[ServiceDiscoveryPlugin, string] =
  ## External discovery needs both halves: the node configured for it (which
  ## is what created this backend) and a registered, fully populated plugin.
  let plugin = loadPlugin().valueOr:
    return
      err("external backend: configured but no service discovery plugin registered")
  ?plugin.validate()
  ok(plugin)

template pluginCall(T: typedesc, op: string, request: untyped): untyped =
  ## Awaits one (mt) plugin request, bounded by the timeout the plugin
  ## declared at registration. The worker is not interrupted on timeout —
  ## the entry point runs to completion there — the caller just stops waiting.
  ## `T` is the payload type, so every branch stays correctly typed; the
  ## template yields a value rather than returning, which keeps it usable
  ## inside the async transform.
  block:
    let plugRes = readyPlugin()
    if plugRes.isErr():
      Result[T, string].err(plugRes.error())
    else:
      let plugin = plugRes.get()
      let fut = request
      var cancelled = false
      let answered =
        try:
          await fut.withTimeout(plugin.requestTimeout())
        except CancelledError:
          cancelled = true
          false
      if cancelled:
        Result[T, string].err("external backend: " & op & " cancelled")
      elif not answered:
        Result[T, string].err(
          "external backend: plugin did not answer " & op & " in time"
        )
      else:
        try:
          fut.read()
        except CatchableError:
          Result[T, string].err(
            "external backend: " & op & " failed: " & getCurrentExceptionMsg()
          )

proc emitPeers(
    self: ExternalServiceDiscovery, key: string, peers: seq[DiscoveredPeer]
) =
  if peers.len == 0:
    return
  PeersDiscovered.emit(
    self.brokerCtx, PeersDiscovered(origin: ExternalBackendId, key: key, peers: peers)
  )

proc runServiceLookupLoop(self: ExternalServiceDiscovery) {.async: (raises: []).} =
  ## Mirrors the internal backend: periodically resolves every registered
  ## interest and publishes what came back.
  while self.running:
    try:
      await sleepAsync(self.serviceLookupInterval)
    except CancelledError:
      return

    for key in self.interests:
      if not self.running:
        return
      let peers = (await self.lookupServicePeers(key, 0)).valueOr:
        debug "service lookup failed", key = key, reason = error
        continue
      self.emitPeers(key, peers)

proc runRandomLookupLoop(self: ExternalServiceDiscovery) {.async: (raises: []).} =
  while self.running:
    try:
      await sleepAsync(self.randomLookupInterval)
    except CancelledError:
      return

    if not self.running:
      return
    let peers = (await self.lookupRandom()).valueOr:
      debug "random lookup failed", reason = error
      continue
    self.emitPeers("", peers)

BrokerImplement ExternalServiceDiscovery of IPeerDiscovery:
  proc new(
      T: typedesc[ExternalServiceDiscovery],
      serviceLookupInterval = DefaultServiceLookupInterval,
      randomLookupInterval = DefaultRandomLookupInterval,
  ): ExternalServiceDiscovery =
    let self = ExternalServiceDiscovery(
      nodeCtx: globalBrokerContext(),
      serviceLookupInterval: serviceLookupInterval,
      randomLookupInterval: randomLookupInterval,
    )

    # Registration stays on the single-thread lane: the vtable is full of
    # pointer/proc fields, which the (mt) codec rejects, so it is handed to
    # the worker through the guarded global instead of a broker payload.
    discard SetServiceDiscoveryPlugin.reprovideIt(self.nodeCtx):
      ?plugin.validate()
      storePlugin(plugin)
      info "service discovery plugin installed", abiVersion = plugin.abiVersion
      ok()

    discard ClearServiceDiscoveryPlugin.reprovideIt(self.nodeCtx):
      dropPlugin()
      info "service discovery plugin cleared"
      ok()

    self

  method backendInfo(
      self: ExternalServiceDiscovery
  ): Future[Result[DiscoveryBackendInfo, string]] {.async.} =
    ok(
      DiscoveryBackendInfo(
        id: ExternalBackendId,
        running: self.running,
        keyKinds: @["svc", "shard", "cap"],
        boundPorts: @[],
      )
    )

  method startDiscovery(
      self: ExternalServiceDiscovery
  ): Future[Result[void, string]] {.async.} =
    if self.running:
      return ok()

    ?await startWorker(self.nodeCtx)
    ?pluginCall(void, "start", PluginStart.request(self.nodeCtx))

    self.running = true
    if self.serviceLookupLoop.isNil():
      self.serviceLookupLoop = self.runServiceLookupLoop()
    if self.randomLookupLoop.isNil():
      self.randomLookupLoop = self.runRandomLookupLoop()
    ok()

  method stopDiscovery(
      self: ExternalServiceDiscovery
  ): Future[Result[void, string]] {.async.} =
    if not self.running:
      return ok()
    self.running = false

    if not self.serviceLookupLoop.isNil():
      await self.serviceLookupLoop.cancelAndWait()
      self.serviceLookupLoop = nil
    if not self.randomLookupLoop.isNil():
      await self.randomLookupLoop.cancelAndWait()
      self.randomLookupLoop = nil

    ## The worker thread is deliberately left running: (mt) dispatch is bound
    ## to the thread that registered the providers, so tearing it down here
    ## would break a later restart. It is idle when no verb is in flight and
    ## is joined at process teardown via `stopWorker`.

    ## Telling the plugin to stop is best-effort. The host is free to clear the
    ## plugin before stopping the node, and a plugin that is gone has nothing
    ## left to stop -- the local side is stopped either way. Treating that as a
    ## failure would put an error in the log of a healthy shutdown.
    if loadPlugin().isNone():
      return ok()
    pluginCall(void, "stop", PluginStop.request(self.nodeCtx))

  method lookupServicePeers(
      self: ExternalServiceDiscovery, key: string, limit: int
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    if not self.running:
      return err("external backend: not running")
    pluginCall(
      seq[DiscoveredPeer], "lookup", PluginLookup.request(self.nodeCtx, key, limit)
    )

  method lookupRandom(
      self: ExternalServiceDiscovery
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    if not self.running:
      return err("external backend: not running")
    pluginCall(
      seq[DiscoveredPeer], "randomLookup", PluginRandomLookup.request(self.nodeCtx)
    )

  method startAdvertising(
      self: ExternalServiceDiscovery, key: string, data: seq[byte], record: seq[byte]
  ): Future[Result[void, string]] {.async.} =
    pluginCall(
      void,
      "startAdvertising",
      PluginStartAdvertising.request(self.nodeCtx, key, data, record),
    )

  method stopAdvertising(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    pluginCall(
      void, "stopAdvertising", PluginStopAdvertising.request(self.nodeCtx, key)
    )

  method registerInterest(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    ?pluginCall(
      void, "registerInterest", PluginRegisterInterest.request(self.nodeCtx, key)
    )
    if key notin self.interests:
      self.interests.add(key)
    ok()

  method unregisterInterest(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    ?pluginCall(
      void, "unregisterInterest", PluginUnregisterInterest.request(self.nodeCtx, key)
    )
    self.interests.keepItIf(it != key)
    ok()

  method addBootstrapEntries(
      self: ExternalServiceDiscovery, entries: seq[string]
  ): Future[Result[void, string]] {.async.} =
    if entries.len == 0:
      return ok()
    pluginCall(
      void,
      "addBootstrapEntries",
      PluginAddBootstrapEntries.request(self.nodeCtx, entries),
    )

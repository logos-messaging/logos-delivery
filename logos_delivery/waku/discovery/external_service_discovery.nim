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
  plugin: Opt[ServiceDiscoveryPlugin]
    ## Instance state, not a global: registration is served on this node's own
    ## thread, and the worker gets its own copy at spawn.
  worker: ServiceDiscoveryWorker
  nodeCtx: BrokerContext
  interests: seq[string]
  serviceLookupInterval: Duration
  randomLookupInterval: Duration
  serviceLookupLoop: Future[void]
  randomLookupLoop: Future[void]

proc readyPlugin(
    self: ExternalServiceDiscovery
): Result[ServiceDiscoveryPlugin, string] =
  ## External discovery needs both halves: the node configured for it (which
  ## is what created this backend) and a registered, fully populated plugin.
  ## No re-validation: the vtable was validated when it was registered and is
  ## immutable afterwards, so there is no later moment for it to go partial.
  let plugin = self.plugin.valueOr:
    return
      err("external backend: configured but no service discovery plugin registered")
  ok(plugin)

template pluginCall(T: typedesc, op: string, request: untyped): untyped =
  ## Awaits one (mt) plugin request, bounded by the timeout the plugin
  ## declared at registration. The worker is not interrupted on timeout —
  ## the entry point runs to completion there — the caller just stops waiting.
  ## `T` is the payload type, so every branch stays correctly typed; the
  ## template yields a value rather than returning, which keeps it usable
  ## inside the async transform.
  block:
    let plugRes = readyPlugin(self)
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
      worker: ServiceDiscoveryWorker.new(),
      serviceLookupInterval: serviceLookupInterval,
      randomLookupInterval: randomLookupInterval,
    )

    # Registration stays on the single-thread lane: the vtable is full of
    # pointer/proc fields, which the (mt) codec rejects, so it is handed to
    # the worker through the guarded global instead of a broker payload.
    #
    # Both verbs are only legal while discovery is stopped. A running backend
    # has a worker thread calling into the vtable, so swapping or removing it
    # underneath would change which plugin serves calls already in flight. A
    # registration outlives stop/start: install once, then start and stop as
    # often as you like.
    let nodeCtx = self.nodeCtx
    discard SetServiceDiscoveryPlugin.reprovideIt(nodeCtx):
      if self.running:
        return err(
          "service discovery plugin: cannot be registered while discovery is " &
            "running; stop the node first"
        )
      ?plugin.validate()
      self.plugin = Opt.some(plugin)
      info "service discovery plugin installed",
        abiVersion = plugin.abiVersion, ctx = $nodeCtx
      ok()

    discard ClearServiceDiscoveryPlugin.reprovideIt(nodeCtx):
      if self.running:
        return err(
          "service discovery plugin: cannot be cleared while discovery is " &
            "running; stop the node first"
        )
      self.plugin = Opt.none(ServiceDiscoveryPlugin)
      info "service discovery plugin cleared", ctx = $nodeCtx
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

    ## A valid plugin is a hard requirement, checked before anything is
    ## spawned: external discovery that is configured but has no usable plugin
    ## is not a degraded node, it is a node with no discovery at all, so it
    ## must fail loudly rather than come up quietly.
    let plugin = readyPlugin(self).valueOr:
      return err(error)

    ## The worker gets the vtable by value, so nothing is shared and there is
    ## nothing to look up on the far side.
    ?await self.worker.start(self.nodeCtx, plugin)
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

    ## The plugin is still there: `startDiscovery` required one, and clearing
    ## is refused while discovery runs, so there is nothing to guard against.
    let stopRes = pluginCall(void, "stop", PluginStop.request(self.nodeCtx))

    ## The worker exists to serve this discovery session, so it goes with it.
    ## Its thread hands the (mt) buckets back on the way out, which is what
    ## lets a later `startDiscovery` spawn a fresh one on the same context.
    self.worker.stop()
    stopRes

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
    ## No-op by design. The external provider takes its bootstrap entries when
    ## it initialises, and libp2p offers no call to add more afterwards, so
    ## there is no plugin entry point to forward these to. Succeeding rather
    ## than failing keeps the node's bootstrap wiring uniform across backends:
    ## the caller has nothing to do differently for this one.
    if entries.len > 0:
      debug "external backend takes bootstrap entries at provider init, ignoring",
        count = entries.len
    ok()

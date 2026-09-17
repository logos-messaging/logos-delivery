{.push raises: [].}

## IPeerDiscovery backed by an external discovery host (today:
## logos-libp2p-module, driven by glue in logos-delivery-module).
##
## Shape-wise this is the twin of the internal `ServiceDiscovery` backend:
## fully async verbs plus periodic lookup loops. The difference is only where
## the work happens: every verb is emitted as a `ServiceDiscoveryHostRequest`
## and awaited until the host settles it through
## `CompleteServiceDiscoveryRequest`, bounded by `requestTimeout`. The node's
## loop never blocks on the host, and no thread is involved.
##
## The one thing this backend does that the internal one does not: it signs
## this node's own peer record before advertising, because the host's
## discovery node is not this node.

import std/[sequtils, strutils, tables]
import chronos, chronicles, results
import brokers/broker_implement
import
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/discovery/peer_discovery_conversion,
  logos_delivery/waku/discovery/external_discovery_host,
  logos_delivery/waku/discovery/signed_service_record,
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/waku_core/peers,
  logos_delivery/waku/requests/node_state_requests

export peer_discovery_interface, external_discovery_host

logScope:
  topics = "waku discovery external"

const
  ExternalBackendId* = "service-ext"
  DefaultServiceLookupInterval* = chronos.seconds(60)
  DefaultRandomLookupInterval* = chronos.seconds(60)
  DefaultHostRequestTimeout* = chronos.seconds(30)
  HostStopTimeout = chronos.seconds(2)
    ## `stop` also runs inside the FFI destructor, which nim-ffi cancels after
    ## 10 s and during which it processes no completion at all.

type HostReply = Future[Result[string, string]]

type ExternalServiceDiscovery* = ref object of IPeerDiscovery
  running: bool
  stops: uint64
    ## Bumped by every `stopDiscovery`, so a `start` whose host reply was
    ## already in when a stop ran still sees that stop.
  nodeCtx: BrokerContext
    ## Where the host requests are emitted and completed: the node's context,
    ## which is the one the library bridges onto FFI.
  requestTimeout: Duration
  nextRequestId: uint64
  pending: Table[uint64, HostReply]
  interests: seq[string]
  serviceLookupInterval: Duration
  randomLookupInterval: Duration
  serviceLookupLoop: Future[void]
  randomLookupLoop: Future[void]

proc hostCall(
    self: ExternalServiceDiscovery,
    verb: ServiceDiscoveryVerb,
    key = "",
    limit = 0,
    data: seq[byte] = @[],
    record: seq[byte] = @[],
    timeout = ZeroDuration,
): Future[Result[string, string]] {.async: (raises: []).} =
  let timeout = if timeout == ZeroDuration: self.requestTimeout else: timeout
  inc self.nextRequestId
  let id = self.nextRequestId
  let reply = HostReply.init("external discovery host call")
  self.pending[id] = reply
  defer:
    self.pending.del(id)

  ServiceDiscoveryHostRequest.emit(
    self.nodeCtx,
    ServiceDiscoveryHostRequest(
      requestId: id,
      verb: verb,
      key: key,
      limit: limit,
      data: data,
      record: record,
      timeoutMs: timeout.milliseconds,
    ),
  )

  let answered =
    try:
      await reply.withTimeout(timeout)
    except CancelledError:
      return err("external backend: " & $verb & " cancelled")
  if not answered:
    return err("external backend: host did not answer " & $verb & " in time")

  try:
    return reply.read()
  except CatchableError:
    return err("external backend: " & $verb & " failed: " & getCurrentExceptionMsg())

proc hostCallVoid(
    self: ExternalServiceDiscovery,
    verb: ServiceDiscoveryVerb,
    key = "",
    timeout = ZeroDuration,
): Future[Result[void, string]] {.async: (raises: []).} =
  discard ?(await self.hostCall(verb, key, timeout = timeout))
  return ok()

proc hostLookup(
    self: ExternalServiceDiscovery, verb: ServiceDiscoveryVerb, key = "", limit = 0
): Future[Result[seq[DiscoveredPeer], string]] {.async: (raises: []).} =
  let payload = ?(await self.hostCall(verb, key, limit))
  return parsePeers(payload)

proc failPending(self: ExternalServiceDiscovery, reason: string) =
  for reply in toSeq(self.pending.values):
    if not reply.finished():
      reply.complete(Result[string, string].err(reason))

proc feedPeerManager(self: ExternalServiceDiscovery, peers: seq[DiscoveredPeer]) =
  ## The host has no handle on the node, so the peers it found reach the
  ## PeerManager from here, as the in-process kademlia does for its own.
  let pm = GetNodePeerManager.request(self.nodeCtx).valueOr:
    debug "no peer manager to feed external discovery results", reason = error
    return
  for peer in peers:
    let info = peer.toRemotePeerInfo(PeerOrigin.External).valueOr:
      debug "skipping undialable discovered peer", peerId = peer.peerId, reason = error
      continue
    pm.addPeer(info, PeerOrigin.External)

proc emitPeers(
    self: ExternalServiceDiscovery, key: string, peers: seq[DiscoveredPeer]
) =
  if peers.len == 0:
    return
  self.feedPeerManager(peers)
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

    # A copy: interests can change while a lookup is awaited.
    let keys = self.interests
    for key in keys:
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
      requestTimeout = DefaultHostRequestTimeout,
  ): ExternalServiceDiscovery =
    let self = ExternalServiceDiscovery(
      nodeCtx: globalBrokerContext(),
      requestTimeout: requestTimeout,
      serviceLookupInterval: serviceLookupInterval,
      randomLookupInterval: randomLookupInterval,
    )

    discard CompleteServiceDiscoveryRequest.reprovideIt(self.nodeCtx):
      let reply = self.pending.getOrDefault(requestId)
      if reply.isNil() or reply.finished():
        return
          err("external backend: unknown or expired discovery request " & $requestId)
      if success:
        reply.complete(Result[string, string].ok(payload))
      else:
        reply.complete(Result[string, string].err(payload))
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

    ## A host that answers `start` is a hard requirement: configured external
    ## discovery without one is a node with no discovery at all, so it must
    ## fail loudly rather than come up quietly.
    let stops = self.stops
    ?(await self.hostCallVoid(ServiceDiscoveryVerb.start))
    if self.stops != stops:
      return err("external backend: discovery stopped while starting")

    self.running = true
    if self.serviceLookupLoop.isNil():
      self.serviceLookupLoop = self.runServiceLookupLoop()
    if self.randomLookupLoop.isNil():
      self.randomLookupLoop = self.runRandomLookupLoop()
    ok()

  method stopDiscovery(
      self: ExternalServiceDiscovery
  ): Future[Result[void, string]] {.async.} =
    ## Nothing waits for answers to a stopped session: release every caller,
    ## a `start` still waiting on the host included, now rather than after
    ## their own timeouts.
    inc self.stops
    self.failPending("external backend: discovery stopped")
    if not self.running:
      return ok()
    self.running = false

    if not self.serviceLookupLoop.isNil():
      await self.serviceLookupLoop.cancelAndWait()
      self.serviceLookupLoop = nil
    if not self.randomLookupLoop.isNil():
      await self.randomLookupLoop.cancelAndWait()
      self.randomLookupLoop = nil

    await self.hostCallVoid(
      ServiceDiscoveryVerb.stop, timeout = min(self.requestTimeout, HostStopTimeout)
    )

  method lookupServicePeers(
      self: ExternalServiceDiscovery, key: string, limit: int
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    if not self.running:
      return err("external backend: not running")
    await self.hostLookup(ServiceDiscoveryVerb.lookup, key, limit)

  method lookupRandom(
      self: ExternalServiceDiscovery
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    if not self.running:
      return err("external backend: not running")
    await self.hostLookup(ServiceDiscoveryVerb.randomLookup)

  method startAdvertising(
      self: ExternalServiceDiscovery, key: string, data: seq[byte]
  ): Future[Result[void, string]] {.async.} =
    ## The host's discovery node is not this node: left to itself it would
    ## publish its own identity under our service. So sign a record for this
    ## node listing exactly this service, and let the host publish it
    ## verbatim. Identity and key come from the node-state getters, the way
    ## the discv5 backend gets its ENR and key.
    if not key.startsWith(SvcKeyPrefix):
      return err("external backend: only svc: keys can be advertised")
    let serviceId = key[SvcKeyPrefix.len ..^ 1]
    let peerInfo = ?GetNodePeerInfo.request(self.nodeCtx)
    let nodeKey = ?GetNodeKey.request(self.nodeCtx)
    let record = ?signedServiceRecord(peerInfo, nodeKey, serviceId, data)
    discard ?(
      await self.hostCall(
        ServiceDiscoveryVerb.startAdvertising, key, data = data, record = record
      )
    )
    ok()

  method stopAdvertising(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    await self.hostCallVoid(ServiceDiscoveryVerb.stopAdvertising, key)

  method registerInterest(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    ?(await self.hostCallVoid(ServiceDiscoveryVerb.registerInterest, key))
    if key notin self.interests:
      self.interests.add(key)
    ok()

  method unregisterInterest(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    ?(await self.hostCallVoid(ServiceDiscoveryVerb.unregisterInterest, key))
    self.interests.keepItIf(it != key)
    ok()

  method addBootstrapEntries(
      self: ExternalServiceDiscovery, entries: seq[string]
  ): Future[Result[void, string]] {.async.} =
    ## No-op by design. The host takes its bootstrap entries when it
    ## initialises (see `logosdelivery_get_discovery_requirements`), and libp2p
    ## offers no call to add more afterwards. Succeeding rather than failing
    ## keeps the node's bootstrap wiring uniform across backends.
    if entries.len > 0:
      debug "external backend takes bootstrap entries at host init, ignoring",
        count = entries.len
    ok()

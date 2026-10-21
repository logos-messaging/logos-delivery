{.push raises: [].}

## IPeerDiscovery backed by an external service-discovery plugin (today:
## logos-libp2p-module, driven by glue in logos-delivery-module).
##
## Shape-wise this is the twin of the internal `ServicePeerDiscovery` backend:
## fully async verbs plus periodic lookup loops. The difference is only where
## the work happens — every plugin call is a request on `IServiceDiscoveryHost`,
## which the host answers asynchronously, so a 30 s DHT bootstrap never blocks
## the node's event loop.
##
## The one thing this backend does that the internal one does not: it signs
## this node's own peer record before advertising, because the provider's
## discovery node is not this node. That is its only libp2p dependency.
##
## Adverts and interests are kept as what the node wants, not sent once. The
## node cannot tell when the provider is ready -- a plugin can start before its
## libp2p switch has, and libp2p then refuses both -- so a loop hands them to
## the plugin and retries until each is taken.

import std/[sequtils, strutils, tables]
import chronos, chronicles, results
import brokers/broker_implement
import libp2p/peerinfo
import
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/discovery/peer_discovery_conversion,
  logos_delivery/waku/discovery/signed_service_record,
  logos_delivery/waku/requests/node_state_requests,
  logos_delivery/waku/discovery/service_discovery_host,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/node/peer_manager/peer_manager

export peer_discovery_interface, service_discovery_host

logScope:
  topics = "waku discovery external"

const
  ExternalBackendId* = "service-ext"
  DefaultServiceLookupInterval* = chronos.seconds(60)
  DefaultRandomLookupInterval* = chronos.seconds(60)
  AnnounceBackoffMin = chronos.seconds(1)
  AnnounceBackoffMax = chronos.seconds(60)
    ## Retry schedule for what the plugin has not taken yet. The provider is
    ## local to this node, so there is no herd to spread and no jitter.
  AlreadyAdvertised = "already advertised"
    ## libp2p's refusal of a service it already advertises
    ## (`addProvidedService`), passed through verbatim by the plugin. Host
    ## errors are plain text, so this text is the only signal that the plugin
    ## holds the key -- for instance after a call that timed out on our side
    ## but completed there. Should libp2p reword it, the key is retried and
    ## warned about, never silently left stale.

type Advert = object
  data: seq[byte]
  taken: bool ## the plugin holds this advert; no call until something changes
  resign: bool
    ## The plugin may hold an older record for the key -- the node's addresses
    ## or `data` changed, or this is a new session -- so it is stopped before it
    ## is sent, and "already advertised" does not count as taken.
  version: int ## bumped on every change, so a reply to an older send is ignored

type ExternalServiceDiscovery* = ref object of IPeerDiscovery
  running: bool
  nodeCtx: BrokerContext
    ## The node's context: its state getters and the `IServiceDiscoveryHost`
    ## the library installs live there.
  adverts: Table[string, Advert]
  interests: Table[string, bool] ## key -> taken by the plugin
  announceWanted: AsyncEvent
  announceLoop: Future[void]
  observedPeerInfo: PeerInfo
  addressObserver: PeerInfoObserver
    ## Set while running: the plugin publishes the record it was handed and
    ## never refreshes it, so adverts are re-signed when the addresses move.
  serviceLookupInterval: Duration
  randomLookupInterval: Duration
  serviceLookupLoop: Future[void]
  randomLookupLoop: Future[void]

proc admitPeers(self: ExternalServiceDiscovery, peers: seq[DiscoveredPeer]) =
  ## Hands discovered peers to the PeerManager, which decides what to dial.
  ## The in-process backend does this inside `processRecords`, so every lookup
  ## feeds the node; this backend has to do it here, because the plugin runs
  ## on its own switch and nothing else sees what it found. The
  ## `PeersDiscovered` event is observability only and reaches no peer store.
  ##
  ## Peers are stored under `PeerOrigin.Kademlia`: the protocol is the same
  ## kademlia service discovery either way, only its host differs.
  if peers.len == 0:
    return

  let peerManager = GetNodePeerManager.request(self.nodeCtx).valueOr:
    debug "peer manager unreachable, discovered peers dropped",
      count = peers.len, reason = error
    return

  for peer in peers:
    let peerInfo = peer.toRemotePeerInfo().valueOr:
      debug "discarding discovered peer", reason = error
      continue

    peerManager.addPeer(peerInfo, PeerOrigin.Kademlia)

    debug "Peer added via external service discovery",
      peerId = $peerInfo.peerId,
      addresses = peerInfo.addrs.mapIt($it),
      protocols = peerInfo.protocols

proc pendingAnnouncements*(self: ExternalServiceDiscovery): int =
  ## Adverts and interests the plugin has not taken yet. Zero means the
  ## announce loop is parked: it calls the plugin again only when a verb or an
  ## address change wakes it.
  var pending = 0
  for advert in self.adverts.values():
    if not advert.taken:
      inc pending
  for taken in self.interests.values():
    if not taken:
      inc pending
  pending

proc emitPeers(
    self: ExternalServiceDiscovery, key: string, peers: seq[DiscoveredPeer]
) =
  if peers.len == 0:
    return
  PeersDiscovered.emit(
    self.brokerCtx, PeersDiscovered(origin: ExternalBackendId, key: key, peers: peers)
  )

const EagerLookupDelays = [chronos.seconds(2), chronos.seconds(4), chronos.seconds(8)]
  ## Startup schedule for the first service lookups, before the configured
  ## interval takes over. The same schedule as the in-process backend.

proc runServiceLookupLoop(self: ExternalServiceDiscovery) {.async: (raises: []).} =
  ## Mirrors the internal backend: periodically resolves every registered
  ## interest and publishes what came back. The opening rounds run on the
  ## eager schedule, so a fresh node does not sit peerless for a whole
  ## interval before asking anyone.
  var attempt = 0
  while self.running:
    let delay =
      if attempt < EagerLookupDelays.len:
        EagerLookupDelays[attempt]
      else:
        self.serviceLookupInterval
    try:
      await sleepAsync(delay)
    except CancelledError:
      return

    var found = 0
    ## Every wanted key, taken by the plugin or not: a lookup does not need the
    ## interest, which only pre-warms the provider's table.
    for key in toSeq(self.interests.keys()):
      if not self.running:
        return
      let peers = (await self.lookupServicePeers(key, 0)).valueOr:
        debug "service lookup failed", key = key, reason = error
        continue
      found += peers.len
      self.emitPeers(key, peers)

    if attempt < EagerLookupDelays.len:
      ## One round that found peers ends the eager phase; an empty or failed
      ## one waits the next, longer delay. A failure counts as empty: both
      ## mean "nothing yet", and splitting them buys a second retry policy
      ## for no gain.
      attempt =
        if found > 0:
          EagerLookupDelays.len
        else:
          attempt + 1

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

proc signRecord(
    self: ExternalServiceDiscovery, key: string, data: seq[byte]
): Result[seq[byte], string] =
  ## This node's record listing exactly this service, from its current
  ## identity and addresses. Identity and key come from the node-state getters,
  ## the way the discv5 backend gets its ENR and key.
  let serviceId = key[ServiceKeyPrefix.len ..^ 1]
  let peerInfo = ?GetNodePeerInfo.request(self.nodeCtx)
  let nodeKey = ?GetNodeKey.request(self.nodeCtx)
  signedServiceRecord(peerInfo, nodeKey, serviceId, data)

proc resignAll(self: ExternalServiceDiscovery) =
  ## Every advert is handed to the plugin again, stopped first and signed
  ## afresh.
  for advert in self.adverts.mvalues():
    advert.taken = false
    advert.resign = true
    inc advert.version
  self.announceWanted.fire()

proc observeAddresses(self: ExternalServiceDiscovery) =
  ## Libp2p calls observers after a commit that changed the node's addresses.
  let peerInfo = GetNodePeerInfo.request(self.nodeCtx).valueOr:
    debug "node peer info unreachable, adverts will not follow address changes",
      reason = error
    return
  if peerInfo.isNil():
    return
  self.addressObserver = proc(p: PeerInfo) {.gcsafe, raises: [].} =
    if self.running and self.adverts.len > 0:
      debug "node addresses changed, re-signing external adverts",
        adverts = self.adverts.len
      self.resignAll()
  self.observedPeerInfo = peerInfo
  peerInfo.addObserver(self.addressObserver)

proc unobserveAddresses(self: ExternalServiceDiscovery) =
  if not self.observedPeerInfo.isNil():
    self.observedPeerInfo.removeObserver(self.addressObserver)
  self.observedPeerInfo = nil
  self.addressObserver = nil

proc sendAdvert(
    self: ExternalServiceDiscovery, key: string, advert: Advert
): Future[Result[void, string]] {.async: (raises: []).} =
  ## The plugin's discovery node is not this node: left to itself it would
  ## publish its own identity under our service. So it gets a record signed
  ## here, from the node's current addresses, and publishes it verbatim.
  let record = ?self.signRecord(key, advert.data)
  if advert.resign:
    ## Its failure is not fatal: the start below says whether the plugin
    ## still holds an older record.
    (await HostStopAdvertising.request(self.nodeCtx, key)).isOkOr:
      debug "external discovery could not stop the advert before re-sending it",
        key = key, reason = error
  let res = await HostStartAdvertising.request(self.nodeCtx, key, advert.data, record)
  if res.isErr() and not advert.resign and AlreadyAdvertised in res.error:
    return ok()
  res

proc announcePending(
    self: ExternalServiceDiscovery
): Future[bool] {.async: (raises: []).} =
  ## Sends every advert and interest the plugin has not taken. True when it
  ## has taken them all.
  var allTaken = true

  for key in toSeq(self.adverts.keys()):
    if not self.running:
      return false
    ## The keys are a snapshot: one may have been stopped during an earlier
    ## call of this pass, and must not be sent as a default entry.
    if key notin self.adverts:
      continue
    let advert = self.adverts.getOrDefault(key)
    if advert.taken:
      continue
    let res = await self.sendAdvert(key, advert)
    ## Changed or dropped while the call was out: that change woke the loop,
    ## and this reply is about a version nobody wants any more.
    self.adverts.withValue(key, cur):
      if cur.version == advert.version:
        if res.isOk():
          cur.taken = true
          cur.resign = false
          info "external discovery took the advert", key = key
        else:
          allTaken = false
          debug "external discovery refused the advert, will retry",
            key = key, reason = res.error

  for key in toSeq(self.interests.keys()):
    if not self.running:
      return false
    if key notin self.interests or self.interests.getOrDefault(key):
      continue
    let res = await HostRegisterInterest.request(self.nodeCtx, key)
    if key notin self.interests:
      continue
    if res.isOk():
      self.interests[key] = true
      info "external discovery took the interest", key = key
    else:
      allTaken = false
      debug "external discovery refused the interest, will retry",
        key = key, reason = res.error

  allTaken

proc runAnnounceLoop(self: ExternalServiceDiscovery) {.async: (raises: []).} =
  ## Sends what the plugin has not taken, then sleeps until something changes.
  ## While the plugin refuses, it retries on a doubling backoff; a change
  ## wakes it and starts the backoff over. Warns once when the backoff reaches
  ## its cap: a healthy provider takes everything well before that.
  var backoff = AnnounceBackoffMin
  var warned = false
  while self.running:
    self.announceWanted.clear()
    let allTaken = await self.announcePending()
    try:
      if allTaken:
        backoff = AnnounceBackoffMin
        warned = false
        await self.announceWanted.wait()
      elif await self.announceWanted.wait().withTimeout(backoff):
        backoff = AnnounceBackoffMin
      else:
        backoff = min(backoff * 2, AnnounceBackoffMax)
        if backoff == AnnounceBackoffMax and not warned:
          warned = true
          warn "external discovery keeps refusing adverts or interests, retrying",
            every = AnnounceBackoffMax
    except CancelledError:
      return

BrokerImplement ExternalServiceDiscovery of IPeerDiscovery:
  proc new(
      T: typedesc[ExternalServiceDiscovery],
      serviceLookupInterval = DefaultServiceLookupInterval,
      randomLookupInterval = DefaultRandomLookupInterval,
  ): ExternalServiceDiscovery =
    ExternalServiceDiscovery(
      nodeCtx: globalBrokerContext(),
      announceWanted: newAsyncEvent(),
      serviceLookupInterval: serviceLookupInterval,
      randomLookupInterval: randomLookupInterval,
    )

  method backendInfo(
      self: ExternalServiceDiscovery
  ): Future[Result[DiscoveryBackendInfo, string]] {.async.} =
    ok(
      DiscoveryBackendInfo(
        id: ExternalBackendId,
        running: self.running,
        keyKinds: @["service", "topic", "cap"],
        boundPorts: @[],
      )
    )

  method startDiscovery(
      self: ExternalServiceDiscovery
  ): Future[Result[void, string]] {.async.} =
    if self.running:
      return ok()

    ## A host that implements the whole interface is a hard requirement,
    ## checked before anything is called: external discovery that is
    ## configured but has no usable host is not a degraded node, it is a node
    ## with no discovery at all, so it must fail loudly rather than come up
    ## quietly. No host installed fails the same way, as "no provider".
    (await HostCheck.request(self.nodeCtx)).isOkOr:
      return err("external backend: " & error)

    ## Each host verb carries its own deadline (the library's reverse-call
    ## timeout), and a call that outlives it is dropped there, so nothing here
    ## waits on a host that went quiet.
    ?(await HostStart.request(self.nodeCtx))

    self.running = true

    ## A new session: everything wanted, including what a verb recorded before
    ## this start, is handed over again. libp2p outlives our session, so it may
    ## still hold a record from the last one, with old addresses.
    for taken in self.interests.mvalues():
      taken = false
    self.resignAll()
    if self.observedPeerInfo.isNil():
      self.observeAddresses()
    if self.announceLoop.isNil():
      self.announceLoop = self.runAnnounceLoop()

    if self.serviceLookupLoop.isNil():
      self.serviceLookupLoop = self.runServiceLookupLoop()

    ## Same rule as the in-process backend: a zero interval, the default,
    ## leaves the random walk off. Hosted discovery makes it worse than
    ## useless -- the records it returns name the plugin's own host, never
    ## the delivery node it advertises for.
    if self.randomLookupInterval > ZeroDuration:
      if self.randomLookupLoop.isNil():
        self.randomLookupLoop = self.runRandomLookupLoop()
    else:
      info "Random kademlia lookups disabled"
    ok()

  method stopDiscovery(
      self: ExternalServiceDiscovery
  ): Future[Result[void, string]] {.async.} =
    if not self.running:
      return ok()
    self.running = false

    self.unobserveAddresses()
    ## First, so none of their calls lands after the host's stop.
    if not self.announceLoop.isNil():
      await self.announceLoop.cancelAndWait()
      self.announceLoop = nil
    if not self.serviceLookupLoop.isNil():
      await self.serviceLookupLoop.cancelAndWait()
      self.serviceLookupLoop = nil
    if not self.randomLookupLoop.isNil():
      await self.randomLookupLoop.cancelAndWait()
      self.randomLookupLoop = nil

    return await HostStop.request(self.nodeCtx)

  method lookupServicePeers(
      self: ExternalServiceDiscovery, key: string, limit: int
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    if not self.running:
      return err("external backend: not running")
    let peers = ?(await HostLookup.request(self.nodeCtx, key, limit))
    self.admitPeers(peers)
    ok(peers)

  method lookupRandom(
      self: ExternalServiceDiscovery
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    if not self.running:
      return err("external backend: not running")
    let peers = ?(await HostRandomLookup.request(self.nodeCtx))
    self.admitPeers(peers)
    ok(peers)

  method startAdvertising(
      self: ExternalServiceDiscovery, key: string, data: seq[byte]
  ): Future[Result[void, string]] {.async.} =
    ## Ok means taken on, not yet published: the announce loop hands it to the
    ## plugin and logs when the plugin takes it. What can never succeed is
    ## refused here instead of being kept.
    if not key.startsWith(ServiceKeyPrefix):
      return err("external backend: only service: keys can be advertised")
    ## Signed now only to refuse a node with no identity to sign with; the
    ## record sent is signed when it is sent.
    self.signRecord(key, data).isOkOr:
      return err("external backend: cannot sign advert for: " & key & ": " & error)
    self.adverts.withValue(key, advert):
      if advert.data != data:
        ## The plugin holds the old data under this key.
        advert.data = data
        advert.taken = false
        advert.resign = true
        inc advert.version
    do:
      self.adverts[key] = Advert(data: data)
    self.announceWanted.fire()
    ok()

  method stopAdvertising(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    ## Best effort: a plugin that is not up yet cannot hold the advert either.
    self.adverts.del(key)
    if self.running:
      (await HostStopAdvertising.request(self.nodeCtx, key)).isOkOr:
        debug "external discovery could not stop the advert", key = key, reason = error
    ok()

  method registerInterest(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    ## Ok means taken on; see `startAdvertising`.
    if key notin self.interests:
      self.interests[key] = false
      self.announceWanted.fire()
    ok()

  method unregisterInterest(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    ## Best effort, like `stopAdvertising`.
    self.interests.del(key)
    if self.running:
      (await HostUnregisterInterest.request(self.nodeCtx, key)).isOkOr:
        debug "external discovery could not unregister the interest",
          key = key, reason = error
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

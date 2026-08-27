{.push raises: [].}

## IPeerDiscovery implementation wrapping `WakuDiscoveryV5`. Phase 1: the
## wrapped entity keeps its ENR/subscription plumbing and feeds the
## PeerManager itself; this wrapper owns construction and lifecycle,
## resolving node state through the getter brokers instead of constructor
## injection.

import std/[sequtils, strutils]
import chronos, chronicles, results
import libp2p/crypto/crypto
import brokers/broker_implement
import logos_delivery/waku/discovery/peer_discovery_interface
import
  logos_delivery/waku/discovery/waku_discv5,
  logos_delivery/waku/discovery/peer_discovery_conversion,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_enr,
  logos_delivery/waku/api/events/discovery_events,
  logos_delivery/waku/requests/node_state_requests

export peer_discovery_interface

logScope:
  topics = "waku discovery discv5"

const
  Discv5BackendId* = "discv5"
  CapKeyPrefix = "cap:"
  ShardKeyPrefix = "shard:"

type Discv5PeerDiscovery* = ref object of IPeerDiscovery
  conf: Discv5Conf
  listenAddress: IpAddress
  rng: crypto.Rng
  nodeCtx: BrokerContext
    ## Captured from globalBrokerContext() at construction — the node's
    ## context, where the node-state getter providers live (the instance's
    ## own brokerCtx scopes the interface brokers).
  inner*: WakuDiscoveryV5
  running: bool
  subscriptionLoop: Future[void]

proc runSubscriptionListener(
    self: Discv5PeerDiscovery, queue: AsyncEventQueue[SubscriptionEvent]
) {.async.} =
  ## Consumes relay/filter shard subscription changes and mirrors them into
  ## the discv5 ENR (moved here from WakuDiscoveryV5's internal listener).
  let key = queue.register()
  defer:
    queue.unregister(key)

  while self.running:
    let events = await queue.waitEvents(key)

    let subs = events.filterIt(it.kind == PubsubSub).mapIt(it.topic)
    let unsubs = events.filterIt(it.kind == PubsubUnsub).mapIt(it.topic)

    if unsubs.len > 0:
      self.inner.updateShards(unsubs, add = false).isOkOr:
        debug "ENR shard removal failed", reason = error
    if subs.len > 0:
      self.inner.updateShards(subs, add = true).isOkOr:
        debug "ENR shard addition failed", reason = error

proc keyPredicate(key: string): Result[Opt[WakuDiscv5Predicate], string] =
  ## Maps a criteria key onto an ENR record predicate.
  if key.len == 0:
    return ok(Opt.none(WakuDiscv5Predicate))

  if key.startsWith(CapKeyPrefix):
    let capName = key[CapKeyPrefix.len ..^ 1]
    var wanted: Opt[Capabilities]
    for cap in Capabilities:
      if cmpIgnoreCase($cap, capName) == 0:
        wanted = Opt.some(cap)
        break
    let cap = wanted.valueOr:
      return err("discv5 backend: unknown capability: " & capName)
    let pred = proc(record: waku_enr.Record): bool {.closure, gcsafe, raises: [].} =
      record.supportsCapability(cap)
    return ok(Opt.some(WakuDiscv5Predicate(pred)))

  if key.startsWith(ShardKeyPrefix):
    let parts = key[ShardKeyPrefix.len ..^ 1].split('/')
    if parts.len != 2:
      return err("discv5 backend: expected shard:<cluster>/<shard>: " & key)
    let (clusterId, shardId) =
      try:
        (uint16(parseUInt(parts[0])), uint16(parseUInt(parts[1])))
      except ValueError:
        return err("discv5 backend: invalid shard key: " & key)
    let pred = proc(record: waku_enr.Record): bool {.closure, gcsafe, raises: [].} =
      record.containsShard(clusterId, shardId)
    return ok(Opt.some(WakuDiscv5Predicate(pred)))

  err("discv5 backend: unsupported criteria key: " & key)

proc shardKeyToPubsubTopic(key: string): Result[PubsubTopic, string] =
  ## "shard:<cluster>/<shard>" -> "/waku/2/rs/<cluster>/<shard>"
  if not key.startsWith(ShardKeyPrefix):
    return err("discv5 backend: only shard: keys can be advertised, got: " & key)
  let parts = key[ShardKeyPrefix.len ..^ 1].split('/')
  if parts.len != 2:
    return err("discv5 backend: expected shard:<cluster>/<shard>: " & key)
  try:
    ok(
      $RelayShard(
        clusterId: uint16(parseUInt(parts[0])), shardId: uint16(parseUInt(parts[1]))
      )
    )
  except ValueError:
    err("discv5 backend: invalid shard key: " & key)

BrokerImplement Discv5PeerDiscovery of IPeerDiscovery:
  proc new(
      T: typedesc[Discv5PeerDiscovery],
      conf: Discv5Conf,
      listenAddress: IpAddress,
      rng: crypto.Rng,
  ): Discv5PeerDiscovery =
    let self = Discv5PeerDiscovery(
      conf: conf, listenAddress: listenAddress, rng: rng, nodeCtx: globalBrokerContext()
    )

    # Bridge the node-level event onto the instance-scoped interface event.
    # The wrapper lives as long as the node, so the listener is never dropped.
    discard PeersDiscoveredEvent.listen(
      proc(ev: PeersDiscoveredEvent): Future[void] {.async: (raises: []), gcsafe.} =
        let mine = ev.peers.filterIt(it.origin == PeerOrigin.Discv5)
        if mine.len > 0:
          let converted = mine.mapIt(it.toDiscoveredPeer())
          PeersDiscovered.emit(
            self.brokerCtx,
            PeersDiscovered(origin: Discv5BackendId, key: "", peers: converted),
          )
    )

    self

  method backendInfo(
      self: Discv5PeerDiscovery
  ): Future[Result[DiscoveryBackendInfo, string]] {.async.} =
    let boundPorts =
      if self.running:
        @[self.inner.udpPort().uint16]
      else:
        newSeq[uint16]()
    ok(
      DiscoveryBackendInfo(
        id: Discv5BackendId,
        running: self.running,
        keyKinds: @["shard", "cap", ""],
        boundPorts: boundPorts,
      )
    )

  method startDiscovery(
      self: Discv5PeerDiscovery
  ): Future[Result[void, string]] {.async.} =
    if self.running:
      return ok()

    ## Node state is resolved through the getter brokers; by the time the
    ## node start sequence reaches discovery the providers are installed.
    let enrRecord = ?GetNodeEnr.request(self.nodeCtx)
    let peerManager = ?GetNodePeerManager.request(self.nodeCtx)
    let subscriptionQueue = ?GetTopicSubscriptionQueue.request(self.nodeCtx)
    let dynamicBootstrapNodes = ?GetDynamicBootstrapNodes.request(self.nodeCtx)
    let nodeKey = ?GetNodeKey.request(self.nodeCtx)

    self.inner = ?await setupAndStartDiscv5(
      enrRecord, peerManager, self.conf, dynamicBootstrapNodes, self.rng, nodeKey,
      self.listenAddress,
    )
    self.running = true
    self.subscriptionLoop = self.runSubscriptionListener(subscriptionQueue)
    ok()

  method stopDiscovery(
      self: Discv5PeerDiscovery
  ): Future[Result[void, string]] {.async.} =
    if not self.running:
      return ok()
    self.running = false
    if not self.subscriptionLoop.isNil():
      await self.subscriptionLoop.cancelAndWait()
      self.subscriptionLoop = nil
    try:
      await self.inner.stop()
    except CatchableError:
      return err("discv5 backend: stop failed: " & getCurrentExceptionMsg())
    ok()

  method lookupServicePeers(
      self: Discv5PeerDiscovery, key: string, limit: int
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    if not self.running:
      return err("discv5 backend: not running")
    let pred = ?keyPredicate(key)

    let records =
      try:
        await self.inner.findRandomPeers(pred)
      except CatchableError:
        return err("discv5 backend: lookup failed: " & getCurrentExceptionMsg())

    var found: seq[DiscoveredPeer]
    for record in records:
      let peer = record.toDiscoveredPeer().valueOr:
        continue
      found.add(peer)
      if limit > 0 and found.len >= limit:
        break
    ok(found)

  method lookupRandom(
      self: Discv5PeerDiscovery
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    await self.lookupServicePeers("", 0)

  method startAdvertising(
      self: Discv5PeerDiscovery, key: string, data: seq[byte], record: seq[byte]
  ): Future[Result[void, string]] {.async.} =
    ## Advertising for discv5 = mutating our own ENR; only shard: keys map.
    if record.len > 0:
      return err("discv5 backend: pre-signed records not supported")
    if not self.running:
      return err("discv5 backend: not running")
    let topic = ?shardKeyToPubsubTopic(key)
    self.inner.updateShards(@[topic], add = true)

  method stopAdvertising(
      self: Discv5PeerDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    if not self.running:
      return err("discv5 backend: not running")
    let topic = ?shardKeyToPubsubTopic(key)
    # updateShards refuses to remove the last remaining shard.
    self.inner.updateShards(@[topic], add = false)

  method registerInterest(
      self: Discv5PeerDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    err("discv5 backend: interest registration not supported for key: " & key)

  method unregisterInterest(
      self: Discv5PeerDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    err("discv5 backend: interest registration not supported for key: " & key)

  method addBootstrapEntries(
      self: Discv5PeerDiscovery, entries: seq[string]
  ): Future[Result[void, string]] {.async.} =
    if not self.running:
      return err("discv5 backend: not running")
    var records: seq[waku_enr.Record]
    for entry in entries:
      addBootstrapNode(entry, records) # logs and skips invalid entries
    if records.len > 0:
      self.inner.updateBootstrapRecords(self.inner.protocol.bootstrapRecords & records)
    ok()

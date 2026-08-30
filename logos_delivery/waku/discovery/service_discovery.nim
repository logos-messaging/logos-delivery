{.push raises: [].}

## IPeerDiscovery implementation for libp2p service discovery, wrapping
## `WakuKademlia`. Phase 1: the wrapped entity keeps
## feeding the PeerManager itself; this wrapper adds the interface surface
## and bridges the node-level PeersDiscoveredEvent onto the instance event.

import std/[sequtils, strutils]
import chronos, chronicles, results
import libp2p/[peerid, multiaddress, peerinfo, extended_peer_record]
from libp2p/protocols/kademlia import updatePeers
from libp2p/protocols/service_discovery import lookupRandom
import brokers/broker_implement
import logos_delivery/waku/discovery/peer_discovery_interface
import
  logos_delivery/waku/discovery/waku_kademlia,
  logos_delivery/waku/discovery/peer_discovery_conversion,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/api/events/discovery_events

export peer_discovery_interface

logScope:
  topics = "waku discovery service"

const
  ServiceBackendId* = "service"
  SvcKeyPrefix = "svc:"

type ServiceDiscovery* = ref object of IPeerDiscovery
  inner*: WakuKademlia
  running: bool

proc serviceIdOf(key: string): Result[string, string] =
  ## Any non-prefixed key and svc:/shard:/cap: keys are literal service
  ## ids; the svc: prefix is stripped.
  if key.len == 0:
    return err("service backend: empty criteria key")
  if key.startsWith(SvcKeyPrefix):
    return ok(key[SvcKeyPrefix.len ..^ 1])
  ok(key)

BrokerImplement ServiceDiscovery of IPeerDiscovery:
  proc new(T: typedesc[ServiceDiscovery], inner: WakuKademlia): ServiceDiscovery =
    let self = ServiceDiscovery(inner: inner)

    # Bridge the node-level event onto the instance-scoped interface event.
    # The wrapper lives as long as the node, so the listener is never dropped.
    discard PeersDiscoveredEvent.listen(
      proc(ev: PeersDiscoveredEvent): Future[void] {.async: (raises: []), gcsafe.} =
        let mine = ev.peers.filterIt(it.origin == PeerOrigin.Kademlia)
        if mine.len > 0:
          let converted = mine.mapIt(it.toDiscoveredPeer())
          PeersDiscovered.emit(
            self.brokerCtx,
            PeersDiscovered(origin: ServiceBackendId, key: "", peers: converted),
          )
    )

    self

  method backendInfo(
      self: ServiceDiscovery
  ): Future[Result[DiscoveryBackendInfo, string]] {.async.} =
    ok(
      DiscoveryBackendInfo(
        id: ServiceBackendId,
        running: self.running,
        keyKinds: @["svc", "shard", "cap"],
        boundPorts: @[],
      )
    )

  method startDiscovery(
      self: ServiceDiscovery
  ): Future[Result[void, string]] {.async.} =
    if self.inner.isNil():
      return err("service backend: not mounted")
    if self.running:
      return ok()
    await self.inner.start()
    self.running = true
    ok()

  method stopDiscovery(self: ServiceDiscovery): Future[Result[void, string]] {.async.} =
    if not self.running:
      return ok()
    await self.inner.stop()
    self.running = false
    ok()

  method lookupServicePeers(
      self: ServiceDiscovery, key: string, limit: int
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    if self.inner.isNil():
      return err("service backend: not mounted")
    let serviceId = ?serviceIdOf(key)
    let peers = ?await self.inner.lookupServicePeers(serviceId)
    var found = peers.mapIt(it.toDiscoveredPeer())
    if limit > 0 and found.len > limit:
      found.setLen(limit)
    ok(found)

  method startAdvertising(
      self: ServiceDiscovery, key: string, data: seq[byte], record: seq[byte]
  ): Future[Result[void, string]] {.async.} =
    if self.inner.isNil():
      return err("service backend: not mounted")
    if record.len > 0:
      return err("service backend: pre-signed advertisements not supported")
    let serviceId = ?serviceIdOf(key)
    self.inner.addServiceToAdvertise(ServiceInfo(id: serviceId, data: data))
    ok()

  method stopAdvertising(
      self: ServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    if self.inner.isNil():
      return err("service backend: not mounted")
    let serviceId = ?serviceIdOf(key)
    let res = catch:
      await self.inner.removeServiceToAdvertise(serviceId)
    res.isOkOr:
      return err("service backend: stop advertising failed: " & error.msg)
    ok()

  method registerInterest(
      self: ServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    if self.inner.isNil():
      return err("service backend: not mounted")
    let serviceId = ?serviceIdOf(key)
    self.inner.addServiceToDiscover(serviceId)
    ok()

  method unregisterInterest(
      self: ServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    if self.inner.isNil():
      return err("service backend: not mounted")
    let serviceId = ?serviceIdOf(key)
    self.inner.removeServiceToDiscover(serviceId)
    ok()

  method addBootstrapEntries(
      self: ServiceDiscovery, entries: seq[string]
  ): Future[Result[void, string]] {.async.} =
    if self.inner.isNil():
      return err("service backend: not mounted")
    var parsed: seq[(PeerId, seq[MultiAddress])]
    for entry in entries:
      let (peerId, ma) = parseFullAddress(entry).valueOr:
        return
          err("service backend: invalid bootstrap entry '" & entry & "': " & $error)
      parsed.add((peerId, @[ma]))
    if parsed.len > 0:
      self.inner.protocol.updatePeers(parsed)
    ok()

  method lookupRandom(
      self: ServiceDiscovery
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    if self.inner.isNil():
      return err("service backend: not mounted")
    let recordsRes = catch:
      await self.inner.protocol.lookupRandom()
    let records = recordsRes.valueOr:
      return err("service backend: random lookup failed: " & error.msg)

    var found: seq[DiscoveredPeer]
    for record in records:
      let rpi = remotePeerInfoFrom(record).valueOr:
        continue
      found.add(rpi.toDiscoveredPeer())
    ok(found)

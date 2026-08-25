{.used.}

import chronos, results, testutils/unittests
import brokers/broker_implement
import logos_delivery/api/peer_discovery_interface

type MockDiscovery = ref object of IPeerDiscovery
  started: bool
  lastLookup: string

BrokerImplement MockDiscovery of IPeerDiscovery:
  proc new(T: typedesc[MockDiscovery]): MockDiscovery =
    MockDiscovery()

  method backendInfo(
      self: MockDiscovery
  ): Future[Result[DiscoveryBackendInfo, string]] {.async.} =
    ok(
      DiscoveryBackendInfo(
        id: "mock", running: self.started, keyKinds: @["svc", ""], boundPorts: @[]
      )
    )

  method startDiscovery(self: MockDiscovery): Future[Result[void, string]] {.async.} =
    self.started = true
    ok()

  method stopDiscovery(self: MockDiscovery): Future[Result[void, string]] {.async.} =
    self.started = false
    ok()

  method lookupServicePeers(
      self: MockDiscovery, key: string, limit: int
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    if not self.started:
      return err("not started")
    self.lastLookup = key
    ok(@[DiscoveredPeer(peerId: "peer-of-" & key)])

  method lookupRandom(
      self: MockDiscovery
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    ok(@[DiscoveredPeer(peerId: "random-peer")])

suite "IPeerDiscovery interface":
  asyncTest "lifecycle and lookups through the interface type":
    let mock = MockDiscovery.create()
    let iface: IPeerDiscovery = mock

    check (await iface.lookupServicePeers("svc:/mix/1.0.0", 0)).isErr()

    check (await iface.startDiscovery()).isOk()
    let info = (await iface.backendInfo()).valueOr:
      raiseAssert error
    check:
      info.id == "mock"
      info.running

    let peers = (await iface.lookupServicePeers("svc:/mix/1.0.0", 5)).valueOr:
      raiseAssert error
    check:
      peers.len == 1
      peers[0].peerId == "peer-of-svc:/mix/1.0.0"
      mock.lastLookup == "svc:/mix/1.0.0"

    let randomPeers = (await iface.lookupRandom()).valueOr:
      raiseAssert error
    check randomPeers[0].peerId == "random-peer"

    check (await iface.stopDiscovery()).isOk()
    check not (await iface.backendInfo()).get().running

  asyncTest "PeersDiscovered reaches instance listeners":
    let mock = MockDiscovery.create()
    var received: seq[DiscoveredPeer]

    let onPeers = proc(
        ev: PeersDiscovered
    ): Future[void] {.async: (raises: []), gcsafe.} =
      received = ev.peers
    discard mock.listen(PeersDiscovered, onPeers)

    mock.emit(
      PeersDiscovered,
      PeersDiscovered(origin: "mock", key: "", peers: @[DiscoveredPeer(peerId: "p1")]),
    )
    await sleepAsync(chronos.milliseconds(10))

    check:
      received.len == 1
      received[0].peerId == "p1"

  asyncTest "instances are isolated by their broker contexts":
    let a = MockDiscovery.create()
    let b = MockDiscovery.create()
    check a.brokerCtx != b.brokerCtx

    var hitsA = 0
    let onPeersA = proc(
        ev: PeersDiscovered
    ): Future[void] {.async: (raises: []), gcsafe.} =
      inc hitsA
    discard a.listen(PeersDiscovered, onPeersA)

    b.emit(PeersDiscovered, PeersDiscovered(origin: "b", key: "", peers: @[]))
    await sleepAsync(chronos.milliseconds(10))
    check hitsA == 0

    discard (await a.startDiscovery())
    check (await b.backendInfo()).get().running == false
    check (await a.backendInfo()).get().running == true

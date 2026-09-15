{.used.}

import std/sequtils
import chronos, results, testutils/unittests
import brokers/broker_implement
import logos_delivery/waku/discovery/peer_discovery_interface

type MockDiscovery = ref object of IPeerDiscovery
  started: bool
  lastLookup: string
  advertised: seq[string]
  interests: seq[string]
  bootstrap: seq[string]

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

  method startAdvertising(
      self: MockDiscovery, key: string, data: seq[byte], record: seq[byte]
  ): Future[Result[void, string]] {.async.} =
    if record.len > 0:
      return err("mock: no pre-signed records")
    self.advertised.add(key)
    ok()

  method stopAdvertising(
      self: MockDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    self.advertised.keepItIf(it != key)
    ok()

  method registerInterest(
      self: MockDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    self.interests.add(key)
    ok()

  method unregisterInterest(
      self: MockDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    self.interests.keepItIf(it != key)
    ok()

  method addBootstrapEntries(
      self: MockDiscovery, entries: seq[string]
  ): Future[Result[void, string]] {.async.} =
    self.bootstrap.add(entries)
    ok()

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

  asyncTest "advertise, interest and bootstrap verbs":
    let mock = MockDiscovery.create()
    let iface: IPeerDiscovery = mock

    check (await iface.startAdvertising("svc:/mix/1.0.0", @[1'u8, 2], @[])).isOk()
    check (await iface.startAdvertising("svc:x", @[], @[9'u8])).isErr()
    check mock.advertised == @["svc:/mix/1.0.0"]

    check (await iface.registerInterest("svc:/mix/1.0.0")).isOk()
    check (await iface.registerInterest("cap:store")).isOk()
    check (await iface.unregisterInterest("cap:store")).isOk()
    check mock.interests == @["svc:/mix/1.0.0"]

    check (await iface.stopAdvertising("svc:/mix/1.0.0")).isOk()
    check mock.advertised.len == 0

    check (await iface.addBootstrapEntries(@["/ip4/1.2.3.4/tcp/1/p2p/16Uxx"])).isOk()
    check mock.bootstrap.len == 1

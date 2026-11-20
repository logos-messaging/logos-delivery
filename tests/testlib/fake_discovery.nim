{.used.}

import chronos, results, brokers/broker_implement
import logos_delivery/waku/discovery/peer_discovery_interface

## A backend that records what it was asked to do, so what a node advertises
## can be checked without standing up a DHT.
type FakeBackend* = ref object of IPeerDiscovery
  id: string
  kinds: seq[string]
  advertised*: seq[string]
  advertisedData*: seq[seq[byte]]
  advertisedSecondary*: seq[seq[DiscoveredService]]
  withdrawn*: seq[string]
  interests*: seq[string]
  pauseNextAdvert*: Future[void].Raising([CancelledError])
    ## When set, the next `startAdvertising` records its call, then waits on it.

BrokerImplement FakeBackend of IPeerDiscovery:
  proc new(T: typedesc[FakeBackend], id: string, kinds: seq[string]): FakeBackend =
    FakeBackend(id: id, kinds: kinds)

  method backendInfo(
      self: FakeBackend
  ): Future[Result[DiscoveryBackendInfo, string]] {.async.} =
    ok(DiscoveryBackendInfo(id: self.id, running: true, keyKinds: self.kinds))

  method startAdvertising(
      self: FakeBackend, key: string, data: seq[byte], secondary: seq[DiscoveredService]
  ): Future[Result[void, string]] {.async.} =
    self.advertised.add(key)
    self.advertisedData.add(data)
    self.advertisedSecondary.add(secondary)
    let pause = self.pauseNextAdvert
    self.pauseNextAdvert = nil
    if not pause.isNil():
      let res = catch:
        await pause
      res.isOkOr:
        return err("fake backend: paused advert ended: " & error.msg)
    ok()

  method registerInterest(
      self: FakeBackend, key: string
  ): Future[Result[void, string]] {.async.} =
    self.interests.add(key)
    ok()

  ## No-ops: the interface requires every verb.
  method startDiscovery(self: FakeBackend): Future[Result[void, string]] {.async.} =
    ok()

  method stopDiscovery(self: FakeBackend): Future[Result[void, string]] {.async.} =
    ok()

  method lookupServicePeers(
      self: FakeBackend, key: string, limit: int
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    ok(newSeq[DiscoveredPeer]())

  method lookupRandom(
      self: FakeBackend
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    ok(newSeq[DiscoveredPeer]())

  method stopAdvertising(
      self: FakeBackend, key: string
  ): Future[Result[void, string]] {.async.} =
    self.withdrawn.add(key)
    ok()

  method unregisterInterest(
      self: FakeBackend, key: string
  ): Future[Result[void, string]] {.async.} =
    ok()

  method addBootstrapEntries(
      self: FakeBackend, entries: seq[string]
  ): Future[Result[void, string]] {.async.} =
    ok()

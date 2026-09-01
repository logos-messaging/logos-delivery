{.used.}

import std/[json, sequtils, strutils]
import chronos, results, testutils/unittests
import brokers/broker_implement
import
  logos_delivery/waku/discovery/self_advertisement,
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/waku/waku_enr/capabilities
import logos_delivery/waku/waku_core/codecs
import tools/confutils/cli_args

## A backend that records what it was asked to do, so the fan-out rules can be
## checked without standing up a DHT.
type FakeBackend = ref object of IPeerDiscovery
  id: string
  kinds: seq[string]
  advertised: seq[string]
  advertisedData: seq[seq[byte]]
  interests: seq[string]

BrokerImplement FakeBackend of IPeerDiscovery:
  proc new(T: typedesc[FakeBackend], id: string, kinds: seq[string]): FakeBackend =
    FakeBackend(id: id, kinds: kinds)

  method backendInfo(
      self: FakeBackend
  ): Future[Result[DiscoveryBackendInfo, string]] {.async.} =
    ok(DiscoveryBackendInfo(id: self.id, running: true, keyKinds: self.kinds))

  method startAdvertising(
      self: FakeBackend, key: string, data: seq[byte], record: seq[byte]
  ): Future[Result[void, string]] {.async.} =
    self.advertised.add(key)
    self.advertisedData.add(data)
    ok()

  method registerInterest(
      self: FakeBackend, key: string
  ): Future[Result[void, string]] {.async.} =
    self.interests.add(key)
    ok()

  ## Not exercised here; the interface requires every verb.
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
    ok()

  method unregisterInterest(
      self: FakeBackend, key: string
  ): Future[Result[void, string]] {.async.} =
    ok()

  method addBootstrapEntries(
      self: FakeBackend, entries: seq[string]
  ): Future[Result[void, string]] {.async.} =
    ok()

proc confWith(flags: CapabilitiesBitfield): WakuConf =
  var conf = defaultWakuNodeConf().valueOr:
    raiseAssert error
  conf.clusterId = Opt.some(16'u16)
  var wakuConf = conf.toWakuConf().valueOr:
    raiseAssert error
  wakuConf.wakuFlags = flags
  wakuConf.subscribeShards = @[0'u16, 3'u16]
  wakuConf

const CoreFlags =
  CapabilitiesBitfield.init(relay = true, store = true, lightpush = true)
const EdgeFlags = CapabilitiesBitfield.init()
const TestShards = @[0'u16, 3'u16]

suite "Self advertisement":
  asyncTest "a serving node advertises and registers interest":
    let kad = FakeBackend.create("service", @["svc", "shard", "cap"])
    await advertiseSelf(@[IPeerDiscovery(kad)], confWith(CoreFlags), TestShards)
    check:
      kad.advertised == @["svc:" & LogosDeliveryServiceId]
      kad.interests == @["svc:" & LogosDeliveryServiceId]

  asyncTest "an edge node registers interest but advertises nothing":
    ## Nothing to be found for, but it still needs to find others.
    let kad = FakeBackend.create("service", @["svc", "shard", "cap"])
    await advertiseSelf(@[IPeerDiscovery(kad)], confWith(EdgeFlags), TestShards)
    check:
      kad.advertised.len == 0
      kad.interests == @["svc:" & LogosDeliveryServiceId]

  asyncTest "relay alone is enough to be worth finding":
    let kad = FakeBackend.create("service", @["svc", "shard", "cap"])
    await advertiseSelf(
      @[IPeerDiscovery(kad)],
      confWith(CapabilitiesBitfield.init(relay = true)),
      TestShards,
    )
    check kad.advertised.len == 1

  asyncTest "both kademlia hosts take part, discv5 does not":
    ## Selected by what a backend declares it understands, not by its name --
    ## discv5 rejects svc: keys, so asking it would only produce warnings.
    let internal = FakeBackend.create("service", @["svc", "shard", "cap"])
    let plugin = FakeBackend.create("service-ext", @["svc", "shard", "cap"])
    let discv5 = FakeBackend.create("discv5", @["shard", "cap", ""])
    await advertiseSelf(
      @[IPeerDiscovery(internal), IPeerDiscovery(plugin), IPeerDiscovery(discv5)],
      confWith(CoreFlags),
      TestShards,
    )
    check:
      internal.advertised.len == 1
      plugin.advertised.len == 1
      discv5.advertised.len == 0
      discv5.interests.len == 0

  test "the payload carries version, cluster, capabilities and shards":
    let data = selfAdvertisementData(confWith(CoreFlags), TestShards)
    check:
      data.len == 5 # 4-byte header + one bitmap byte covering shards 0 and 3
      data[0] == AdvertFormatVersion
      (uint16(data[1]) shl 8 or uint16(data[2])) == 16'u16
      CapabilitiesBitfield(data[3]).supportsCapability(Capabilities.Relay)
      CapabilitiesBitfield(data[3]).supportsCapability(Capabilities.Store)
      CapabilitiesBitfield(data[3]).supportsCapability(Capabilities.Lightpush)
      not CapabilitiesBitfield(data[3]).supportsCapability(Capabilities.Filter)
      data[4] == 0b0000_1001'u8 # shards 0 and 3

  test "the payload stays within the size libp2p will accept":
    ## The JSON shape this replaced ran to ~188 bytes and could never be
    ## advertised. Checked with a deliberately wide shard set, not just the
    ## two-shard fixture.
    var manyShards: seq[uint16]
    for i in 0'u16 ..< 200'u16:
      manyShards.add(i)
    check selfAdvertisementData(confWith(CoreFlags), manyShards).len <= MaxAdvertLen

  test "a shard index beyond the bitmap is dropped, not aliased":
    let data = selfAdvertisementData(confWith(CoreFlags), @[0'u16, 9999'u16])
    check:
      data.len <= MaxAdvertLen
      data[4] == 0b0000_0001'u8 # shard 0 only; 9999 did not fold onto a low bit

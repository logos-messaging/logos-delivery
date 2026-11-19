{.used.}

import std/[base64, sequtils]
import
  chronos,
  results,
  testutils/unittests,
  libp2p/crypto/curve25519,
  libp2p_mix/mix_protocol
import
  logos_delivery/waku/discovery/self_advertisement,
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/waku/waku_enr/capabilities
import tools/confutils/cli_args
import ../testlib/fake_discovery

proc confWith(flags: CapabilitiesBitfield): WakuConf =
  var conf = defaultKernelConf().valueOr:
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
    let kad = FakeBackend.create("service", @["service", "topic", "cap"])
    await advertiseSelf(@[IPeerDiscovery(kad)], confWith(CoreFlags), TestShards)
    check:
      kad.advertised == @["service:" & LogosDeliveryServiceId]
      kad.interests == @["service:" & LogosDeliveryServiceId]

  asyncTest "an edge node registers interest but advertises nothing":
    ## Nothing to be found for, but it still needs to find others.
    let kad = FakeBackend.create("service", @["service", "topic", "cap"])
    await advertiseSelf(@[IPeerDiscovery(kad)], confWith(EdgeFlags), TestShards)
    check:
      kad.advertised.len == 0
      kad.interests == @["service:" & LogosDeliveryServiceId]

  asyncTest "relay alone is enough to be worth finding":
    let kad = FakeBackend.create("service", @["service", "topic", "cap"])
    await advertiseSelf(
      @[IPeerDiscovery(kad)],
      confWith(CapabilitiesBitfield.init(relay = true)),
      TestShards,
    )
    check kad.advertised.len == 1

  asyncTest "both kademlia hosts take part, discv5 does not":
    ## Selected by what a backend declares it understands, not by its name --
    ## discv5 rejects svc: keys, so asking it would only produce warnings.
    let internal = FakeBackend.create("service", @["service", "topic", "cap"])
    let plugin = FakeBackend.create("service-ext", @["service", "topic", "cap"])
    let discv5 = FakeBackend.create("discv5", @["topic", "cap", ""])
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

  asyncTest "the mix advert carries the given key under the mix service":
    let kad = FakeBackend.create("service", @["service", "topic", "cap"])
    var key: Curve25519Key
    for i in 0 ..< key.len:
      key[i] = byte(i)
    await advertiseMix(
      @[IPeerDiscovery(kad)],
      key,
      proc(): bool {.gcsafe, raises: [].} =
        true,
    )
    check:
      kad.advertised == @["service:" & MixProtocolID]
      kad.advertisedData == @[@key]
      kad.interests == @["service:" & MixProtocolID]

  test "the payload carries version, cluster, capabilities and shards":
    let raw = cast[seq[byte]](base64.decode(
      cast[string](selfAdvertisementData(confWith(CoreFlags), TestShards))
    ))
    check:
      raw.len == 5 # 4-byte header + one bitmap byte covering shards 0 and 3
      raw[0] == AdvertFormatVersion
      (uint16(raw[1]) shl 8 or uint16(raw[2])) == 16'u16
      CapabilitiesBitfield(raw[3]).supportsCapability(Capabilities.Relay)
      CapabilitiesBitfield(raw[3]).supportsCapability(Capabilities.Store)
      CapabilitiesBitfield(raw[3]).supportsCapability(Capabilities.Lightpush)
      not CapabilitiesBitfield(raw[3]).supportsCapability(Capabilities.Filter)
      raw[4] == 0b0000_1001'u8 # shards 0 and 3

  test "the payload stays within the size libp2p will accept":
    ## The JSON shape this replaced ran to ~188 bytes and could never be
    ## advertised. Checked with a deliberately wide shard set, not just the
    ## two-shard fixture.
    var manyShards: seq[uint16]
    for i in 0'u16 ..< 200'u16:
      manyShards.add(i)
    check selfAdvertisementData(confWith(CoreFlags), manyShards).len <= MaxAdvertLen

  test "the payload is valid UTF-8, so it survives a JSON transport":
    ## The plugin-hosted path marshals `data` as a JSON string on its way to the
    ## provider. A raw binary record throws there and takes the hosting module
    ## down, so every byte has to be printable ASCII.
    var manyShards: seq[uint16]
    for i in 0'u16 ..< 160'u16:
      manyShards.add(i)
    for data in [
      selfAdvertisementData(confWith(CoreFlags), TestShards),
      selfAdvertisementData(confWith(EdgeFlags), @[]),
      selfAdvertisementData(confWith(CoreFlags), manyShards),
    ]:
      check data.allIt(it >= 0x20'u8 and it < 0x7f'u8)

  test "a shard index beyond the bitmap is dropped, not aliased":
    let raw = cast[seq[byte]](base64.decode(
      cast[string](selfAdvertisementData(confWith(CoreFlags), @[0'u16, 9999'u16]))
    ))
    check:
      raw.len == 5
      raw[4] == 0b0000_0001'u8 # shard 0 only; 9999 did not fold onto a low bit

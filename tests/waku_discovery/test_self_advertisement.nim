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
  logos_delivery/waku/waku_enr/capabilities,
  logos_delivery/waku/discovery/delivery_advert,
  logos_delivery/waku/discovery/peer_discovery_conversion,
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/waku_core
import tools/confutils/cli_args
import ../testlib/[fake_discovery, wakucore]

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

proc mixKeyBytes(): seq[byte] =
  var b = newSeq[byte](Curve25519KeySize)
  for i in 0 ..< Curve25519KeySize:
    b[i] = byte(i + 1)
  b

proc mixKey(): Opt[Curve25519Key] =
  Opt.some(intoCurve25519Key(mixKeyBytes()))

proc withMix(conf: WakuConf): WakuConf =
  ## The node mounts mix. The builder sets the Mix flag whenever it does.
  conf.mixConf = Opt.some(MixConf())
  conf.wakuFlags = CapabilitiesBitfield(
    byte(conf.wakuFlags) or byte(CapabilitiesBitfield.init(mix = true))
  )
  conf

proc advertiseSelf(
    discoveries: seq[IPeerDiscovery],
    conf: WakuConf,
    shards: seq[uint16],
    mixKey = Opt.none(Curve25519Key),
) {.async.} =
  ## Advertises the record of a node with this configuration, as the node puts
  ## it together: the delivery part when it serves something, and the mix part
  ## while it has a mix key to advertise.
  var parts: seq[GetSelfAdvert]
  if conf.wakuFlags.isServiceNode():
    parts.add(deliveryAdvertPart(conf, shards))
  if mixKey.isSome():
    parts.add(mixAdvertPart(mixKey.get()))
  await advertiseSelf(discoveries, assembleAdvert(parts).expect("a record"))

proc advertisedCaps(kad: FakeBackend): CapabilitiesBitfield =
  advertisedCapabilities(kad.advertisedData[0]).expect("a delivery payload")

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

  asyncTest "a relay node that mounts mix lists its mix key in the delivery record":
    let kad = FakeBackend.create("service", @["service", "topic", "cap"])
    await advertiseSelf(
      @[IPeerDiscovery(kad)], confWith(CoreFlags).withMix(), TestShards, mixKey()
    )
    check:
      ## One registration, and no interest in a mix service of its own.
      kad.advertised == @["service:" & LogosDeliveryServiceId]
      kad.interests == @["service:" & LogosDeliveryServiceId]
      kad.advertisedSecondary[0] ==
        @[DiscoveredService(id: MixProtocolID, data: mixKeyBytes())]
      kad.advertisedCaps().supportsCapability(Capabilities.Mix)
      ## What a reader of this record takes.
      advertisedMixKey(
        @[DiscoveredService(id: LogosDeliveryServiceId, data: kad.advertisedData[0])] &
          kad.advertisedSecondary[0]
      ) == Opt.some(intoCurve25519Key(mixKeyBytes()))

  asyncTest "a mix node that is not ready advertises as a delivery node only":
    ## With Mix RLN, a node without a usable Mix membership cannot prove a hop.
    let kad = FakeBackend.create("service", @["service", "topic", "cap"])
    await advertiseSelf(
      @[IPeerDiscovery(kad)], confWith(CoreFlags).withMix(), TestShards
    )
    check:
      kad.advertised == @["service:" & LogosDeliveryServiceId]
      kad.advertisedSecondary[0].len == 0
      not kad.advertisedCaps().supportsCapability(Capabilities.Mix)
      kad.advertisedCaps().supportsCapability(Capabilities.Relay)

  test "a record takes one delivery part":
    let part = deliveryAdvertPart(confWith(CoreFlags), TestShards)
    check:
      assembleAdvert([part, part]).isErr()
      ## Without a delivery part the node advertises nothing.
      assembleAdvert([mixAdvertPart(mixKey().get())]) ==
        Result[SelfAdvert, string].ok(SelfAdvert())
      assembleAdvert([]) == Result[SelfAdvert, string].ok(SelfAdvert())

  test "a part of another service is listed in the record as it is":
    let other =
      GetSelfAdvert(service: DiscoveredService(id: "/other/1.0.0", data: @[7'u8]))
    let advert = assembleAdvert(
        [other, deliveryAdvertPart(confWith(CoreFlags), TestShards)]
      )
      .expect("a record")
    check:
      advert.data == Opt.some(selfAdvertisementData(confWith(CoreFlags), TestShards))
      advert.secondary == @[other.service]

  asyncTest "a relay node without mix lists the delivery service alone":
    let kad = FakeBackend.create("service", @["service", "topic", "cap"])
    await advertiseSelf(@[IPeerDiscovery(kad)], confWith(CoreFlags), TestShards)
    check:
      kad.advertisedSecondary[0].len == 0
      not kad.advertisedCaps().supportsCapability(Capabilities.Mix)

  asyncTest "a serving node without relay does not advertise its mix key":
    ## It mounts mix to send through it; it is no hop for others.
    let kad = FakeBackend.create("service", @["service", "topic", "cap"])
    await advertiseSelf(
      @[IPeerDiscovery(kad)],
      confWith(CapabilitiesBitfield.init(filter = true)).withMix(),
      TestShards,
      mixKey(),
    )
    check:
      kad.advertised == @["service:" & LogosDeliveryServiceId]
      kad.advertisedSecondary[0].len == 0
      not kad.advertisedCaps().supportsCapability(Capabilities.Mix)
      kad.advertisedCaps().supportsCapability(Capabilities.Filter)

  asyncTest "an edge node that mounts mix advertises nothing":
    let kad = FakeBackend.create("service", @["service", "topic", "cap"])
    await advertiseSelf(
      @[IPeerDiscovery(kad)], confWith(EdgeFlags).withMix(), TestShards, mixKey()
    )
    check:
      kad.advertised.len == 0
      kad.interests == @["service:" & LogosDeliveryServiceId]

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

suite "Delivery record into the peer store":
  let
    serving = CapabilitiesBitfield.init(relay = true, filter = true, lightpush = true)
    shardTopic = Opt.some(PubsubTopic("/waku/2/rs/16/3"))

  proc discovered(
      conf: WakuConf, shards = TestShards, peerId = $newTestSwitch().peerInfo.peerId
  ): DiscoveredPeer =
    DiscoveredPeer(
      peerId: peerId,
      addrs: @["/ip4/10.0.0.1/tcp/60000"],
      services: @[
        DiscoveredService(
          id: LogosDeliveryServiceId, data: selfAdvertisementData(conf, shards)
        )
      ],
    )

  test "the payload gives back its cluster and shards":
    check:
      advertisedShards(selfAdvertisementData(confWith(serving), TestShards)).expect(
        "a delivery payload"
      ) == (16'u16, TestShards)
      advertisedShards(cast[seq[byte]](base64.encode("\x09abc"))).isErr()
      advertisedShards(cast[seq[byte]](base64.encode("\x01a"))).isErr()
      advertisedShards(@[byte('!')]).isErr()

  test "a record's codecs and shards make its peer selectable unconnected":
    let pm = PeerManager.new(newTestSwitch())
    let info = discovered(confWith(serving)).toRemotePeerInfo(16'u16).valueOr:
        raiseAssert error
    pm.addPeer(info, PeerOrigin.Kademlia)

    check:
      LogosDeliveryServiceId in info.protocols
      info.advertisedShards == TestShards
      info.shards.len == 0
      pm.selectPeer(WakuLightPushCodec, shardTopic).isSome()
      pm.selectPeer(WakuFilterSubscribeCodec, shardTopic).isSome()
      pm.switch.peerStore.hasShard(info.peerId, 16'u16, 3'u16)
      pm.selectPeer(WakuStoreCodec, shardTopic).isNone()
      pm.selectPeer(WakuLightPushCodec, Opt.some(PubsubTopic("/waku/2/rs/16/1"))).isNone()

  test "a record of another cluster claims nothing":
    let info = discovered(confWith(serving)).toRemotePeerInfo(7'u16).valueOr:
        raiseAssert error
    check:
      info.protocols == @[LogosDeliveryServiceId]
      info.advertisedShards.len == 0

  test "a record leaves the shards the peer's metadata gave":
    ## The record can be older than the metadata: a node signs a new one when
    ## its addresses or mix part change, and not when it subscribes to a shard.
    let pm = PeerManager.new(newTestSwitch())
    let peerStore = pm.switch.peerStore
    let info = discovered(confWith(serving), shards = @[0'u16])
      .toRemotePeerInfo(16'u16).valueOr:
        raiseAssert error
    peerStore.setShardInfo(info.peerId, @[0'u16, 1])
    pm.addPeer(info, PeerOrigin.Kademlia)

    check:
      peerStore[ShardBook][info.peerId] == @[0'u16, 1]
      peerStore.hasShard(info.peerId, 16'u16, 1'u16)
      peerStore.getPeer(info.peerId).supportsShard(16'u16, 1'u16)
      pm
        .selectPeer(WakuFilterSubscribeCodec, Opt.some(PubsubTopic("/waku/2/rs/16/1")))
        .isSome()

  test "the peer's metadata wins over the shards its record claims":
    let pm = PeerManager.new(newTestSwitch())
    let peerStore = pm.switch.peerStore
    let info = discovered(confWith(serving)).toRemotePeerInfo(16'u16).valueOr:
        raiseAssert error
    pm.addPeer(info, PeerOrigin.Kademlia)
    peerStore.setShardInfo(info.peerId, @[0'u16])

    check:
      peerStore.hasShard(info.peerId, 16'u16, 0'u16)
      not peerStore.hasShard(info.peerId, 16'u16, 3'u16)
      not peerStore.getPeer(info.peerId).supportsShard(16'u16, 3'u16)

  test "a newer record replaces the shards an older one claimed":
    let pm = PeerManager.new(newTestSwitch())
    let peerStore = pm.switch.peerStore
    let peerId = $newTestSwitch().peerInfo.peerId
    for shards in [@[0'u16, 3], @[1'u16]]:
      let info = discovered(confWith(serving), shards, peerId)
        .toRemotePeerInfo(16'u16).valueOr:
          raiseAssert error
      pm.addPeer(info, PeerOrigin.Kademlia)

    let pid = PeerId.init(peerId).expect("a peer id")
    check:
      peerStore[AdvertisedShardBook][pid] == @[1'u16]
      peerStore.hasShard(pid, 16'u16, 1'u16)
      not peerStore.hasShard(pid, 16'u16, 3'u16)
      peerStore[ShardBook][pid].len == 0

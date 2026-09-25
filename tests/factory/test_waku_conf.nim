{.used.}

import
  libp2p/crypto/[crypto, secp],
  libp2p/crypto/curve25519,
  libp2p/multiaddress,
  nimcrypto/utils,
  std/[net, random, sequtils, strutils],
  results,
  stew/byteutils,
  testutils/unittests
import
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/waku/factory/conf_builder/conf_builder,
  logos_delivery/waku/factory/networks_config,
  logos_delivery/waku/waku_mix,
  logos_delivery/waku/waku_enr/capabilities,
  logos_delivery/waku/common/utils/parse_size_units

suite "Waku Conf - build with cluster conf":
  test "ext-multiaddr-only fails conf build without ext-multiaddrs":
    var builder = WakuConfBuilder.init()
    builder.withClusterId(1)
    builder.withExtMultiAddrsOnly(true)
    check builder.build().isErr()

  test "ext-multiaddr-only fails conf build on a zero port":
    var builder = WakuConfBuilder.init()
    builder.withClusterId(1)
    builder.withExtMultiAddrsOnly(true)
    builder.withExtMultiAddrs(@["/ip4/203.0.113.9/tcp/0"])
    check builder.build().isErr()

  test "Cluster Conf is passed and relay is enabled":
    ## Setup
    let networkPresetConf = NetworkPresetConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    builder.discv5Conf.withUdpPort(9000)
    builder.withRelayServiceRatio("50:50")
    # Mount all shards in network
    let expectedShards = toSeq[0.uint16 .. 7.uint16]
    let userMessageLimit = rand(1 .. 1000).uint64

    ## Given
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])
    builder.withNetworkPresetConf(networkPresetConf)
    builder.withRelay(true)
    builder.rlnRelayConf.withUserMessageLimit(userMessageLimit)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check conf.clusterId == networkPresetConf.clusterId
    check conf.shardingConf.kind == networkPresetConf.shardingConf.kind
    check conf.shardingConf.numShardsInCluster ==
      networkPresetConf.shardingConf.numShardsInCluster
    check conf.subscribeShards == expectedShards
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(networkPresetConf.maxMessageSize))
    check conf.discv5Conf.get().bootstrapNodes == networkPresetConf.discv5BootstrapNodes

    if networkPresetConf.rlnRelay:
      assert conf.rlnEvmConf.isSome(), "RLN Relay conf is disabled"

      let rlnEvmConf = conf.rlnEvmConf.get()
      check rlnEvmConf.ethContractAddress.string ==
        networkPresetConf.rlnRelayEthContractAddress
      check rlnEvmConf.dynamic == networkPresetConf.rlnRelayDynamic
      check rlnEvmConf.chainId == networkPresetConf.rlnRelayChainId
      check rlnEvmConf.epochSizeSec == networkPresetConf.rlnEpochSizeSec
      check rlnEvmConf.userMessageLimit == userMessageLimit.uint

  test "Cluster Conf is passed, but relay is disabled":
    ## Setup
    let networkPresetConf = NetworkPresetConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    builder.withRelayServiceRatio("50:50")
    builder.discv5Conf.withUdpPort(9000)
    # Mount all shards in network
    let expectedShards = toSeq[0.uint16 .. 7.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])
    builder.withNetworkPresetConf(networkPresetConf)
    builder.withRelay(false)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check conf.clusterId == networkPresetConf.clusterId
    check conf.shardingConf.kind == networkPresetConf.shardingConf.kind
    check conf.shardingConf.numShardsInCluster ==
      networkPresetConf.shardingConf.numShardsInCluster
    check conf.subscribeShards == expectedShards
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(networkPresetConf.maxMessageSize))
    check conf.discv5Conf.get().bootstrapNodes == networkPresetConf.discv5BootstrapNodes

    assert conf.rlnEvmConf.isNone

  test "Cluster Conf is passed, but rln relay is disabled":
    ## Setup
    let networkPresetConf = NetworkPresetConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()

    let # Mount all shards in network
      expectedShards = toSeq[0.uint16 .. 7.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])
    builder.withNetworkPresetConf(networkPresetConf)
    builder.rlnRelayConf.withEnabled(false)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check conf.clusterId == networkPresetConf.clusterId
    check conf.shardingConf.kind == networkPresetConf.shardingConf.kind
    check conf.shardingConf.numShardsInCluster ==
      networkPresetConf.shardingConf.numShardsInCluster
    check conf.subscribeShards == expectedShards
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(networkPresetConf.maxMessageSize))
    check conf.discv5Conf.get().bootstrapNodes == networkPresetConf.discv5BootstrapNodes
    assert conf.rlnEvmConf.isNone

  test "Cluster Conf is passed and valid shards are specified":
    ## Setup
    let networkPresetConf = NetworkPresetConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    let shards = @[2.uint16, 3.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])
    builder.withNetworkPresetConf(networkPresetConf)
    builder.withSubscribeShards(shards)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check conf.clusterId == networkPresetConf.clusterId
    check conf.shardingConf.kind == networkPresetConf.shardingConf.kind
    check conf.shardingConf.numShardsInCluster ==
      networkPresetConf.shardingConf.numShardsInCluster
    check conf.subscribeShards == shards
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(networkPresetConf.maxMessageSize))
    check conf.discv5Conf.get().bootstrapNodes == networkPresetConf.discv5BootstrapNodes

  test "Cluster Conf is passed and invalid shards are specified":
    ## Setup
    let networkPresetConf = NetworkPresetConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    let shards = @[2.uint16, 10.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])
    builder.withNetworkPresetConf(networkPresetConf)
    builder.withSubscribeShards(shards)

    ## When
    let resConf = builder.build()

    ## Then
    assert resConf.isErr(), "Invalid shard was accepted"

  test "Cluster Conf mandating RLN fails conf build if user disables rln relay":
    ## Setup
    let networkPresetConf = NetworkPresetConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()

    ## Given
    builder.withNetworkPresetConf(networkPresetConf)
    builder.withRelay(true)
    builder.rlnRelayConf.withEnabled(false)

    ## When
    let resConf = builder.build()

    ## Then
    assert networkPresetConf.rlnRelay, "precondition: preset must mandate RLN"
    assert resConf.isErr(), "relay with rln relay disabled was accepted"

  test "Cluster Conf mandating RLN fails conf build if user overrides the rln contract":
    ## Setup
    let networkPresetConf = NetworkPresetConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    # otherwise-valid RLN, so only the security gate can fail the build
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])

    ## Given
    builder.withNetworkPresetConf(networkPresetConf)
    builder.withRelay(true)
    builder.rlnRelayConf.withEthContractAddress(
      networkPresetConf.rlnRelayEthContractAddress & "0"
    )

    ## When
    let resConf = builder.build()

    ## Then
    assert networkPresetConf.rlnRelay, "precondition: preset must mandate RLN"
    assert resConf.isErr(), "relay with an overridden rln contract was accepted"

  test "Cluster Conf mandating RLN fails conf build if user overrides the rln chain id":
    ## Setup
    let networkPresetConf = NetworkPresetConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    # otherwise-valid RLN, so only the security gate can fail the build
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])

    ## Given
    builder.withNetworkPresetConf(networkPresetConf)
    builder.withRelay(true)
    builder.rlnRelayConf.withChainId(1'u) # chain id 1 differs from the preset's

    ## When
    let resConf = builder.build()

    ## Then
    assert networkPresetConf.rlnRelay, "precondition: preset must mandate RLN"
    assert resConf.isErr(), "relay with an overridden rln chain id was accepted"

  test "Cluster Conf mandating RLN fails conf build if user overrides rln dynamic mode":
    ## Setup
    let networkPresetConf = NetworkPresetConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    # otherwise-valid RLN, so only the security gate can fail the build
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])

    ## Given
    builder.withNetworkPresetConf(networkPresetConf)
    builder.withRelay(true)
    builder.rlnRelayConf.withDynamic(not networkPresetConf.rlnRelayDynamic)

    ## When
    let resConf = builder.build()

    ## Then
    assert networkPresetConf.rlnRelay, "precondition: preset must mandate RLN"
    assert resConf.isErr(), "relay with an overridden rln dynamic mode was accepted"

  test "Cluster Conf mandating RLN fails conf build if user overrides the rln epoch size":
    ## Setup
    let networkPresetConf = NetworkPresetConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    # otherwise-valid RLN, so only the security gate can fail the build
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])

    ## Given
    builder.withNetworkPresetConf(networkPresetConf)
    builder.withRelay(true)
    builder.rlnRelayConf.withEpochSizeSec(networkPresetConf.rlnEpochSizeSec + 1'u64)

    ## When
    let resConf = builder.build()

    ## Then
    assert networkPresetConf.rlnRelay, "precondition: preset must mandate RLN"
    assert resConf.isErr(), "relay with an overridden rln epoch size was accepted"

  test "num-shards-in-network > 0 overrides preset":
    ## Setup
    let networkPresetConf = NetworkPresetConf.LogosDevConf()
    var builder = WakuConfBuilder.init()

    # Sanity check
    check networkPresetConf.shardingConf.kind == AutoSharding
    check networkPresetConf.shardingConf.numShardsInCluster > 1

    ## Given: preset says >1 shards but user explicitly sets 1
    builder.withNetworkPresetConf(networkPresetConf)
    builder.withNumShardsInCluster(1)
    builder.withShardingConf(AutoSharding)

    ## When
    let conf = builder.build().expect("build should succeed")

    ## Then: user value wins, not preset
    conf.validate().expect("conf should validate")
    check conf.shardingConf.kind == AutoSharding
    check conf.shardingConf.numShardsInCluster == 1

  test "num-shards-in-network == 0 does not override preset":
    ## Passing an AutoSharding preset and trying to override with
    ## --num-shards-in-network=0 (which is StaticSharding) doesn't work.
    ## Note that --num-shards-in-network=0 and omitting the switch are
    ## internally the same. Promoting the config to an Opt[uint16] is
    ## probably not worth it since overriding an AutoSharding preset with
    ## StaticSharding shouldn't make any sense (that is, no use case).

    ## Given: emulate --preset=logos.dev --num-shards-in-network=0
    let networkPresetConf = NetworkPresetConf.LogosDevConf()
    var builder = WakuConfBuilder.init()
    builder.withNetworkPresetConf(networkPresetConf)

    ## When
    let conf = builder.build().expect("build should succeed")

    ## Then: preset wins and StaticSharding user intent is lost
    conf.validate().expect("conf should validate")
    check conf.shardingConf.kind == networkPresetConf.shardingConf.kind
    check conf.shardingConf.numShardsInCluster ==
      networkPresetConf.shardingConf.numShardsInCluster

suite "Waku Conf - node key":
  test "Node key is generated":
    ## Setup
    var builder = WakuConfBuilder.init()
    builder.withClusterId(1)

    ## Given

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    let pubkey = getPublicKey(conf.nodeKey)
    assert pubkey.isOk()

  test "Passed node key is used":
    ## Setup
    let nodeKeyStr =
      "0011223344556677889900aabbccddeeff0011223344556677889900aabbccddeeff"
    let nodeKey = block:
      let key = SkPrivateKey.init(utils.fromHex(nodeKeyStr)).tryGet()
      crypto.PrivateKey(scheme: Secp256k1, skkey: key)
    var builder = WakuConfBuilder.init()
    builder.withClusterId(1)

    ## Given
    builder.withNodeKey(nodeKey)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    assert utils.toHex(conf.nodeKey.getRawBytes().get()) ==
      utils.toHex(nodeKey.getRawBytes().get()),
      "Passed node key isn't in config:" & $nodeKey & $conf.nodeKey

suite "Waku Conf - store sync":
  test "Store sync sets the Sync capability":
    ## Setup
    var builder = WakuConfBuilder.init()
    builder.withClusterId(1)

    ## Given
    builder.storeServiceConf.withEnabled(true)
    builder.storeServiceConf.withDbUrl("sqlite://store.sqlite3")
    builder.storeServiceConf.storeSyncConf.withEnabled(true)
    builder.storeServiceConf.storeSyncConf.withRangeSec(3600)
    builder.storeServiceConf.storeSyncConf.withIntervalSec(300)
    builder.storeServiceConf.storeSyncConf.withRelayJitterSec(20)

    ## When
    let conf = builder.build().valueOr:
      raiseAssert error

    ## Then
    check:
      conf.wakuFlags.supportsCapability(Capabilities.Store)
      conf.wakuFlags.supportsCapability(Capabilities.Sync)

suite "Waku Conf - extMultiaddrs":
  test "Valid multiaddresses are passed and accepted":
    ## Setup
    var builder = WakuConfBuilder.init()
    builder.withClusterId(1)

    ## Given
    let multiaddrs =
      @["/ip4/127.0.0.1/udp/9090/quic", "/ip6/::1/tcp/3217", "/dns4/foo.com/tcp/80"]
    builder.withExtMultiAddrs(multiaddrs)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check multiaddrs.len == conf.endpointConf.extMultiAddrs.len
    let resMultiaddrs = conf.endpointConf.extMultiAddrs.map(
      proc(m: MultiAddress): string =
        $m
    )
    for m in multiaddrs:
      check m in resMultiaddrs

suite "Waku Conf Builder - rate limits":
  test "Valid rate limit passed via string":
    ## Setup
    var builder = RateLimitConfBuilder.init()

    ## Given
    let rateLimitsStr = @["lightpush:2/2ms", "10/2m", "store: 3/3s"]
    builder.withRateLimits(rateLimitsStr)

    ## When
    let res = builder.build()

    ## Then
    assert res.isOk(), $res.error

suite "Waku Conf - pure-libp2p peers budget":
  test "off by default":
    var builder = WakuConfBuilder.init()
    let conf = builder.build().expect("build should succeed")
    check conf.maxPureLibp2pPeers == 0

  test "logos.dev preset carries 50":
    var builder = WakuConfBuilder.init()
    builder.withNetworkPresetConf(NetworkPresetConf.LogosDevConf())
    let conf = builder.build().expect("build should succeed")
    check conf.maxPureLibp2pPeers == 50

  test "explicit value wins over the preset":
    var builder = WakuConfBuilder.init()
    builder.withNetworkPresetConf(NetworkPresetConf.LogosDevConf())
    builder.withMaxPureLibp2pPeers(0)
    let conf = builder.build().expect("build should succeed")
    check conf.maxPureLibp2pPeers == 0

  test "negative value is rejected":
    var builder = WakuConfBuilder.init()
    builder.withMaxPureLibp2pPeers(-1)
    check builder.build().isErr()

suite "Waku Conf - mix nodes from a network preset":
  ## A preset that turns mix on seeds at least `MinMixPoolSize` nodes, the fewest
  ## that a path can use.

  test "the presets that enable mix ship a pool that can build a path":
    for preset in [NetworkPresetConf.LogosDevConf(), NetworkPresetConf.LogosTestConf()]:
      check:
        preset.mix
        preset.mixnodes.len >= MinMixPoolSize
        # count distinct nodes, so a duplicate line counts once
        preset.mixnodes.mapIt(parseMixNode(it).get().multiAddr).deduplicate().len >=
          MinMixPoolSize

  test "a preset's mix nodes are its entry nodes":
    ## The mix list and the entry list name the same fleet nodes, so an edit to
    ## one list fails this test until the other matches.
    for preset in [NetworkPresetConf.LogosDevConf(), NetworkPresetConf.LogosTestConf()]:
      for entry in preset.mixnodes:
        check parseMixNode(entry).get().multiAddr in preset.entryNodes

  test "every mix node a preset ships parses":
    for preset in [NetworkPresetConf.LogosDevConf(), NetworkPresetConf.LogosTestConf()]:
      for entry in preset.mixnodes:
        check parseMixNode(entry).isOk()

  test "the presets that do not enable mix ship no mix nodes":
    for preset in [
      NetworkPresetConf.TheWakuNetworkConf(), NetworkPresetConf.StatusProdConf()
    ]:
      check:
        not preset.mix
        preset.mixnodes.len == 0

  test "a preset's mix nodes reach the built conf":
    var builder = WakuConfBuilder.init()
    builder.discv5Conf.withUdpPort(9000)
    # An anonymity level enables the mix conf, which decides the mount.
    builder.mixConf.withEnabled(true)
    builder.withNetworkPresetConf(NetworkPresetConf.LogosDevConf())

    let conf = builder.build().valueOr:
      raiseAssert "Conf build failed: " & $error

    check conf.mixConf.isSome()
    check conf.mixConf.get().mixnodes.len ==
      NetworkPresetConf.LogosDevConf().mixnodes.len

  test "mix nodes given by the user are kept alongside the preset's":
    let extra = MixNodePubInfo(
      multiAddr:
        "/ip4/203.0.113.9/tcp/30303/p2p/" &
        "16Uiu2HAmTUbnxLGT9JvV6mu9oPyDjqHK4Phs1VDJNUgESgNSkuby",
      pubKey: intoCurve25519Key(
        utils.fromHex(
          "c288a425a6209c74ec07e2e8b6816e9b6995d1cd59b1ab482317c3dfb3ba200f"
        )
      ),
    )

    var builder = WakuConfBuilder.init()
    builder.discv5Conf.withUdpPort(9000)
    builder.mixConf.withEnabled(true)
    builder.mixConf.withMixNodes(@[extra])
    builder.withNetworkPresetConf(NetworkPresetConf.LogosDevConf())

    let conf = builder.build().valueOr:
      raiseAssert "Conf build failed: " & $error

    check conf.mixConf.get().mixnodes.len ==
      NetworkPresetConf.LogosDevConf().mixnodes.len + 1

suite "Waku Conf - mix node entries":
  const Key = "c288a425a6209c74ec07e2e8b6816e9b6995d1cd59b1ab482317c3dfb3ba200f"
  const PeerId = "16Uiu2HAmTUbnxLGT9JvV6mu9oPyDjqHK4Phs1VDJNUgESgNSkuby"

  test "a name is accepted, because a preset pins names":
    ## The fleets publish `dns4`; the node resolves the names after the mount.
    check parseMixNode(
      "/dns4/delivery-01.do-ams3.logos.dev.status.im/tcp/30303/p2p/" & PeerId & ":" & Key
    )
      .isOk()

  test "a literal address is accepted too":
    check parseMixNode("/ip4/203.0.113.9/tcp/30303/p2p/" & PeerId & ":" & Key).isOk()

  test "a malformed entry is rejected rather than raised on":
    check:
      parseMixNode("no-separator").isErr()
      # a key with a valid hex prefix and trailing junk must fail
      parseMixNode("/ip4/203.0.113.9/tcp/30303/p2p/" & PeerId & ":" & Key & "zz").isErr()
      parseMixNode("/ip4/203.0.113.9/tcp/30303/p2p/" & PeerId & ":" & Key & "00").isErr()
      # a multiaddress without a /p2p/<peer id> must fail at parse
      parseMixNode("/ip4/203.0.113.9/tcp/30303:" & Key).isErr()
      parseMixNode("/ip4/203.0.113.9/tcp/30303:" & Key & ":extra").isErr()
      parseMixNode("not-a-multiaddress:" & Key).isErr()
      parseMixNode("/ip4/203.0.113.9/tcp/30303/p2p/" & PeerId & ":abcd").isErr()

  test "an entry on a transport mix cannot route is refused, with the reason":
    ## The peer info parser takes WebSocket, IPv6, dns6, dns and dnsaddr, and the
    ## pool routes none of them, so the entry fails at config.
    for address in [
      "/ip4/203.0.113.9/tcp/30303/ws", "/ip6/2001:db8::1/tcp/30303",
      "/dns6/delivery-01.example.invalid/tcp/30303",
      "/dns/delivery-01.example.invalid/tcp/30303",
      "/dnsaddr/delivery-01.example.invalid/tcp/30303",
    ]:
      let res = parseMixNode(address & "/p2p/" & PeerId & ":" & Key)
      check:
        res.isErr()
        res.error.contains("IPv4")

  test "a circuit relay over a routable transport is accepted, as the pool routes it":
    ## The pool matches the base transport with the `/p2p/<relay>/p2p-circuit`
    ## suffix stripped, and the encoder carries the relay id; the parser judges
    ## the relay's address the same way.
    const RelayId = "16Uiu2HAmMK7PYygBtKUQ8EHp7EfaD3bCEsJrkFooK8RQ2PVpJprH"
    check:
      parseMixNode(
        "/ip4/203.0.113.9/tcp/30303/p2p/" & RelayId & "/p2p-circuit/p2p/" & PeerId & ":" &
          Key
      )
        .isOk()
      parseMixNode(
        "/ip4/203.0.113.9/udp/30303/quic-v1/p2p/" & RelayId & "/p2p-circuit/p2p/" &
          PeerId & ":" & Key
      )
        .isOk()

  test "a dns4 name over QUIC-v1 is accepted too":
    check parseMixNode(
      "/dns4/delivery-01.example.invalid/udp/30303/quic-v1/p2p/" & PeerId & ":" & Key
    )
      .isOk()

  test "a QUIC-v1 entry is accepted, because mix routes QUIC-v1":
    ## The peer info parser and the mix pool both take QUIC-v1.
    check parseMixNode("/ip4/203.0.113.9/udp/30303/quic-v1/p2p/" & PeerId & ":" & Key)
      .isOk()

  test "an entry on a transport the peer info parser refuses is refused with its reason":
    ## The error carries the peer info parser's own reason.
    let res = parseMixNode("/ip4/203.0.113.9/udp/30303/p2p/" & PeerId & ":" & Key)
    check:
      res.isErr()
      res.error.contains("no supported transport")

suite "Waku Conf - the Mix capability follows the mount":
  ## The ENR `Mix` bit follows the mix conf, which mounts mix. A preset's
  ## `mix: true` does not mount mix, so it must not advertise it.

  test "a preset that enables mix does not advertise Mix by itself":
    var builder = WakuConfBuilder.init()
    builder.discv5Conf.withUdpPort(9000)
    builder.withNetworkPresetConf(NetworkPresetConf.LogosDevConf())

    let conf = builder.build().valueOr:
      raiseAssert "Conf build failed: " & $error

    check:
      conf.mixConf.isNone()
      not conf.wakuFlags.supportsCapability(Capabilities.Mix)

  test "a node that mounts mix advertises Mix":
    var builder = WakuConfBuilder.init()
    builder.discv5Conf.withUdpPort(9000)
    builder.mixConf.withEnabled(true)
    builder.withNetworkPresetConf(NetworkPresetConf.LogosDevConf())

    let conf = builder.build().valueOr:
      raiseAssert "Conf build failed: " & $error

    check:
      conf.mixConf.isSome()
      conf.wakuFlags.supportsCapability(Capabilities.Mix)

  test "the user turning mix off on a preset that enables it keeps the bit off":
    ## `--mix=false` sets the bare flag to false and disables the mix conf. The
    ## build discards the conf with the preset's mix nodes and advertises nothing.
    var builder = WakuConfBuilder.init()
    builder.discv5Conf.withUdpPort(9000)
    builder.withMix(false)
    builder.mixConf.withEnabled(false)
    builder.withNetworkPresetConf(NetworkPresetConf.LogosDevConf())

    let conf = builder.build().valueOr:
      raiseAssert "Conf build failed: " & $error

    check:
      conf.mixConf.isNone()
      not conf.wakuFlags.supportsCapability(Capabilities.Mix)

  test "the bare mix flag does not decide the mount, and does not reach the ENR":
    ## The bare `mix` flag and the mix conf disagree here, and the conf decides:
    ## mix is mounted and advertised.
    var builder = WakuConfBuilder.init()
    builder.discv5Conf.withUdpPort(9000)
    builder.withMix(false)
    builder.mixConf.withEnabled(true)
    builder.withNetworkPresetConf(NetworkPresetConf.LogosDevConf())

    let conf = builder.build().valueOr:
      raiseAssert "Conf build failed: " & $error

    check:
      conf.mixConf.isSome()
      conf.wakuFlags.supportsCapability(Capabilities.Mix)

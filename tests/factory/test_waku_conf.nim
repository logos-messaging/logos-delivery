{.used.}

import
  libp2p/crypto/[crypto, secp],
  libp2p/multiaddress,
  nimcrypto/utils,
  std/[net, options, random, sequtils],
  results,
  testutils/unittests
import
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/waku/factory/conf_builder/conf_builder,
  logos_delivery/waku/factory/networks_config,
  logos_delivery/waku/common/utils/parse_size_units

suite "Waku Conf - build with cluster conf":
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
      assert conf.rlnRelayConf.isSome(), "RLN Relay conf is disabled"

      let rlnRelayConf = conf.rlnRelayConf.get()
      check rlnRelayConf.ethContractAddress.string ==
        networkPresetConf.rlnRelayEthContractAddress
      check rlnRelayConf.dynamic == networkPresetConf.rlnRelayDynamic
      check rlnRelayConf.chainId == networkPresetConf.rlnRelayChainId
      check rlnRelayConf.epochSizeSec == networkPresetConf.rlnEpochSizeSec
      check rlnRelayConf.userMessageLimit == userMessageLimit.uint

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

    assert conf.rlnRelayConf.isNone

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
    assert conf.rlnRelayConf.isNone

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
    ## internally the same. Promoting the config to an Option[uint16] is
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

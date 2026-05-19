{.used.}

import
  libp2p/crypto/[crypto, secp],
  libp2p/multiaddress,
  nimcrypto/utils,
  std/[net, options, random, sequtils],
  results,
  testutils/unittests
import
  waku/factory/waku_conf,
  waku/factory/conf_builder/conf_builder,
  waku/factory/networks_config,
  waku/common/utils/parse_size_units

suite "Waku Conf - build with cluster conf":
  test "Cluster Conf is passed and relay is enabled":
    ## Setup
    let networkConf = NetworkConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    builder.discv5Conf.withUdpPort(9000)
    builder.withRelayServiceRatio("50:50")
    # Mount all shards in network
    let expectedShards = toSeq[0.uint16 .. 7.uint16]
    let userMessageLimit = rand(1 .. 1000).uint64

    ## Given
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])
    builder.withNetworkConf(networkConf)
    builder.withRelay(true)
    builder.rlnRelayConf.withUserMessageLimit(userMessageLimit)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check conf.clusterId == networkConf.clusterId
    check conf.shardingConf.kind == networkConf.shardingConf.kind
    check conf.shardingConf.numShardsInCluster ==
      networkConf.shardingConf.numShardsInCluster
    check conf.subscribeShards == expectedShards
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(networkConf.maxMessageSize))
    check conf.discv5Conf.get().bootstrapNodes == networkConf.discv5BootstrapNodes

    if networkConf.rlnRelay:
      assert conf.rlnRelayConf.isSome(), "RLN Relay conf is disabled"

      let rlnRelayConf = conf.rlnRelayConf.get()
      check rlnRelayConf.ethContractAddress.string ==
        networkConf.rlnRelayEthContractAddress
      check rlnRelayConf.dynamic == networkConf.rlnRelayDynamic
      check rlnRelayConf.chainId == networkConf.rlnRelayChainId
      check rlnRelayConf.epochSizeSec == networkConf.rlnEpochSizeSec
      check rlnRelayConf.userMessageLimit == userMessageLimit.uint

  test "Cluster Conf is passed, but relay is disabled":
    ## Setup
    let networkConf = NetworkConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    builder.withRelayServiceRatio("50:50")
    builder.discv5Conf.withUdpPort(9000)
    # Mount all shards in network
    let expectedShards = toSeq[0.uint16 .. 7.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])
    builder.withNetworkConf(networkConf)
    builder.withRelay(false)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check conf.clusterId == networkConf.clusterId
    check conf.shardingConf.kind == networkConf.shardingConf.kind
    check conf.shardingConf.numShardsInCluster ==
      networkConf.shardingConf.numShardsInCluster
    check conf.subscribeShards == expectedShards
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(networkConf.maxMessageSize))
    check conf.discv5Conf.get().bootstrapNodes == networkConf.discv5BootstrapNodes

    assert conf.rlnRelayConf.isNone

  test "Cluster Conf is passed, but rln relay is disabled":
    ## Setup
    let networkConf = NetworkConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()

    let # Mount all shards in network
      expectedShards = toSeq[0.uint16 .. 7.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])
    builder.withNetworkConf(networkConf)
    builder.rlnRelayConf.withEnabled(false)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check conf.clusterId == networkConf.clusterId
    check conf.shardingConf.kind == networkConf.shardingConf.kind
    check conf.shardingConf.numShardsInCluster ==
      networkConf.shardingConf.numShardsInCluster
    check conf.subscribeShards == expectedShards
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(networkConf.maxMessageSize))
    check conf.discv5Conf.get().bootstrapNodes == networkConf.discv5BootstrapNodes
    assert conf.rlnRelayConf.isNone

  test "Cluster Conf is passed and valid shards are specified":
    ## Setup
    let networkConf = NetworkConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    let shards = @[2.uint16, 3.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])
    builder.withNetworkConf(networkConf)
    builder.withSubscribeShards(shards)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check conf.clusterId == networkConf.clusterId
    check conf.shardingConf.kind == networkConf.shardingConf.kind
    check conf.shardingConf.numShardsInCluster ==
      networkConf.shardingConf.numShardsInCluster
    check conf.subscribeShards == shards
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(networkConf.maxMessageSize))
    check conf.discv5Conf.get().bootstrapNodes == networkConf.discv5BootstrapNodes

  test "Cluster Conf is passed and invalid shards are specified":
    ## Setup
    let networkConf = NetworkConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    let shards = @[2.uint16, 10.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])
    builder.withNetworkConf(networkConf)
    builder.withSubscribeShards(shards)

    ## When
    let resConf = builder.build()

    ## Then
    assert resConf.isErr(), "Invalid shard was accepted"

  test "Cluster Conf is passed and RLN contract is **not** overridden":
    ## Setup
    let networkConf = NetworkConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    builder.rlnRelayConf.withEthClientUrls(@["https://my_eth_rpc_url/"])

    # Mount all shards in network
    let expectedShards = toSeq[0.uint16 .. 7.uint16]
    let contractAddress = "0x0123456789ABCDEF"
    let userMessageLimit = rand(1 .. 1000).uint64

    ## Given
    builder.rlnRelayConf.withEthContractAddress(contractAddress)
    builder.withNetworkConf(networkConf)
    builder.withRelay(true)
    builder.rlnRelayConf.withUserMessageLimit(userMessageLimit)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check conf.clusterId == networkConf.clusterId
    check conf.shardingConf.kind == networkConf.shardingConf.kind
    check conf.shardingConf.numShardsInCluster ==
      networkConf.shardingConf.numShardsInCluster
    check conf.subscribeShards == expectedShards
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(networkConf.maxMessageSize))
    check conf.discv5Conf.isSome == networkConf.discv5Discovery
    check conf.discv5Conf.get().bootstrapNodes == networkConf.discv5BootstrapNodes

    if networkConf.rlnRelay:
      assert conf.rlnRelayConf.isSome

      let rlnRelayConf = conf.rlnRelayConf.get()
      check rlnRelayConf.ethContractAddress.string ==
        networkConf.rlnRelayEthContractAddress
      check rlnRelayConf.dynamic == networkConf.rlnRelayDynamic
      check rlnRelayConf.chainId == networkConf.rlnRelayChainId
      check rlnRelayConf.epochSizeSec == networkConf.rlnEpochSizeSec
      check rlnRelayConf.userMessageLimit == userMessageLimit.uint

  test "num-shards-in-network > 0 overrides preset":
    ## Setup
    let networkConf = NetworkConf.LogosDevConf()
    var builder = WakuConfBuilder.init()

    # Sanity check
    check networkConf.shardingConf.kind == AutoSharding
    check networkConf.shardingConf.numShardsInCluster > 1

    ## Given: preset says >1 shards but user explicitly sets 1
    builder.withNetworkConf(networkConf)
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
    let networkConf = NetworkConf.LogosDevConf()
    var builder = WakuConfBuilder.init()
    builder.withNetworkConf(networkConf)
    # Note: builder.withNumShardsInCluster() is not called when the
    # value that comes from the CLI path is 0 (which means it was
    # either set to 0 or was left unset).
    builder.withShardingConf(StaticSharding)

    ## When
    let conf = builder.build().expect("build should succeed")

    ## Then: preset wins and StaticSharding user intent is lost
    conf.validate().expect("conf should validate")
    check conf.shardingConf.kind == networkConf.shardingConf.kind
    check conf.shardingConf.numShardsInCluster ==
      networkConf.shardingConf.numShardsInCluster

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

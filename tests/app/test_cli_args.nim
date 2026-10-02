{.used.}

import
  std/[os, strutils],
  testutils/unittests,
  chronos,
  libp2p/crypto/[crypto, secp],
  libp2p/multiaddress,
  nimcrypto/utils,
  secp256k1,
  confutils,
  stint

import tools/confutils/cli_args

import
  ../../logos_delivery/waku/factory/networks_config,
  ../../logos_delivery/waku/factory/waku_conf,
  ../../logos_delivery/waku/common/logging,
  ../../logos_delivery/waku/common/utils/parse_size_units,
  ../../logos_delivery/waku/waku_core/message/default_values

suite "Waku external config - default values":
  test "Default sharding value":
    ## Setup
    let defaultShardingMode = StaticSharding
    let defaultSubscribeShards: seq[uint16] = @[]

    ## Given
    let preConfig = defaultKernelConf().get()

    ## When
    let res = preConfig.toWakuConf()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    check conf.shardingConf.kind == defaultShardingMode
    check conf.subscribeShards == defaultSubscribeShards

  test "Default shards value in static sharding":
    ## Setup
    let defaultSubscribeShards: seq[uint16] = @[]

    ## Given
    var preConfig = defaultKernelConf().get()
    preConfig.numShardsInNetwork = 0.uint16

    ## When
    let res = preConfig.toWakuConf()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    check conf.subscribeShards == defaultSubscribeShards

  test "Default entry layer is kernel":
    ## Given
    let preConfig = defaultLogosDeliveryNodeConf().get()

    ## Then
    check preConfig.entryLayer == EntryLayer.kernel

suite "Waku external config - apply preset":
  test "Preset is TWN":
    ## Setup
    let expectedConf = NetworkPresetConf.TheWakuNetworkConf()

    ## Given
    let preConfig = WakuNodeConf(
      preset: "twn",
      relay: Opt.some(true),
      ethClientUrls: @["http://someaddress".EthRpcUrl],
    )

    ## When
    let res = preConfig.toWakuConf()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(expectedConf.maxMessageSize))
    check conf.clusterId == expectedConf.clusterId
    check conf.rlnEvmConf.isSome() == expectedConf.rlnRelay
    if conf.rlnEvmConf.isSome():
      let rlnEvmConf = conf.rlnEvmConf.get()
      check rlnEvmConf.ethContractAddress == expectedConf.rlnRelayEthContractAddress
      check rlnEvmConf.dynamic == expectedConf.rlnRelayDynamic
      check rlnEvmConf.chainId == expectedConf.rlnRelayChainId
      check rlnEvmConf.epochSizeSec == expectedConf.rlnEpochSizeSec
      check rlnEvmConf.userMessageLimit == expectedConf.rlnRelayUserMessageLimit
      check conf.shardingConf.kind == expectedConf.shardingConf.kind
      check conf.shardingConf.numShardsInCluster ==
        expectedConf.shardingConf.numShardsInCluster
    check conf.discv5Conf.isSome() == expectedConf.discv5Discovery
    if conf.discv5Conf.isSome():
      let discv5Conf = conf.discv5Conf.get()
      check discv5Conf.bootstrapNodes == expectedConf.discv5BootstrapNodes

  test "Subscribes to all valid shards in twn":
    ## Setup
    let expectedConf = NetworkPresetConf.TheWakuNetworkConf()

    ## Given
    let shards: seq[uint16] = @[0, 1, 2, 3, 4, 5, 6, 7]
    let preConfig = WakuNodeConf(preset: "twn", shards: shards)

    ## When
    let res = preConfig.toWakuConf()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    check conf.subscribeShards.len == expectedConf.shardingConf.numShardsInCluster.int

  test "Subscribes to some valid shards in twn":
    ## Setup
    let expectedConf = NetworkPresetConf.TheWakuNetworkConf()

    ## Given
    let shards: seq[uint16] = @[0, 4, 7]
    let preConfig = WakuNodeConf(preset: "twn", shards: shards)

    ## When
    let resConf = preConfig.toWakuConf()
    assert resConf.isOk(), $resConf.error

    ## Then
    let conf = resConf.get()
    assert conf.subscribeShards.len() == shards.len()
    for index, shard in shards:
      assert shard in conf.subscribeShards

  test "Subscribes to invalid shards in twn":
    ## Setup

    ## Given
    let shards: seq[uint16] = @[0, 4, 7, 10]
    let preConfig = WakuNodeConf(preset: "twn", shards: shards)

    ## When
    let res = preConfig.toWakuConf()

    ## Then
    assert res.isErr(), "Invalid shard was accepted"

suite "Waku external config - node key":
  test "Passed node key is used":
    ## Setup
    let nodeKeyStr =
      "0011223344556677889900aabbccddeeff0011223344556677889900aabbccddeeff"
    let nodekey = block:
      let key = SkPrivateKey.init(utils.fromHex(nodeKeyStr)).tryGet()
      crypto.PrivateKey(scheme: Secp256k1, skkey: key)

    ## Given
    let config = WakuNodeConf.load(version = "", cmdLine = @["--nodekey=" & nodeKeyStr])

    ## When
    let res = config.toWakuConf()
    assert res.isOk(), $res.error

    ## Then
    let resKey = res.get().nodeKey
    assert utils.toHex(resKey.getRawBytes().get()) ==
      utils.toHex(nodekey.getRawBytes().get())

suite "Waku external config - Shards":
  test "Shards are valid":
    ## Setup

    ## Given
    let shards: seq[uint16] = @[0, 2, 4]
    let numShardsInNetwork = 5.uint16
    let wakuNodeConf =
      WakuNodeConf(shards: shards, numShardsInNetwork: numShardsInNetwork)

    ## When
    let res = wakuNodeConf.toWakuConf()
    assert res.isOk(), $res.error

    ## Then
    let wakuConf = res.get()
    let vRes = wakuConf.validate()
    assert vRes.isOk(), $vRes.error

  test "Shards are not in range":
    ## Setup

    ## Given
    let shards: seq[uint16] = @[0, 2, 5]
    let numShardsInNetwork = 5.uint16
    let wakuNodeConf =
      WakuNodeConf(shards: shards, numShardsInNetwork: numShardsInNetwork)

    ## When
    let res = wakuNodeConf.toWakuConf()

    ## Then
    assert res.isErr(), "Invalid shard was accepted"

  test "Shard is passed without num shards":
    ## Setup

    ## Given
    let wakuNodeConf = WakuNodeConf.load(version = "", cmdLine = @["--shard=0"])

    ## When
    let res = wakuNodeConf.toWakuConf()

    ## Then
    let wakuConf = res.get()
    let vRes = wakuConf.validate()
    assert vRes.isOk(), $vRes.error

  test "Any shard is valid without num shards in static sharding mode":
    ## Setup

    ## Given
    let wakuNodeConf = WakuNodeConf.load(version = "", cmdLine = @["--shard=32"])

    ## When
    let res = wakuNodeConf.toWakuConf()

    ## Then
    let wakuConf = res.get()
    let vRes = wakuConf.validate()
    assert vRes.isOk(), $vRes.error

  test "Shard is passed several times":
    ## Given
    let cmdLine = @["--shard=0", "--shard=2", "--shard=4"]

    ## When
    let wakuNodeConf = WakuNodeConf.load(version = "", cmdLine = cmdLine)

    ## Then
    check wakuNodeConf.shards == @[0'u16, 2, 4]

suite "Waku external config - store retention policy":
  test "Default retention policy":
    ## Given
    var conf = defaultKernelConf().get()
    conf.store = Opt.some(true)
    conf.storeMessageDbUrl = "sqlite://test.db"
    # storeMessageRetentionPolicy keeps its default: "time:<2 days in seconds>"

    ## When
    let res = conf.toWakuConf()

    ## Then
    assert res.isOk(), $res.error
    let wakuConf = res.get()
    require wakuConf.storeServiceConf.isSome()
    check wakuConf.storeServiceConf.get().retentionPolicies ==
      @["time:" & $2.days.seconds]

  test "Single custom retention policy":
    ## Given
    var conf = defaultKernelConf().get()
    conf.store = Opt.some(true)
    conf.storeMessageDbUrl = "sqlite://test.db"
    conf.storeMessageRetentionPolicy = "capacity:50000"

    ## When
    let res = conf.toWakuConf()

    ## Then
    assert res.isOk(), $res.error
    let wakuConf = res.get()
    require wakuConf.storeServiceConf.isSome()
    check wakuConf.storeServiceConf.get().retentionPolicies == @["capacity:50000"]

  test "Retention policies with whitespace around semicolons and colons":
    ## Given
    var conf = defaultKernelConf().get()
    conf.store = Opt.some(true)
    conf.storeMessageDbUrl = "sqlite://test.db"
    conf.storeMessageRetentionPolicy = "time:3600 ; capacity:10000 ; size     : 30GB"

    ## When
    let res = conf.toWakuConf()

    ## Then
    assert res.isOk(), $res.error
    let wakuConf = res.get()
    require wakuConf.storeServiceConf.isSome()
    check wakuConf.storeServiceConf.get().retentionPolicies ==
      @["time:3600", "capacity:10000", "size:30GB"]

  test "Invalid retention policy type returns error":
    ## Given
    var conf = defaultKernelConf().get()
    conf.store = Opt.some(true)
    conf.storeMessageDbUrl = "sqlite://test.db"
    conf.storeMessageRetentionPolicy = "foo:1234"

    ## When
    let res = conf.toWakuConf()

    ## Then
    check res.isErr()
    check res.error.contains("unknown retention policy type")

  test "Duplicated retention policy type returns error":
    ## Given
    var conf = defaultKernelConf().get()
    conf.store = Opt.some(true)
    conf.storeMessageDbUrl = "sqlite://test.db"
    conf.storeMessageRetentionPolicy = "time:3600;time:7200;capacity:10000"

    ## When
    let res = conf.toWakuConf()

    ## Then
    check res.isErr()
    check res.error.contains("duplicated retention policy type")

suite "Waku external config - store sync":
  test "Store sync without store builds no store service":
    ## Given
    var conf = defaultKernelConf().get()
    conf.store = Opt.some(false)
    conf.storeSync = true

    ## When
    let wakuConf = conf.toWakuConf().valueOr:
      raiseAssert error

    ## Then the configuration builds, and store sync is silently not configured
    check wakuConf.storeServiceConf.isNone()

suite "Waku external config - http url parsing":
  test "Basic HTTP URLs without authentication":
    check string(parseCmdArg(EthRpcUrl, "https://example.com/path")) ==
      "https://example.com/path"
    check string(parseCmdArg(EthRpcUrl, "https://example.com/")) ==
      "https://example.com/"
    check string(parseCmdArg(EthRpcUrl, "http://localhost:8545")) ==
      "http://localhost:8545"
    check string(parseCmdArg(EthRpcUrl, "https://mainnet.infura.io")) ==
      "https://mainnet.infura.io"

  test "Basic authentication with simple credentials":
    check string(parseCmdArg(EthRpcUrl, "https://user:pass@example.com/path")) ==
      "https://user:pass@example.com/path"
    check string(
      parseCmdArg(EthRpcUrl, "https://john.doe:secret123@example.com/api/v1")
    ) == "https://john.doe:secret123@example.com/api/v1"
    check string(parseCmdArg(EthRpcUrl, "https://user_name:pass_word@example.com/")) ==
      "https://user_name:pass_word@example.com/"
    check string(parseCmdArg(EthRpcUrl, "https://user-name:pass-word@example.com/")) ==
      "https://user-name:pass-word@example.com/"
    check string(parseCmdArg(EthRpcUrl, "https://user123:pass456@example.com/")) ==
      "https://user123:pass456@example.com/"

  test "Special characters (percent-encoded) in credentials":
    check string(
      parseCmdArg(EthRpcUrl, "https://user%40email:pass%21%23%24@example.com/")
    ) == "https://user%40email:pass%21%23%24@example.com/"
    check string(parseCmdArg(EthRpcUrl, "https://user%2Bplus:pass%26and@example.com/")) ==
      "https://user%2Bplus:pass%26and@example.com/"
    check string(
      parseCmdArg(EthRpcUrl, "https://user%3Acolon:pass%3Bsemi@example.com/")
    ) == "https://user%3Acolon:pass%3Bsemi@example.com/"
    check string(
      parseCmdArg(EthRpcUrl, "https://user%2Fslash:pass%3Fquest@example.com/")
    ) == "https://user%2Fslash:pass%3Fquest@example.com/"
    check string(
      parseCmdArg(EthRpcUrl, "https://user%5Bbracket:pass%5Dbracket@example.com/")
    ) == "https://user%5Bbracket:pass%5Dbracket@example.com/"
    check string(
      parseCmdArg(EthRpcUrl, "https://user%20space:pass%20space@example.com/")
    ) == "https://user%20space:pass%20space@example.com/"
    check string(
      parseCmdArg(EthRpcUrl, "https://user%3Cless:pass%3Egreater@example.com/")
    ) == "https://user%3Cless:pass%3Egreater@example.com/"
    check string(
      parseCmdArg(EthRpcUrl, "https://user%7Bbrace:pass%7Dbrace@example.com/")
    ) == "https://user%7Bbrace:pass%7Dbrace@example.com/"
    check string(parseCmdArg(EthRpcUrl, "https://user%5Cback:pass%7Cpipe@example.com/")) ==
      "https://user%5Cback:pass%7Cpipe@example.com/"

  test "Complex passwords with special characters":
    check string(
      parseCmdArg(
        EthRpcUrl, "https://admin:P%40ssw0rd%21%23%24%25%5E%26*()@example.com/"
      )
    ) == "https://admin:P%40ssw0rd%21%23%24%25%5E%26*()@example.com/"
    check string(
      parseCmdArg(EthRpcUrl, "https://user:abc123%21%40%23DEF456@example.com/")
    ) == "https://user:abc123%21%40%23DEF456@example.com/"
    check string(
      parseCmdArg(
        EthRpcUrl,
        "https://user:P%40%24%24w0rd%21%23%24%25%5E%26%2A%28%29_%2B-%3D%5B%5D%7B%7D%7C%3B%27%3A%22%2C.%2F%3C%3E%3F%60~%5C@example.com",
      )
    ) ==
      "https://user:P%40%24%24w0rd%21%23%24%25%5E%26%2A%28%29_%2B-%3D%5B%5D%7B%7D%7C%3B%27%3A%22%2C.%2F%3C%3E%3F%60~%5C@example.com"

  test "Different hostname types":
    check string(parseCmdArg(EthRpcUrl, "https://user:pass@subdomain.example.com/path")) ==
      "https://user:pass@subdomain.example.com/path"
    check string(parseCmdArg(EthRpcUrl, "https://user:pass@192.168.1.1/admin")) ==
      "https://user:pass@192.168.1.1/admin"
    check string(parseCmdArg(EthRpcUrl, "https://user:pass@[2001:db8::1]/path")) ==
      "https://user:pass@[2001:db8::1]/path"
    check string(parseCmdArg(EthRpcUrl, "https://user:pass@example.co.uk/path")) ==
      "https://user:pass@example.co.uk/path"

  test "URLs with port numbers":
    check string(parseCmdArg(EthRpcUrl, "https://user:pass@example.com:8080/path")) ==
      "https://user:pass@example.com:8080/path"
    check string(parseCmdArg(EthRpcUrl, "https://user:pass@example.com:443/")) ==
      "https://user:pass@example.com:443/"
    check string(parseCmdArg(EthRpcUrl, "http://user:pass@example.com:80/path")) ==
      "http://user:pass@example.com:80/path"

  test "URLs with query parameters and fragments":
    check string(
      parseCmdArg(EthRpcUrl, "https://user:pass@example.com/path?query=1#section")
    ) == "https://user:pass@example.com/path?query=1#section"
    check string(
      parseCmdArg(EthRpcUrl, "https://user:pass@example.com/?foo=bar&baz=qux")
    ) == "https://user:pass@example.com/?foo=bar&baz=qux"
    check string(parseCmdArg(EthRpcUrl, "https://api.example.com/rpc?key=value")) ==
      "https://api.example.com/rpc?key=value"
    check string(parseCmdArg(EthRpcUrl, "https://api.example.com/rpc#section")) ==
      "https://api.example.com/rpc#section"

  test "Edge cases with credentials":
    check string(parseCmdArg(EthRpcUrl, "https://a:b@example.com/")) ==
      "https://a:b@example.com/"
    check string(parseCmdArg(EthRpcUrl, "https://user:@example.com/")) ==
      "https://user:@example.com/"
    check string(parseCmdArg(EthRpcUrl, "https://:pass@example.com/")) ==
      "https://:pass@example.com/"
    check string(parseCmdArg(EthRpcUrl, "http://user:pass@example.com/")) ==
      "http://user:pass@example.com/"

  test "Websocket URLs are rejected":
    expect(ValueError):
      discard parseCmdArg(EthRpcUrl, "ws://localhost:8545")
    expect(ValueError):
      discard parseCmdArg(EthRpcUrl, "wss://mainnet.infura.io")
    expect(ValueError):
      discard parseCmdArg(EthRpcUrl, "ws://user:pass@localhost:8545")

  test "Invalid URLs are rejected":
    expect(ValueError):
      discard parseCmdArg(EthRpcUrl, "https://user@pass@example.com/")
    expect(ValueError):
      discard parseCmdArg(EthRpcUrl, "https://user:pass:extra@example.com/")
    expect(ValueError):
      discard parseCmdArg(EthRpcUrl, "ftp://user:pass@example.com/")
    expect(ValueError):
      discard parseCmdArg(EthRpcUrl, "https://user pass@example.com/")
    expect(ValueError):
      discard parseCmdArg(EthRpcUrl, "https://user:pass word@example.com/")
    expect(ValueError):
      discard parseCmdArg(EthRpcUrl, "user:pass@example.com/")
    expect(ValueError):
      discard parseCmdArg(EthRpcUrl, "https://user:pass@")
    expect(ValueError):
      discard parseCmdArg(EthRpcUrl, "https://user:pass@@example.com/")
    expect(ValueError):
      discard parseCmdArg(EthRpcUrl, "not-a-url")
    expect(ValueError):
      discard parseCmdArg(EthRpcUrl, "http://")
    expect(ValueError):
      discard parseCmdArg(EthRpcUrl, "https://")

suite "Waku external config - environment variables":
  test "options are read from the LOGOS_DELIVERY_NODE_ prefix":
    ## Given
    putEnv("LOGOS_DELIVERY_NODE_TCP_PORT", "8080")
    defer:
      delEnv("LOGOS_DELIVERY_NODE_TCP_PORT")

    ## When
    ## `cmdLine = @[]` ignores the test runner's own arguments.
    let conf =
      try:
        WakuNodeConf.load(
          version = "",
          cmdLine = @[],
          secondarySources = proc(
              conf: WakuNodeConf, sources: auto
          ) {.gcsafe, raises: [ConfigurationError].} =
            sources.addConfigFile(Envvar, InputFile(NodeEnvvarPrefix)),
        )
      except CatchableError:
        raiseAssert getCurrentExceptionMsg()

    ## Then
    check conf.tcpPort == Port(8080)

suite "Waku external config - REST server caches":
  test "messaging cache capacity must be at least 1":
    var conf = defaultKernelConf().get()
    conf.rest = true
    conf.restMessagingCacheCapacity = 0
    check conf.toWakuConf().isErr()

  test "messaging cache capacity flows into the REST server conf":
    var conf = defaultKernelConf().get()
    conf.rest = true
    conf.restMessagingCacheCapacity = 1
    let res = conf.toWakuConf()
    check res.isOk()
    check res.get().restServerConf.get().messagingCacheCapacity == 1'u32

  test "relay cache capacity must be at least 1":
    var conf = defaultKernelConf().get()
    conf.rest = true
    conf.restRelayCacheCapacity = 0
    check conf.toWakuConf().isErr()

suite "Node config - Messaging API flags":
  test "the messaging flags parse from the command line":
    let conf = LogosDeliveryNodeConf.load(
      version = "", cmdLine = @["--reliability=false", "--anonymity-level=Required"]
    )
    check:
      conf.messaging.reliabilityEnabled == Opt.some(false)
      conf.messaging.anonymityLevel == Opt.some(AnonymityLevel.Required)

  test "the messaging flags are unset by default":
    let conf = LogosDeliveryNodeConf.load(version = "", cmdLine = @[])
    check not conf.messaging.isSet()

suite "Waku external config - deprecated flags":
  test "deprecated flags still parse and leave the config unchanged":
    ## Given
    let cmdLine = @["--dns-discovery", "--rln-relay-eth-private-key=0xabc"]

    ## When
    var conf = WakuNodeConf.load(version = "", cmdLine = cmdLine)
    applyModeFlags(conf, DefaultKernelModeFlags)
    let wakuConf = conf.toWakuConf().valueOr:
      raiseAssert error
    let defaultWakuConf = defaultKernelConf().get().toWakuConf().valueOr:
        raiseAssert error

    ## Then
    check:
      conf.dnsDiscovery == true
      conf.rlnRelayEthPrivateKey == "0xabc"
      wakuConf.dnsDiscoveryConf.isNone()
      wakuConf.discv5Conf.isSome() == defaultWakuConf.discv5Conf.isSome()
      wakuConf.rlnEvmConf.isNone()

  test "on-chain RLN no longer needs --rln-relay-dynamic":
    ## Given
    var conf = defaultKernelConf().get()
    conf.rlnRelay = Opt.some(true)
    conf.rlnRelayChainId = 1
    conf.rlnRelayEthContractAddress = "0x0000000000000000000000000000000000000001"

    ## When
    let wakuConf = conf.toWakuConf().valueOr:
      raiseAssert error

    ## Then
    check:
      wakuConf.rlnEvmConf.isSome()
      wakuConf.rlnEvmConf.get().dynamic

  test "--rln-relay-dynamic is still accepted":
    ## Given
    let rlnFlags = @[
      "--rln-relay=true", "--rln-relay-chain-id=1",
      "--rln-relay-eth-contract-address=0x0000000000000000000000000000000000000001",
    ]

    ## When
    let withTrue = WakuNodeConf
      .load(version = "", cmdLine = rlnFlags & "--rln-relay-dynamic=true")
      .toWakuConf()
    let withFalse = WakuNodeConf
      .load(version = "", cmdLine = rlnFlags & "--rln-relay-dynamic=false")
      .toWakuConf()

    ## Then
    check:
      withTrue.isOk()
      withTrue.get().rlnEvmConf.get().dynamic
      withFalse.isOk()
      not withFalse.get().rlnEvmConf.get().dynamic

suite "Waku external config - ignored dependent flags":
  proc warningsOf(conf: WakuNodeConf): seq[string] =
    let defaults = defaultKernelConf(ModeProtocolFlags()).get()
    let wakuConf = conf.toWakuConf().valueOr:
      raiseAssert error
    return ignoredFlagWarnings(conf, defaults, wakuConf)

  test "default config reports nothing":
    check warningsOf(defaultKernelConf().get()).len == 0

  test "flags set while their feature is disabled are reported":
    ## Given
    var conf = defaultKernelConf().get()
    conf.storeResume = true
    conf.restPort = 9000
    conf.metricsServerPort = 9001
    conf.quicSupport = false
    conf.quicPort = Opt.some(Port(9002))
    conf.websocketSecureKeyPath = "/key.pem"
    conf.rlnRelayCredIndex = Opt.some(1'u)

    ## When / Then
    check warningsOf(conf) ==
      @[
        "--store-resume is ignored: --store is not enabled",
        "--rest-port is ignored: --rest is not enabled",
        "--metrics-server-port is ignored: --metrics-server is not enabled",
        "--websocket-secure-key-path is ignored: --websocket-secure-support is not enabled",
        "--quic-port is ignored: --quic-support is not enabled",
        "--rln-relay-membership-index is ignored: --rln-relay is not enabled",
      ]

  test "flags of an enabled feature are not reported":
    ## Given
    var conf = defaultKernelConf().get()
    conf.store = Opt.some(true)
    conf.storeResume = true
    conf.rest = true
    conf.restPort = 9000
    conf.discv5UdpPort = Port(9003)

    ## When / Then
    check warningsOf(conf).len == 0

  test "a feature disabled by the user reports its flags":
    ## Given
    var conf = defaultKernelConf().get()
    conf.discv5Discovery = Opt.some(false)
    conf.discv5UdpPort = Port(9003)
    conf.filter = Opt.some(false)
    conf.filterMaxCriteria = 5

    ## When / Then
    check warningsOf(conf) ==
      @[
        "--filter-max-criteria is ignored: --filter is not enabled",
        "--discv5-udp-port is ignored: --discv5-discovery is not enabled",
      ]

  test "a feature enabled by the preset does not report its flags":
    ## Given: the TWN preset enables RLN
    var conf = defaultKernelConf().get()
    conf.preset = "twn"
    conf.rlnRelayCredIndex = Opt.some(1'u)

    ## When / Then
    check warningsOf(conf).len == 0

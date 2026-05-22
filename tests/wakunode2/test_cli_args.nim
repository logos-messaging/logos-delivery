{.used.}

import
  std/[options, strutils],
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
  ../../waku/factory/networks_config,
  ../../waku/factory/waku_conf,
  ../../waku/common/logging,
  ../../waku/common/utils/parse_size_units,
  ../../waku/waku_core/message/default_values

suite "Waku external config - default values":
  test "Default sharding value":
    ## Setup
    let defaultShardingMode = StaticSharding
    let defaultSubscribeShards: seq[uint16] = @[]

    ## Given
    let preConfig = defaultWakuNodeConf().get()

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
    var preConfig = defaultWakuNodeConf().get()
    preConfig.numShardsInNetwork = 0.uint16

    ## When
    let res = preConfig.toWakuConf()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    check conf.subscribeShards == defaultSubscribeShards

suite "Waku external config - apply preset":
  test "Preset is TWN":
    ## Setup
    let expectedConf = NetworkConf.TheWakuNetworkConf()

    ## Given
    let preConfig = WakuNodeConf(
      cmd: noCommand,
      preset: "twn",
      relay: true,
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
    check conf.rlnRelayConf.isSome() == expectedConf.rlnRelay
    if conf.rlnRelayConf.isSome():
      let rlnRelayConf = conf.rlnRelayConf.get()
      check rlnRelayConf.ethContractAddress == expectedConf.rlnRelayEthContractAddress
      check rlnRelayConf.dynamic == expectedConf.rlnRelayDynamic
      check rlnRelayConf.chainId == expectedConf.rlnRelayChainId
      check rlnRelayConf.epochSizeSec == expectedConf.rlnEpochSizeSec
      check rlnRelayConf.userMessageLimit == expectedConf.rlnRelayUserMessageLimit
      check conf.shardingConf.kind == expectedConf.shardingConf.kind
      check conf.shardingConf.numShardsInCluster ==
        expectedConf.shardingConf.numShardsInCluster
    check conf.discv5Conf.isSome() == expectedConf.discv5Discovery
    if conf.discv5Conf.isSome():
      let discv5Conf = conf.discv5Conf.get()
      check discv5Conf.bootstrapNodes == expectedConf.discv5BootstrapNodes

  test "Subscribes to all valid shards in twn":
    ## Setup
    let expectedConf = NetworkConf.TheWakuNetworkConf()

    ## Given
    let shards: seq[uint16] = @[0, 1, 2, 3, 4, 5, 6, 7]
    let preConfig = WakuNodeConf(cmd: noCommand, preset: "twn", shards: shards)

    ## When
    let res = preConfig.toWakuConf()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    check conf.subscribeShards.len == expectedConf.shardingConf.numShardsInCluster.int

  test "Subscribes to some valid shards in twn":
    ## Setup
    let expectedConf = NetworkConf.TheWakuNetworkConf()

    ## Given
    let shards: seq[uint16] = @[0, 4, 7]
    let preConfig = WakuNodeConf(cmd: noCommand, preset: "twn", shards: shards)

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
    let preConfig = WakuNodeConf(cmd: noCommand, preset: "twn", shards: shards)

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
    let wakuNodeConf = WakuNodeConf(
      cmd: noCommand, shards: shards, numShardsInNetwork: numShardsInNetwork
    )

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
    let wakuNodeConf = WakuNodeConf(
      cmd: noCommand, shards: shards, numShardsInNetwork: numShardsInNetwork
    )

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

suite "Waku external config - store retention policy":
  test "Default retention policy":
    ## Given
    var conf = defaultWakuNodeConf().get()
    conf.store = true
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
    var conf = defaultWakuNodeConf().get()
    conf.store = true
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
    var conf = defaultWakuNodeConf().get()
    conf.store = true
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
    var conf = defaultWakuNodeConf().get()
    conf.store = true
    conf.storeMessageDbUrl = "sqlite://test.db"
    conf.storeMessageRetentionPolicy = "foo:1234"

    ## When
    let res = conf.toWakuConf()

    ## Then
    check res.isErr()
    check res.error.contains("unknown retention policy type")

  test "Duplicated retention policy type returns error":
    ## Given
    var conf = defaultWakuNodeConf().get()
    conf.store = true
    conf.storeMessageDbUrl = "sqlite://test.db"
    conf.storeMessageRetentionPolicy = "time:3600;time:7200;capacity:10000"

    ## When
    let res = conf.toWakuConf()

    ## Then
    check res.isErr()
    check res.error.contains("duplicated retention policy type")

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
